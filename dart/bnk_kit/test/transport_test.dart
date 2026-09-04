/// The transport against a fake apiserver on loopback: mutual TLS from PEM
/// bytes, the CA pin, the tls-server-name override, and the three upgraded
/// channels over real sockets. This is the test the Swift package could not
/// write, because its identity lived in a keychain.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bnk_kit/bnk_kit.dart';
import 'package:test/test.dart';

Uint8List fixture(String name) =>
    File('test/fixtures/tls/$name.txt').readAsBytesSync();

/// Just enough apiserver to answer what the client asks.
class FakeApiserver {
  late final HttpServer server;
  final metricsGz = File('test/fixtures/metrics.gz').readAsBytesSync();
  int portForwardRequests = 0;

  Future<void> start() async {
    final context = SecurityContext(withTrustedRoots: false)
      ..useCertificateChainBytes(fixture('server-cert'))
      ..usePrivateKeyBytes(fixture('server-key'))
      ..setTrustedCertificatesBytes(fixture('ca-cert'));
    server = await HttpServer.bindSecure('127.0.0.1', 0, context,
        requestClientCertificate: true);
    server.listen(_handle);
  }

  int get port => server.port;

  Future<void> stop() => server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    final clientCN = request.certificate?.subject.replaceFirst('/CN=', '');
    if (path == '/version') {
      request.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'gitVersion': 'v1.30.0-fake', 'platform': 'linux/amd64'}));
      await request.response.close();
    } else if (path == '/whoami') {
      request.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'certificate': clientCN,
          'authorization': request.headers.value('authorization'),
          'userAgent': request.headers.value('user-agent'),
        }));
      await request.response.close();
    } else if (path == '/api/v1/nodes') {
      request.response.write(jsonEncode({
        'items': [
          {'metadata': {'name': 'n1'}, 'status': {'conditions': [{'type': 'Ready', 'status': 'True'}]}},
          {'metadata': {'name': 'n2'}, 'status': {'conditions': [{'type': 'Ready', 'status': 'False'}]}},
        ]
      }));
      await request.response.close();
    } else if (path == '/forbidden') {
      request.response
        ..statusCode = 403
        ..write('{"kind":"Status","message":"pods is forbidden"}');
      await request.response.close();
    } else if (path.endsWith('/log')) {
      request.response.headers.contentType = ContentType.text;
      request.response.write('2026-09-04T03:23:18.000000001Z first line\n');
      await request.response.flush();
      request.response.write('E0904 03:23:19.000000       1 x.go:1] second line\nno stamp at all\n');
      await request.response.close();
    } else if (path.endsWith('/portforward')) {
      portForwardRequests++;
      final socket = await WebSocketTransformer.upgrade(request,
          protocolSelector: (protocols) => protocols.first);
      _portForward(socket, int.parse(request.uri.queryParameters['ports']!));
    } else if (path.endsWith('/exec')) {
      final socket = await WebSocketTransformer.upgrade(request,
          protocolSelector: (protocols) => protocols.first);
      _exec(socket, request.uri.queryParametersAll['command'] ?? const []);
    } else {
      request.response.statusCode = 404;
      await request.response.close();
    }
  }

  /// v4.channel.k8s.io: port acks on both channels, then an HTTP/1.1 server
  /// on channel 0 that stays open for the next request.
  void _portForward(WebSocket socket, int port) async {
    socket.add([0, port & 0xff, port >> 8]);
    socket.add([1, port & 0xff, port >> 8]);
    final pending = <int>[];
    await for (final message in socket) {
      if (message is! List<int> || message.isEmpty || message[0] != 0) continue;
      pending.addAll(message.sublist(1));
      final head = utf8.decode(pending);
      final end = head.indexOf('\r\n\r\n');
      if (end < 0) continue;
      pending.clear();
      final target = head.split(' ')[1];
      final List<int> reply;
      if (target == '/metrics') {
        // Chunked and gzipped, which is what Go does for a streamed body.
        final half = metricsGz.length ~/ 2;
        reply = [
          ...utf8.encode('HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Encoding: gzip\r\nTransfer-Encoding: chunked\r\n\r\n'),
          ...utf8.encode('${half.toRadixString(16)}\r\n'),
          ...metricsGz.sublist(0, half),
          ...utf8.encode('\r\n${(metricsGz.length - half).toRadixString(16)};ext=1\r\n'),
          ...metricsGz.sublist(half),
          ...utf8.encode('\r\n0\r\n\r\n'),
        ];
      } else if (target == '/plain') {
        const body = 'plain_metric 42\n';
        reply = utf8.encode('HTTP/1.1 200 OK\r\nContent-Length: ${body.length}\r\n\r\n$body');
      } else {
        reply = utf8.encode('HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n');
      }
      // Frames cut at awkward places, so the reader has to buffer across
      // them: mid-status-line, mid-header, mid-chunk.
      for (var i = 0; i < reply.length; i += 7) {
        socket.add([0, ...reply.sublist(i, i + 7 > reply.length ? reply.length : i + 7)]);
      }
      if (target != '/metrics' && target != '/plain') {
        await socket.close();
        return;
      }
    }
  }

  /// v5.channel.k8s.io: stdout, stderr, then a Status on channel 3.
  void _exec(WebSocket socket, List<String> command) async {
    socket.add([1, ...utf8.encode('ran: ${command.join(' ')}\n')]);
    socket.add([2, ...utf8.encode('a warning\n')]);
    final status = command.first == 'false'
        ? {'status': 'Failure', 'message': 'command terminated with exit code 1', 'reason': 'NonZeroExitCode'}
        : {'status': 'Success'};
    socket.add([3, ...utf8.encode(jsonEncode(status))]);
    await socket.close();
  }
}

