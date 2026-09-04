/// Test support: a fake apiserver on loopback with throwaway certificates.
///
/// Lives in `lib/` rather than `test/` so that packages built on top of this
/// one can drive their code through real sockets, real TLS and the real
/// WebSocket framing without a cluster. Nothing here ships in an app.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'src/kubeconfig.dart';

/// Where the fixtures are, relative to the current directory. Tests in this
/// package run from its root; a dependent package passes its own path.
class Fixtures {
  final String dir;
  const Fixtures(this.dir);

  Uint8List tls(String name) => File('$dir/tls/$name.txt').readAsBytesSync();
  Uint8List get metricsGz => File('$dir/metrics.gz').readAsBytesSync();

  /// A kubeconfig for [api] as a file would carry it, PEM inline as base64,
  /// with the server name the fixtures' certificate is issued for.
  String kubeconfig(FakeApiserver api, {String context = 'fake', String cluster = 'fake'}) {
    String b64(String name) => base64.encode(tls(name));
    return '''
apiVersion: v1
kind: Config
clusters:
- name: $cluster
  cluster:
    server: https://127.0.0.1:${api.port}
    tls-server-name: apiserver.test
    certificate-authority-data: ${b64('ca-cert')}
contexts:
- name: $context
  context:
    cluster: $cluster
    user: tester
current-context: $context
users:
- name: tester
  user:
    client-certificate-data: ${b64('client-cert')}
    client-key-data: ${b64('client-key')}
''';
  }

  KubeContext context(FakeApiserver api,
      {KubeAuth? auth, bool pinCA = true, String? tlsServerName = 'apiserver.test', bool insecure = false}) {
    return KubeContext(
      name: 'fake',
      clusterName: 'fake',
      server: Uri.parse('https://127.0.0.1:${api.port}'),
      caPEM: pinCA ? tls('ca-cert') : null,
      tlsServerName: tlsServerName,
      insecureSkipTLSVerify: insecure,
      namespace: null,
      auth: auth ?? ClientCertificateAuth(tls('client-cert'), tls('client-key')),
    );
  }
}

typedef RouteHandler = FutureOr<Object?> Function(HttpRequest request);

/// Just enough apiserver to answer what the client asks.
///
/// Built-in routes cover a small cluster: two TMM pods carrying an exporter,
/// a broken pod, two nodes, a warning event, and the three upgraded channels.
/// [routes] override or add paths; a handler returns a JSON-encodable object,
/// or `null` after having written the response itself.
class FakeApiserver {
  final Fixtures fixtures;
  final Map<String, RouteHandler> routes = {};
  late final HttpServer server;
  int portForwardRequests = 0;

  FakeApiserver({this.fixtures = const Fixtures('test/fixtures')});

  Future<void> start() async {
    final context = SecurityContext(withTrustedRoots: false)
      ..useCertificateChainBytes(fixtures.tls('server-cert'))
      ..usePrivateKeyBytes(fixtures.tls('server-key'))
      ..setTrustedCertificatesBytes(fixtures.tls('ca-cert'));
    server = await HttpServer.bindSecure('127.0.0.1', 0, context, requestClientCertificate: true);
    server.listen(_handle);
  }

  int get port => server.port;

  Future<void> stop() => server.close(force: true);

  static Map<String, Object> pod(String name, String namespace,
      {Map<String, String> labels = const {}, String phase = 'Running', bool exporter = false,
      bool ready = true, int restarts = 0}) {
    return {
      'metadata': {'name': name, 'namespace': namespace, 'labels': labels,
        'creationTimestamp': '2026-09-04T03:23:18Z'},
      'spec': {
        'nodeName': 'n1',
        'containers': [{'name': 'main', 'image': 'example/main:1'}],
        if (exporter) 'ephemeralContainers': [{'name': 'tmm-stat-exporter', 'image': 'example/exporter:1'}],
        'volumes': [{'name': 'f5tmstat'}],
      },
      'status': {
        'phase': phase,
        'containerStatuses': [{'name': 'main', 'ready': ready, 'restartCount': restarts}],
        if (exporter) 'ephemeralContainerStatuses': [{'name': 'tmm-stat-exporter', 'ready': true}],
      },
    };
  }

