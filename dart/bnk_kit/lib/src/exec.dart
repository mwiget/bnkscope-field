import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'json.dart';
import 'kube_client.dart';

enum ExecSource { stdout, stderr }

class ExecChunk {
  final ExecSource source;
  final String text;
  const ExecChunk(this.source, this.text);
}

class ExecException implements Exception {
  final String message;
  const ExecException(this.message);
  @override
  String toString() => message;
}

/// What the apiserver reports on channel 3 when the command is done.
class _ExecStatus {
  final String? status;
  final String? message;
  final String? reason;
  _ExecStatus(JsonMap j)
      : status = asString(j['status']),
        message = asString(j['message']),
        reason = asString(j['reason']);
}

/// Running a command inside a container, over `pods/exec`.
///
/// The framing is `v5.channel.k8s.io`, the same shape as port-forward's: one
/// channel byte then payload. Here channel 0 is stdin, 1 stdout, 2 stderr,
/// and 3 carries a JSON `Status` at the end saying whether the command
/// succeeded, the only place an exit code appears, since the WebSocket closes
/// cleanly either way.
///
/// No TTY is requested, and that is a deliberate limit rather than an
/// oversight. A TTY means a terminal emulator: cursor addressing, scroll
/// regions, the alternate screen. What this is for is `tmctl`, `configview`
/// and `bdt_cli`, commands that print and exit, and pretending to be a shell
/// that cannot run `vi` would be worse than not offering one.
extension ExecApi on KubeClient {
  /// Run [command] and stream its output.
  ///
  /// The stream finishes when the command exits. A non-zero exit arrives as an
  /// [ExecException] carrying the apiserver's own message, which is where the
  /// exit code lives. Cancelling the subscription closes the socket.
  Stream<ExecChunk> exec(
      {required String namespace,
      required String pod,
      String? container,
      required List<String> command}) {
    final controller = StreamController<ExecChunk>();
    WebSocket? socket;
    var cancelled = false;

    controller.onListen = () async {
      try {
        final query = <String, Object>{
          'stdout': 'true',
          'stderr': 'true',
          'stdin': 'false',
          'tty': 'false',
          if (container != null) 'container': container,
          'command': command,
        };
        final ws = await webSocket('/api/v1/namespaces/$namespace/pods/$pod/exec',
            query: query, protocols: const ['v5.channel.k8s.io']);
        socket = ws;
        if (cancelled) {
          await ws.close(WebSocketStatus.goingAway);
          return;
        }
        _ExecStatus? status;
        await for (final message in ws) {
          if (message is! List<int> || message.length < 2) continue;
          final channel = message[0];
          final payload = message.sublist(1);
          switch (channel) {
            case 1:
              controller.add(ExecChunk(
                  ExecSource.stdout, utf8.decode(payload, allowMalformed: true)));
            case 2:
              controller.add(ExecChunk(
                  ExecSource.stderr, utf8.decode(payload, allowMalformed: true)));
            case 3:
              try {
                final decoded = jsonDecode(utf8.decode(payload));
                if (decoded is Map) {
                  status = _ExecStatus(Map<String, dynamic>.from(decoded));
                }
              } on FormatException {
                // A status that cannot be read is treated as absent.
              }
            default:
              continue;
          }
        }
        // "Success" is the only status that is not a problem. A non-zero
        // exit arrives here as a failure with the reason.
        if (status != null && status.status != 'Success') {
          throw ExecException(
              status.message ?? status.reason ?? 'the command failed');
        }
        await controller.close();
      } catch (e, st) {
        if (!controller.isClosed) {
          controller.addError(e, st);
          await controller.close();
        }
      }
    };
    controller.onCancel = () {
      cancelled = true;
      socket?.close(WebSocketStatus.goingAway);
    };
    return controller.stream;
  }
}
