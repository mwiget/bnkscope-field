import 'dart:async';

import 'package:bnk_kit/bnk_kit.dart';

import 'brief.dart';
import 'observable.dart';

/// Follows several containers at once and merges them into one view.
///
/// Nothing is installed to make this work: the apiserver streams a
/// container's stdout through the kubelet. What is missing without a
/// collector is history: this holds what has arrived since it started
/// following, and no more. The desktop build ships Loki and 24 hours; here
/// the window is the session.
class LogsEngine extends Observable {
  /// Enough to chase an incident, few enough that the apiserver is not
  /// being asked to hold hundreds of streams open for a tablet.
  static const maxStreams = 24;
  static const bufferLimit = 4000;

  final List<LogLine> _lines = [];
  List<String> _following = const [];
  int _dropped = 0;
  final List<String> _failures = [];
  bool _isRunning = false;
  String _query = '';
  Set<LogLevel> _levels = LogLevel.values.toSet();
  final Set<String> _muted = {};
  final Map<String, int> _counts = {};
  final List<StreamSubscription<LogLine>> _subscriptions = [];

  /// Newest first.
  List<LogLine> get lines => _lines;
  List<String> get following => _following;
  int get dropped => _dropped;
  List<String> get failures => _failures;
  bool get isRunning => _isRunning;

  String get query => _query;
  set query(String v) {
    _query = v;
    notify();
  }

  Set<LogLevel> get levels => _levels;
  set levels(Set<LogLevel> v) {
    _levels = v;
    notify();
  }

  /// Containers the reader has silenced.
  ///
  /// A log view following two dozen containers is only as useful as its
  /// noisiest one allows. Muting is display-only: the stream stays open and
  /// the lines stay in the buffer, so unmuting shows what was missed rather
  /// than starting again.
  Set<String> get muted => _muted;

  /// Lines held per container, for deciding what to mute.
  Map<String, int> get counts => _counts;

  /// Newest first. A live tail pinned to the bottom needs scroll management
  /// to stay useful, and gets in the way the moment you scroll up to read
  /// something; newest at the top needs neither and answers "what just
  /// happened" directly.
  List<LogLine> get visible {
    final needle = _query.trim().toLowerCase();
    return [
      for (final line in _lines)
        if (!_muted.contains(line.container ?? '') &&
            _levels.contains(line.level) &&
            (needle.isEmpty ||
                line.text.toLowerCase().contains(needle) ||
                line.pod.toLowerCase().contains(needle) ||
                (line.container?.toLowerCase().contains(needle) ?? false)))
          line
    ];
  }

  void start({required KubeClient client, required String namespace, required List<Pod> pods, int tailLines = 40}) {
    stop();
    var targets = <({String pod, String container})>[
      for (final pod in pods)
        for (final container in pod.logSources) (pod: pod.metadata.name, container: container)
    ];
    _dropped = targets.length > maxStreams ? targets.length - maxStreams : 0;
    targets = targets.take(maxStreams).toList();
    _following = [for (final t in targets) '${t.pod}/${t.container}'];
    _muted.clear();
    if (targets.isEmpty) {
      notify();
      return;
    }
    _isRunning = true;
    for (final target in targets) {
      _subscriptions.add(client
          .logStream(namespace: namespace, pod: target.pod, container: target.container, tailLines: tailLines)
          .listen(_insert, onError: (Object e) => _note('${target.pod}/${target.container}: ${brief(e)}')));
    }
    notify();
  }

  void stop() {
    for (final s in _subscriptions) {
      s.cancel();
    }
    _subscriptions.clear();
    _isRunning = false;
    notify();
  }

  void clear() {
    _lines.clear();
    _counts.clear();
    _failures.clear();
    notify();
  }

  void toggleMute(String container) {
    if (!_muted.remove(container)) _muted.add(container);
    notify();
  }

  /// Containers seen so far, noisiest first, which is the order someone
  /// looking for what to silence wants them in.
  List<({String container, int lines})> get sources {
    final out = [for (final e in _counts.entries) (container: e.key, lines: e.value)];
    out.sort((a, b) => a.lines == b.lines ? a.container.compareTo(b.container) : b.lines.compareTo(a.lines));
    return out;
  }

  /// Inserted in time order rather than appended.
  ///
  /// Several streams arrive interleaved and each is only ordered within
  /// itself, so arrival order is not time order. A binary search costs less
  /// than sorting the buffer on every line.
  void _insert(LogLine line) {
    final container = line.container;
    if (container != null) _counts[container] = (_counts[container] ?? 0) + 1;
    final at = line.at;
    if (at == null) {
      _lines.insert(0, line);
    } else {
      var low = 0;
      var high = _lines.length;
      final epoch = DateTime.fromMillisecondsSinceEpoch(0);
      while (low < high) {
        final mid = (low + high) ~/ 2;
        if ((_lines[mid].at ?? epoch).isAfter(at)) {
          low = mid + 1;
        } else {
          high = mid;
        }
      }
      _lines.insert(low, line);
    }
    if (_lines.length > bufferLimit) _lines.removeRange(bufferLimit, _lines.length);
    notify();
  }

  void _note(String message) {
    if (_failures.contains(message)) return;
    _failures.add(message);
    if (_failures.length > 6) _failures.removeAt(0);
    notify();
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