  List<Map<String, Object>> get pods => [
        pod('tmm-a', 'ns', labels: {'app': 'f5-tmm', 'svc.dpu.nvidia.com/service': 'tmm'}, exporter: true),
        pod('tmm-b', 'ns', labels: {'app': 'f5-tmm'}, exporter: true),
        pod('broken', 'ns', phase: 'Pending', ready: false, restarts: 7),
        pod('coredns', 'kube-system', labels: {'k8s-app': 'kube-dns'}),
      ];

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    final query = request.uri.queryParameters;
    final clientCN = request.certificate?.subject.replaceFirst('/CN=', '');
    Future<void> json(Object body, [int status = 200]) async {
      request.response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(body));
      await request.response.close();
    }

    final custom = routes[path];
    if (custom != null) {
      final body = await custom(request);
      if (body != null) await json(body);
      return;
    }

    switch (path) {
      case '/version':
        await json({'gitVersion': 'v1.30.0-fake', 'platform': 'linux/amd64'});
      case '/whoami':
        await json({
          'certificate': clientCN,
          'authorization': request.headers.value('authorization'),
          'userAgent': request.headers.value('user-agent'),
        });
      case '/apis':
        await json({'groups': [
          {'name': 'apps', 'preferredVersion': {'groupVersion': 'apps/v1'}},
        ]});
      case '/api/v1/nodes':
        await json({'items': [
          {'metadata': {'name': 'n1'}, 'status': {'conditions': [{'type': 'Ready', 'status': 'True'}],
            'nodeInfo': {'architecture': 'amd64', 'kubeletVersion': 'v1.30.0'},
            'allocatable': {'nvidia.com/GA104GL_RTX_A4000': '2'}}},
          {'metadata': {'name': 'n2'}, 'status': {'conditions': [{'type': 'Ready', 'status': 'False'}]}},
        ]});
      case '/api/v1/namespaces':
        await json({'items': [{'metadata': {'name': 'ns'}}, {'metadata': {'name': 'kube-system'}}]});
      case '/api/v1/pods':
        final selector = query['labelSelector'];
        final wanted = selector?.split('=');
        await json({'items': [
          for (final p in pods)
            if (wanted == null ||
                ((p['metadata'] as Map)['labels'] as Map)[wanted[0]] == wanted[1]) p
        ]});
      case '/api/v1/namespaces/ns/pods':
        await json({'items': [for (final p in pods) if ((p['metadata'] as Map)['namespace'] == 'ns') p]});
      case '/api/v1/events':
        await json({'items': [
          {'metadata': {'name': 'e1', 'namespace': 'ns'}, 'type': 'Warning', 'reason': 'BackOff',
            'message': '(combined from similar events): Back-off restarting failed container',
            'count': 12, 'lastTimestamp': DateTime.now().toUtc().toIso8601String(),
            'involvedObject': {'kind': 'Pod', 'name': 'broken', 'namespace': 'ns'}},
          {'metadata': {'name': 'e2', 'namespace': 'ns'}, 'type': 'Warning', 'reason': 'Old',
            'message': 'long ago', 'lastTimestamp': '2020-01-01T00:00:00Z',
            'involvedObject': {'kind': 'Pod', 'name': 'tmm-a', 'namespace': 'ns'}},
        ]});
      case '/forbidden':
        request.response
          ..statusCode = 403
          ..write('{"kind":"Status","message":"pods is forbidden"}');
        await request.response.close();
      default:
        if (path.endsWith('/log')) {
          request.response.headers.contentType = ContentType.text;
          request.response.write('2026-09-04T03:23:18.000000001Z first line\n');
          await request.response.flush();
          request.response.write('E0904 03:23:19.000000       1 x.go:1] second line\nno stamp at all\n');
          await request.response.close();
        } else if (path.endsWith('/portforward')) {
          portForwardRequests++;
          final socket = await WebSocketTransformer.upgrade(request,
              protocolSelector: (protocols) => protocols.first);
          _portForward(socket, int.parse(query['ports']!));
        } else if (path.endsWith('/exec')) {
          final socket = await WebSocketTransformer.upgrade(request,
              protocolSelector: (protocols) => protocols.first);
          _exec(socket, request.uri.queryParametersAll['command'] ?? const []);
        } else {
          await json({'kind': 'Status', 'code': 404, 'message': 'not found: $path'}, 404);
        }
    }
  }

  /// v4.channel.k8s.io: port acks on both channels, then an HTTP/1.1 server
  /// on channel 0 that stays open for the next request.
  void _portForward(WebSocket socket, int port) async {
    final metricsGz = fixtures.metricsGz;
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
