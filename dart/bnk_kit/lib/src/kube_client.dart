import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'json.dart';
import 'kubeconfig.dart';
import 'port_forward.dart';

/// Why a request could not be made or was refused.
sealed class KubeFailure implements Exception {
  const KubeFailure();

  const factory KubeFailure.unusable(String why) = UnusableFailure;
  const factory KubeFailure.http(int code, String body) = HttpFailure;
}

class UnusableFailure extends KubeFailure {
  final String why;
  const UnusableFailure(this.why);
  @override
  String toString() => why;
}

class HttpFailure extends KubeFailure {
  final int code;
  final String body;
  const HttpFailure(this.code, this.body);
  @override
  String toString() =>
      'apiserver returned $code: ${body.length > 400 ? body.substring(0, 400) : body}';
}

/// One authenticated connection to one apiserver.
///
/// Everything Field does to a cluster goes through here, because the apiserver
/// is the only address it is guaranteed to be able to reach: on the clusters
/// this was built against, the control plane has no route to the pod network,
/// so `services/proxy` and `pods/proxy` both time out. What does work is
/// anything the apiserver forwards to the kubelet, logs, exec, port-forward,
/// so those are the transport, and a pod's own port is reached by tunnelling
/// rather than by dialling it.
///
/// TLS is the platform-free part of this port. A kubeconfig names its own CA,
/// and that CA is the only one trusted for this server, not the system roots,
/// which would let anything with a public certificate impersonate a lab
/// apiserver. The client certificate and key go to the TLS stack as the PEM
/// bytes the kubeconfig carries; no keychain is involved on any platform.
class KubeClient {
  static const userAgent = 'bnkscope-field/0.1';

  /// The timeout that keeps a normal read from hanging forever. It is not
  /// applied to anything that stays open, a followed log or a tunnel, where
  /// thirty seconds would not be a timeout so much as a bug with a stopwatch.
  static const requestTimeout = Duration(seconds: 30);

  final KubeContext context;
  final HttpClient _http;

  KubeClient(this.context) : _http = _makeClient(context);

  static HttpClient _makeClient(KubeContext c) {
    final ca = c.caPEM;
    final security = SecurityContext(withTrustedRoots: ca == null);
    if (ca != null) security.setTrustedCertificatesBytes(ca);
    if (c.auth case ClientCertificateAuth(:final certPEM, :final keyPEM)) {
      security.useCertificateChainBytes(certPEM);
      security.usePrivateKeyBytes(keyPEM);
    }
    final http = HttpClient(context: security)
      ..userAgent = userAgent
      ..connectionTimeout = requestTimeout;
    if (c.insecureSkipTLSVerify) {
      http.badCertificateCallback = (cert, host, port) => true;
    }
    final serverName = c.tlsServerName;
    if (serverName != null && !c.insecureSkipTLSVerify) {
      // Check the certificate against the name the kubeconfig says it will
      // present, when that differs from the address dialled. Without this the
      // only way to use a forwarded apiserver is to stop verifying. The
      // client uses whatever socket the factory returns as-is, so for https
      // the handshake is done here, with the override name.
      http.connectionFactory = (uri, proxyHost, proxyPort) {
        if (proxyHost != null) return Socket.startConnect(proxyHost, proxyPort!);
        if (uri.scheme != 'https') return Socket.startConnect(uri.host, uri.port);
        final plain = Socket.startConnect(uri.host, uri.port);
        final secured = plain
            .then((task) => task.socket)
            .then((socket) => SecureSocket.secure(socket,
                host: serverName, context: security));
        return Future.value(ConnectionTask.fromSocket(
            secured, () => plain.then((task) => task.cancel())));
      };
    }
    return http;
  }

  /// Release the connection pool. Anything still streaming is cut.
  void close() => _http.close(force: true);

  // REST

  /// The URL for [path] under this context's server, with [query] sorted by
  /// key so the same request always spells the same. A value may be a
  /// `String` or an `Iterable<String>`; the latter repeats the key, which is
  /// how `exec` passes `command` once per argument.
  Uri url(String path, [Map<String, Object> query = const {}]) {
    final base = context.server;
    var basePath = base.path;
    if (basePath.endsWith('/')) basePath = basePath.substring(0, basePath.length - 1);
    final keys = query.keys.toList()..sort();
    return base.replace(
      path: '$basePath$path',
      queryParameters: keys.isEmpty ? null : {for (final k in keys) k: query[k]},
    );
  }

  Future<HttpClientRequest> open(String method, String path,
      [Map<String, Object> query = const {}]) async {
    if (context.auth case UnsupportedAuth(:final reason)) {
      throw KubeFailure.unusable(reason);
    }
    final request = await _http.openUrl(method, url(path, query));
    if (context.auth case BearerTokenAuth(:final token)) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    return request;
  }

  Future<Uint8List> get(String path, {Map<String, Object> query = const {}}) =>
      send('GET', path, query: query);

  /// Any method, with the body returned. [get] is the read path; this is
  /// everything that changes something.
  Future<Uint8List> send(String method, String path,
      {Map<String, Object> query = const {},
      List<int>? body,
      String? contentType}) async {
    final request = await open(method, path, query).timeout(requestTimeout);
    if (contentType != null) {
      request.headers.set(HttpHeaders.contentTypeHeader, contentType);
    }
    if (body != null) {
      request.contentLength = body.length;
      request.add(body);
    }
    final response = await request.close().timeout(requestTimeout);
    final data = await readAll(response).timeout(requestTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw KubeFailure.http(
          response.statusCode, utf8.decode(data, allowMalformed: true));
    }
    return data;
  }

  Future<T> getJson<T>(String path, T Function(JsonMap) parse,
      {Map<String, Object> query = const {}}) async {
    final data = await get(path, query: query);
    final decoded = jsonDecode(utf8.decode(data));
    if (decoded is! Map) {
      throw FormatException('expected a JSON object from $path');
    }
    return parse(Map<String, dynamic>.from(decoded));
  }

  static Future<Uint8List> readAll(Stream<List<int>> stream) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  // Upgraded channels

  /// A WebSocket onto a pod subresource. `v5.channel.k8s.io` for exec,
  /// `v4.channel.k8s.io` for port-forward; both answer 101 on 1.30+.
  Future<WebSocket> webSocket(String path,
      {required Map<String, Object> query,
      required List<String> protocols}) {
    if (context.auth case UnsupportedAuth(:final reason)) {
      throw KubeFailure.unusable(reason);
    }
    var uri = url(path, query);
    uri = uri.replace(scheme: uri.scheme == 'https' ? 'wss' : 'ws');
    final headers = <String, dynamic>{};
    if (context.auth case BearerTokenAuth(:final token)) {
      headers[HttpHeaders.authorizationHeader] = 'Bearer $token';
    }
    return WebSocket.connect(uri.toString(),
        protocols: protocols, headers: headers, customClient: _http);
  }

  PortForward portForward(
      {required String namespace, required String pod, required int port}) {
    return PortForward(
      dial: () async => IoChannel(await webSocket(
        '/api/v1/namespaces/$namespace/pods/$pod/portforward',
        query: {'ports': '$port'},
        protocols: const [PortForward.subprotocol],
      )),
      port: port,
    );
  }
}
