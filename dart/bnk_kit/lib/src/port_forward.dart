import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'log.dart';

/// The two things a tunnel needs from a WebSocket: messages in, bytes out.
/// Kept abstract so the framing can be tested without a cluster.
abstract interface class WsChannel {
  Stream<dynamic> get messages;
  void send(List<int> frame);
  Future<void> close();
}

class IoChannel implements WsChannel {
  final WebSocket socket;
  IoChannel(this.socket);
  @override
  Stream<dynamic> get messages => socket;
  @override
  void send(List<int> frame) => socket.add(frame);
  @override
  Future<void> close() => socket.close(WebSocketStatus.goingAway);
}

enum PortForwardFailureKind { remote, closed, transport, malformed }

class PortForwardException implements Exception {
  final PortForwardFailureKind kind;
  final String message;
  const PortForwardException(this.kind, [this.message = '']);

  @override
  String toString() => switch (kind) {
        PortForwardFailureKind.remote => 'port-forward refused: $message',
        PortForwardFailureKind.closed =>
          'the tunnel closed before the reply was complete',
        PortForwardFailureKind.transport => 'the tunnel failed: $message',
        PortForwardFailureKind.malformed => 'the reply could not be read: $message',
      };
}

/// The pieces of an HTTP/1.1 response Field needs.
class HttpReply {
  final int status;
  final Map<String, String> headers;
  final Uint8List body;

  const HttpReply(
      {required this.status, required this.headers, required this.body});

  /// `true` when the peer said the body is gzipped. It is up to the caller to
  /// inflate; this type does not guess at content.
  bool get isGzipped =>
      headers['content-encoding']?.toLowerCase().contains('gzip') ?? false;
}

/// A TCP tunnel into a pod, over `pods/portforward`.
///
/// This is what lets Field scrape a port nothing outside the pod can dial. TMM
/// hooks inbound TCP on its dataplane interfaces, so the exporter's :9099 is
/// unreachable from off the pod, but port-forward is served by the kubelet,
/// which enters the pod's network namespace and connects to loopback inside
/// it. The hooking never sees it.
///
/// The framing is `v4.channel.k8s.io`: every binary message is one channel
/// byte followed by payload. Port *n* of the request owns channels 2n (data)
/// and 2n+1 (error), and the first message on each carries that port as a
/// little-endian uint16 so a client forwarding several ports can tell them
/// apart. One port is forwarded here, so channel 0 is the connection and
/// channel 1 is how the kubelet reports that it could not open it.
///
/// Calls on one tunnel are expected one at a time, as the scraper makes them.
class PortForward {
  static const subprotocol = 'v4.channel.k8s.io';

  final Future<WsChannel> Function() _dial;
  final int port;
  WsChannel? _channel;
  StreamIterator<dynamic>? _messages;
  bool _started = false;
  bool _atEnd = false;
  final _buffer = <int>[];
  String _remoteError = '';

  /// Why the socket stopped, if it stopped with an error. Until this was kept
  /// a Local Network denial, a TLS client-certificate failure and a reply that
  /// genuinely ended early all reported the same "closed before complete".
  Object? _lastError;

  PortForward({required Future<WsChannel> Function() dial, required this.port})
      : _dial = dial;

  bool get isUsable => _started && !_atEnd;

  Future<void> connect() async {
    if (_started) return;
    _started = true;
    try {
      final channel = await _dial();
      _channel = channel;
      _messages = StreamIterator(channel.messages);
    } catch (e) {
      Log.tunnel.severe('connect failed on :$port: $e');
      _lastError = e;
      _atEnd = true;
    }
  }

  Future<void> close() async {
    _atEnd = true;
    final channel = _channel;
    _channel = null;
    _messages = null;
    if (channel != null) {
      try {
        await channel.close();
      } catch (_) {}
    }
  }

  // Reading

  /// Pull one more frame's payload into the buffer. False once the data
  /// channel has ended.
  Future<bool> _fill() async {
    while (true) {
      if (_atEnd) return false;
      final messages = _messages;
      if (messages == null) return false;
      final bool more;
      try {
        more = await messages.moveNext();
      } catch (e) {
        Log.tunnel.severe('receive failed on :$port: $e');
        _lastError = e;
        _atEnd = true;
        return false;
      }
      if (!more) {
        _atEnd = true;
        return false;
      }
      final frame = messages.current;
      if (frame is! List<int> || frame.isEmpty) continue;
      final channel = frame[0];
      final payload = frame.sublist(1);
      switch (channel) {
        case 0:
          // Each channel opens with its port number; that is not payload.
          if (payload.length == 2 && _isPortAck(payload)) continue;
          if (payload.isEmpty) continue;
          _buffer.addAll(payload);
          return true;
        case 1:
          if (payload.length == 2 && _isPortAck(payload)) continue;
          _remoteError += utf8.decode(payload, allowMalformed: true);
        default:
          continue;
      }
    }
  }