KubeContext contextFor(FakeApiserver api,
        {KubeAuth? auth, bool pinCA = true, String? tlsServerName, bool insecure = false}) =>
    KubeContext(
      name: 'fake',
      clusterName: 'fake',
      server: Uri.parse('https://127.0.0.1:${api.port}'),
      caPEM: pinCA ? fixture('ca-cert') : null,
      tlsServerName: tlsServerName,
      insecureSkipTLSVerify: insecure,
      namespace: null,
      auth: auth ?? ClientCertificateAuth(fixture('client-cert'), fixture('client-key')),
    );

void main() {
  late FakeApiserver api;

  setUpAll(() async {
    api = FakeApiserver();
    await api.start();
  });

  tearDownAll(() => api.stop());

  test('presents the client certificate from PEM bytes and pins the CA', () async {
    final client = KubeClient(contextFor(api, tlsServerName: 'apiserver.test'));
    final who = jsonDecode(utf8.decode(await client.get('/whoami'))) as Map;
    expect(who['certificate'], 'bnkfield test client');
    expect(who['authorization'], isNull);
    expect(who['userAgent'], KubeClient.userAgent);
    final version = await client.version();
    expect(version.gitVersion, 'v1.30.0-fake');
    final nodes = await client.nodes();
    expect(nodes.where((n) => n.isReady).length, 1);
    client.close();
  });

  test('sends a bearer token when that is what the kubeconfig carries', () async {
    final client = KubeClient(contextFor(api,
        auth: const BearerTokenAuth('secret-token'), tlsServerName: 'apiserver.test'));
    final who = jsonDecode(utf8.decode(await client.get('/whoami'))) as Map;
    expect(who['certificate'], isNull);
    expect(who['authorization'], 'Bearer secret-token');
    client.close();
  });

  /// The server's certificate names `apiserver.test`, and the client dials
  /// 127.0.0.1. Without the override that is a mismatch and must fail; with
  /// it, the name the kubeconfig gives is the one checked.
  test('honours tls-server-name, and refuses the connection without it', () async {
    final mismatched = KubeClient(contextFor(api));
    await expectLater(mismatched.get('/version'), throwsA(isA<HandshakeException>()));
    mismatched.close();
  });

  test('refuses a server whose CA is not the pinned one', () async {
    // The system roots do not contain the test CA either, so an unpinned
    // context must also fail: nothing with a public certificate gets in.
    final unpinned = KubeClient(contextFor(api, pinCA: false, tlsServerName: 'apiserver.test'));
    await expectLater(unpinned.get('/version'), throwsA(isA<HandshakeException>()));
    unpinned.close();
  });

  test('insecure-skip-tls-verify accepts anything', () async {
    final client = KubeClient(contextFor(api, pinCA: false, insecure: true));
    expect((await client.version()).gitVersion, 'v1.30.0-fake');
    client.close();
  });

  test('reports the status and body of a refusal', () async {
    final client = KubeClient(contextFor(api, tlsServerName: 'apiserver.test'));
    await expectLater(
        client.get('/forbidden'),
        throwsA(isA<HttpFailure>()
            .having((f) => f.code, 'code', 403)
            .having((f) => f.toString(), 'text', contains('forbidden'))));
    client.close();
  });

  test('scrapes over a held tunnel, gzipped and chunked, then plain, then reuses it', () async {
    final client = KubeClient(contextFor(api, tlsServerName: 'apiserver.test'));
    final scraper = PodScraper(client: client, namespace: 'ns', pod: 'tmm', port: 9099);
    final samples = await scraper.scrape();
    expect(samples.length, greaterThan(500));
    expect(samples.any((s) => s.name == 'f5tmm_up' && s.value == 1), isTrue);

    final again = await scraper.scrape(path: '/plain');
    expect(again, [const Sample('plain_metric', {}, 42)]);
    expect(scraper.reconnects, 0);
    expect(api.portForwardRequests, 1, reason: 'one tunnel served both scrapes');

    // A 404 with Connection: close ends the tunnel; the next scrape rebuilds it.
    await expectLater(scraper.scrape(path: '/missing'), throwsA(isA<HttpFailure>()));
    final rebuilt = await scraper.scrape(path: '/plain');
    expect(rebuilt.length, 1);
    expect(api.portForwardRequests, 2);
    await scraper.stop();
    client.close();
  });

  test('one-shot scrape opens and closes its own tunnel', () async {
    final client = KubeClient(contextFor(api, tlsServerName: 'apiserver.test'));
    final before = api.portForwardRequests;
    final samples = await client.scrape(namespace: 'ns', pod: 'tmm', port: 9099, path: '/plain');
    expect(samples.single.name, 'plain_metric');
    expect(api.portForwardRequests, before + 1);
    client.close();
  });

  test('exec streams stdout and stderr and reports the exit', () async {
    final client = KubeClient(contextFor(api, tlsServerName: 'apiserver.test'));
    final chunks = await client
        .exec(namespace: 'ns', pod: 'tmm', container: 'f5-tmm', command: ['tmctl', '-d', 'blade'])
        .toList();
    expect(chunks.map((c) => c.source), [ExecSource.stdout, ExecSource.stderr]);
    expect(chunks.first.text, 'ran: tmctl -d blade\n');

    await expectLater(
        client.exec(namespace: 'ns', pod: 'tmm', container: null, command: ['false']).toList(),
        throwsA(isA<ExecException>().having((e) => e.message, 'message', contains('exit code 1'))));
    client.close();
  });

  test('follows a log, parsing what it can and keeping the rest', () async {
    final client = KubeClient(contextFor(api, tlsServerName: 'apiserver.test'));
    final lines = await client.logStream(namespace: 'ns', pod: 'p', container: 'c').toList();
    expect(lines.length, 3);
    expect(lines[0].at, isNotNull);
    expect(lines[0].text, 'first line');
    expect(lines[1].level, LogLevel.error);
    expect(lines[2].at, isNull);
    expect(lines[2].text, 'no stamp at all');

    // Cancelling after the first line must not hang.
    final first = await client.logStream(namespace: 'ns', pod: 'p').first
        .timeout(const Duration(seconds: 5));
    expect(first.pod, 'p');
    client.close();
  });
}
