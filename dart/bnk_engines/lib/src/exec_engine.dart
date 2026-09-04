import 'dart:async';

import 'package:bnk_kit/bnk_kit.dart';

import 'brief.dart';
import 'observable.dart';

class ExecLine {
  final String text;
  final bool isError;
  const ExecLine(this.text, this.isError);
}

/// One command's output.
class ExecRun {
  static int _next = 0;
  final int id = _next++;
  final String command;
  final String container;
  final List<ExecLine> lines = [];
  bool finished = false;
  String? failure;
  ExecRun({required this.command, required this.container});
}

/// Runs commands in a container and keeps what they printed.
class ExecEngine extends Observable {
  /// Enough to look back over a short investigation without holding a
  /// session of output in memory forever.
  static const historyLimit = 40;

  final List<ExecRun> _runs = [];
  bool _running = false;
  StreamSubscription<ExecChunk>? _subscription;

  List<ExecRun> get runs => _runs;
  bool get running => _running;

  void run(List<String> command,
      {required String container, required String namespace, required String pod, required KubeClient client}) {
    if (command.isEmpty) return;
    _subscription?.cancel();
    _running = true;
    final run = ExecRun(command: Argv.join(command), container: container);
    _runs.add(run);
    if (_runs.length > historyLimit) _runs.removeRange(0, _runs.length - historyLimit);
    _subscription = client.exec(namespace: namespace, pod: pod, container: container, command: command).listen(
          (chunk) => _append(run, chunk),
          onError: (Object e) => _finish(run, brief(e)),
          onDone: () => _finish(run, null),
          cancelOnError: true,
        );
    notify();
  }

  void cancel() {
    _subscription?.cancel();
    _subscription = null;
    _running = false;
    notify();
  }

  void clear() {
    cancel();
    _runs.clear();
    notify();
  }

  void _append(ExecRun run, ExecChunk chunk) {
    appendChunk(run.lines, chunk.text, isError: chunk.source == ExecSource.stderr);
    notify();
  }

  /// Output arrives in arbitrarily sized pieces, not lines: a chunk can end
  /// mid-line and the next one continues it. Splitting each chunk on its
  /// own would break a table row in half.
  ///
  /// A chunk that ends in a newline leaves an empty last line: the cursor,
  /// waiting at the start of the next one. The next chunk fills that line
  /// rather than adding another, whichever stream it comes from; otherwise
  /// every frame boundary would print as a blank line. A chunk that ends
  /// mid-line is continued only by the same stream.
  static void appendChunk(List<ExecLine> lines, String text, {required bool isError}) {
    final pieces = text.split('\n');
    if (lines.isNotEmpty) {
      final last = lines.last;
      if (last.text.isEmpty) {
        lines[lines.length - 1] = ExecLine(pieces.removeAt(0), isError);
      } else if (last.isError == isError && pieces.first.isNotEmpty) {
        lines[lines.length - 1] = ExecLine(last.text + pieces.removeAt(0), isError);
      }
    }
    for (final piece in pieces) {
      lines.add(ExecLine(piece, isError));
    }
  }

  void _finish(ExecRun run, String? failure) {
    if (run.finished) return;
    run.finished = true;
    run.failure = failure;
    // Commands that print nothing and exit are common; a trailing blank line
    // from the final newline is not output.
    if (run.lines.isNotEmpty && run.lines.last.text.isEmpty) run.lines.removeLast();
    _running = false;
    notify();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}