  bool _isPortAck(List<int> payload) =>
      (payload[0] | (payload[1] << 8)) == port;

  Future<Uint8List> _take(int n) async {
    while (_buffer.length < n) {
      if (!await _fill()) throw _failure();
    }
    final out = Uint8List.fromList(_buffer.sublist(0, n));
    _buffer.removeRange(0, n);
    return out;
  }

  /// One CRLF-terminated line, without the terminator.
  Future<String> _takeLine() async {
    while (true) {
      for (var i = 0; i + 1 < _buffer.length; i++) {
        if (_buffer[i] == 13 && _buffer[i + 1] == 10) {
          final text = utf8.decode(_buffer.sublist(0, i), allowMalformed: true);
          _buffer.removeRange(0, i + 2);
          return text;
        }
      }
      if (!await _fill()) throw _failure();
    }
  }

  PortForwardException _failure() {
    if (_remoteError.isNotEmpty) {
      return PortForwardException(PortForwardFailureKind.remote, _remoteError);
    }
    final e = _lastError;
    if (e != null) {
      return PortForwardException(PortForwardFailureKind.transport, '$e');
    }
    return const PortForwardException(PortForwardFailureKind.closed);
  }

  // HTTP

  /// A GET over the tunnel, leaving the connection open for the next one.
  ///
  /// Keeping it open is the whole point: a fresh port-forward per scrape means
  /// a WebSocket upgrade through the apiserver and a new connection into the
  /// pod every time, which on a real device over wifi cost several seconds,
  /// far more than reading the 14 KB body.
  ///
  /// The reply is read frame by frame rather than "until the peer hangs up",
  /// which is what a keep-alive connection rules out. Both framings the
  /// exporter can produce are handled: `Content-Length` for a body Go
  /// buffered, and chunked for one it streamed, which is what a gzipped scrape
  /// is, since Go cannot know the compressed length in advance.
  Future<HttpReply> get(String path,
      {Map<String, String> headers = const {}}) async {
    await connect();
    final channel = _channel;
    if (channel == null || _atEnd) throw _failure();

    final head = StringBuffer('GET $path HTTP/1.1\r\nHost: 127.0.0.1:$port\r\n');
    final names = headers.keys.toList()..sort();
    for (final k in names) {
      head.write('$k: ${headers[k]}\r\n');
    }
    head.write('\r\n');
    try {
      channel.send([0, ...utf8.encode(head.toString())]);
    } catch (e) {
      Log.tunnel.severe('send failed on :$port: $e');
      _lastError = e;
      _atEnd = true;
      throw _failure();
    }

    final statusLine = await _takeLine();
    final parts = statusLine.split(' ');
    final status = parts.length >= 2 ? int.tryParse(parts[1]) : null;
    if (status == null) {
      throw PortForwardException(
          PortForwardFailureKind.malformed, 'bad status line "$statusLine"');
    }

    final fields = <String, String>{};
    while (true) {
      final line = await _takeLine();
      if (line.isEmpty) break;
      final c = line.indexOf(':');
      if (c < 0) continue;
      fields[line.substring(0, c).toLowerCase()] =
          line.substring(c + 1).trim();
    }

    final Uint8List body;
    final length = int.tryParse(fields['content-length'] ?? '');
    if (fields['transfer-encoding']?.toLowerCase().contains('chunked') ?? false) {
      body = await _takeChunkedBody();
    } else if (length != null) {
      body = await _take(length);
    } else {
      // No framing at all means the body ends when the connection does.
      while (await _fill()) {}
      body = Uint8List.fromList(_buffer);
      _buffer.clear();
      _atEnd = true;
    }

    // Honour a peer that asked to close, so the next call reconnects rather
    // than writing into a socket that is going away.
    if (fields['connection']?.toLowerCase().contains('close') ?? false) {
      _atEnd = true;
    }
    return HttpReply(status: status, headers: fields, body: body);
  }

  /// RFC 9112 §7.1: each chunk is a hex length, CRLF, that many bytes, CRLF.
  /// A zero length ends the body, optionally followed by trailers.
  Future<Uint8List> _takeChunkedBody() async {
    final out = BytesBuilder(copy: false);
    while (true) {
      final header = await _takeLine();
      final hex = header.split(';').first.trim();
      final size = int.tryParse(hex, radix: 16);
      if (size == null) {
        throw PortForwardException(
            PortForwardFailureKind.malformed, 'chunk size "$header"');
      }
      if (size == 0) {
        while ((await _takeLine()).isNotEmpty) {} // trailers, usually none
        return out.takeBytes();
      }
      out.add(await _take(size));
      await _takeLine(); // CRLF after the chunk
    }
  }
}
