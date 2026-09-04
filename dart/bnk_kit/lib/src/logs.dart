import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'kube_client.dart';
import 'time.dart';

enum LogLevel {
  error,
  warning,
  info;

  /// Guessed from the shapes that actually turn up in these clusters, which
  /// is more than one convention: klog's `E0831 09:00:43`, logfmt's
  /// `level=warn`, JSON's `"level":"error"`, and F5's CWC logger, which spells
  /// it `"l"="error"`, a single letter, and the reason the first version of
  /// this rendered a rabbitmq connection failure and a Redis retry storm in
  /// the same colour as a routine status line.
  ///
  /// It is a guess and will sometimes be wrong. The bias is deliberate: a
  /// missed error is invisible, while a line wrongly painted amber is still
  /// readable.
  static LogLevel guessed(String line) {
    final klog = _klogLevel(line);
    if (klog != null) return klog;
    final head =
        (line.length > 400 ? line.substring(0, 400) : line).toLowerCase();
    for (final marker in const [
      '"l"="error"', '"l"="critical"', '"l"="fatal"',
      'level=error', 'level=fatal', 'level=critical',
      '"level":"error"', '"level":"fatal"', '[error]', '[fatal]',
    ]) {
      if (head.contains(marker)) return error;
    }
    for (final marker in const [
      '"l"="warn"', 'level=warn', '"level":"warn"', '[warn]',
    ]) {
      if (head.contains(marker)) return warning;
    }
    if (_containsWord('panic', head) || _containsWord('fatal', head)) {
      return error;
    }
    if (_containsWord('error', head) || _containsWord('errors', head)) {
      return error;
    }
    for (final word in const [
      'failed', 'failure', 'refused', 'unreachable', 'timeout', 'warning',
    ]) {
      if (_containsWord(word, head)) return warning;
    }
    return info;
  }

  static final _fourDigits = RegExp(r'^\d{4}$');

  /// `E0831 09:00:43.931896`: severity letter, then a four-digit date.
  static LogLevel? _klogLevel(String line) {
    if (line.length <= 5) return null;
    if (!_fourDigits.hasMatch(line.substring(1, 5))) return null;
    return switch (line[0]) {
      'E' || 'F' => error,
      'W' => warning,
      'I' => info,
      _ => null,
    };
  }

  static final _wordCharacter = RegExp(r'^[\p{L}\p{N}/_-]$', unicode: true);

  /// Whole word only, so `errorless` does not count, and neither does a path
  /// component, which is why `/`, `-` and `_` are treated as part of a word
  /// rather than as boundaries: `/var/log/failed/` is a directory, not a
  /// fault. Nor does "0 errors", the reassuring case that a naive substring
  /// search turns into an alarm.
  static bool _containsWord(String word, String haystack) {
    var index = 0;
    while (true) {
      final at = haystack.indexOf(word, index);
      if (at < 0) return false;
      final end = at + word.length;
      final boundedBefore =
          at == 0 || !_wordCharacter.hasMatch(haystack[at - 1]);
      final boundedAfter =
          end == haystack.length || !_wordCharacter.hasMatch(haystack[end]);
      if (boundedBefore && boundedAfter && !_negated(at, haystack)) return true;
      index = end;
    }
  }

  /// "no errors" and "0 errors" are the opposite of an error.
  static bool _negated(int index, String haystack) {
    final prefix =
        haystack.substring(index >= 6 ? index - 6 : 0, index).toLowerCase();
    return prefix.endsWith('no ') ||
        prefix.endsWith('0 ') ||
        prefix.endsWith('zero ');
  }
}

/// One line out of one container.
class LogLine {
  static int _next = 0;

  /// Stable identity for a list, which arrival order does not give.
  final int id = _next++;
  final DateTime? at;
  final String pod;
  final String? container;
  final String text;
  final LogLevel level;

  LogLine(
      {required this.at,
      required this.pod,
      required this.container,
      required this.text,
      required this.level});

  /// `2026-08-31T09:24:18.442Z the rest of the line`
  static LogLine parse(String raw, {required String pod, String? container}) {
    DateTime? at;
    var text = raw;
    final space = raw.indexOf(' ');
    if (space > 0) {
      final date = Rfc3339.parse(raw.substring(0, space));
      if (date != null) {
        at = date;
        text = raw.substring(space + 1);
      }
    }
    return LogLine(
        at: at,
        pod: pod,
        container: container,
        text: text,
        level: LogLevel.guessed(text));
  }
}

extension LogsApi on KubeClient {
  /// Follow one container's log.
  ///
  /// Nothing is installed to make this work: a container's stdout is captured
  /// by the runtime on the node, and the apiserver will stream it back through
  /// the kubelet. That is the same door everything else here goes through, and
  /// it is why logs need no collector in the cluster; only history does.
  ///
  /// `timestamps=true` because merging several pods into one view needs
  /// something to sort by, and the arrival order of concurrent streams is not
  /// it. Cancelling the subscription drops the connection.
  Stream<LogLine> logStream(
      {required String namespace,
      required String pod,
      String? container,
      int tailLines = 80,
      bool follow = true}) {
    final controller = StreamController<LogLine>();
    HttpClientRequest? request;
    StreamSubscription<String>? lines;
    var cancelled = false;

    controller.onListen = () async {
      try {
        final query = <String, Object>{
          'follow': follow ? 'true' : 'false',
          'tailLines': '$tailLines',
          'timestamps': 'true',
          if (container != null) 'container': container,
        };
        final req = await open('GET', '/api/v1/namespaces/$namespace/pods/$pod/log', query);
        request = req;
        final response = await req.close();
        if (response.statusCode < 200 || response.statusCode >= 300) {
          await response.drain<void>();
          throw KubeFailure.http(response.statusCode, 'could not read logs for $pod');
        }
        if (cancelled) {
          response.detachSocket().then((s) => s.destroy()).ignore();
          return;
        }
        lines = response
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen(
              (raw) => controller.add(LogLine.parse(raw, pod: pod, container: container)),
              onError: (Object e, StackTrace st) => controller.addError(e, st),
              onDone: () => controller.close(),
              cancelOnError: true,
            );
      } catch (e, st) {
        if (!controller.isClosed) {
          controller.addError(e, st);
          await controller.close();
        }
      }
    };
    controller.onCancel = () async {
      cancelled = true;
      final sub = lines;
      if (sub != null) {
        await sub.cancel();
      } else {
        request?.abort();
      }
    };
    return controller.stream;
  }
}
