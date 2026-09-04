import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:yaml/yaml.dart';

import 'yaml_emit.dart';

/// What Field can present to an apiserver. [UnsupportedAuth] is a first-class
/// case, not an error: the context is listed with its reason.
sealed class KubeAuth {
  const KubeAuth();
}

class ClientCertificateAuth extends KubeAuth {
  final Uint8List certPEM;
  final Uint8List keyPEM;
  const ClientCertificateAuth(this.certPEM, this.keyPEM);

  @override
  bool operator ==(Object other) =>
      other is ClientCertificateAuth &&
      _bytesEqual(other.certPEM, certPEM) &&
      _bytesEqual(other.keyPEM, keyPEM);

  @override
  int get hashCode => Object.hash(certPEM.length, keyPEM.length);
}

class BearerTokenAuth extends KubeAuth {
  final String token;
  const BearerTokenAuth(this.token);

  @override
  bool operator ==(Object other) =>
      other is BearerTokenAuth && other.token == token;

  @override
  int get hashCode => token.hashCode;
}

class UnsupportedAuth extends KubeAuth {
  final String reason;
  const UnsupportedAuth(this.reason);

  @override
  bool operator ==(Object other) =>
      other is UnsupportedAuth && other.reason == reason;

  @override
  int get hashCode => reason.hashCode;
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

class KubeContext {
  final String name;
  final String clusterName;
  final Uri server;
  final Uint8List? caPEM;

  /// The name the server's certificate is checked against, when that is not
  /// the address dialled.
  ///
  /// A cluster reached through a forward, a lab apiserver bound to loopback
  /// and published on another address, presents a certificate for the name it
  /// knows itself by, not the one you connected to. Ignoring this field means
  /// such a cluster can only be used by turning verification off altogether,
  /// which is a much bigger hammer.
  final String? tlsServerName;
  final bool insecureSkipTLSVerify;
  final String? namespace;
  final KubeAuth auth;

  const KubeContext({
    required this.name,
    required this.clusterName,
    required this.server,
    required this.caPEM,
    required this.tlsServerName,
    required this.insecureSkipTLSVerify,
    required this.namespace,
    required this.auth,
  });
}

class KubeconfigException implements Exception {
  final String message;
  const KubeconfigException(this.message);

  const KubeconfigException.notAMapping()
      : message = 'kubeconfig is not a YAML mapping';
  const KubeconfigException.noContexts()
      : message = 'kubeconfig lists no contexts';
  KubeconfigException.missingCluster(String name)
      : message = 'context references cluster "$name", which is not defined';
  KubeconfigException.badServer(String server)
      : message = 'cluster server "$server" is not a URL';

  @override
  String toString() => message;
}

/// A kubeconfig, reduced to the parts Field can actually act on.
///
/// Deliberately not a faithful model of the format. Kubeconfigs in the wild
/// carry auth shapes that need a binary on PATH; this app runs none, so those
/// contexts are recorded with the reason they cannot be used rather than
/// half-loaded and failed later.
class Kubeconfig {
  final List<KubeContext> contexts;

  const Kubeconfig._(this.contexts);

  factory Kubeconfig.parse(String yaml) {
    final root = _root(yaml);
    final clusters = _byName(root['clusters'], 'cluster');
    final users = _byName(root['users'], 'user');
    final raw = _mapList(root['contexts']);
    if (raw.isEmpty) throw const KubeconfigException.noContexts();

    final out = <KubeContext>[];
    for (final entry in raw) {
      final name = entry['name'];
      final ctx = _map(entry['context']);
      final clusterName = ctx?['cluster'];
      if (name is! String || ctx == null || clusterName is! String) continue;
      final cluster = clusters[clusterName];
      if (cluster == null) throw KubeconfigException.missingCluster(clusterName);
      final serverString = cluster['server'];
      final server = serverString is String ? Uri.tryParse(serverString) : null;
      if (server == null || !server.hasScheme || server.host.isEmpty) {
        throw KubeconfigException.badServer(
            serverString is String ? serverString : '');
      }
      final userName = ctx['user'];
      final user =
          (userName is String ? users[userName] : null) ?? <String, dynamic>{};
      out.add(KubeContext(
        name: name,
        clusterName: clusterName,
        server: server,
        caPEM: pemOrFile(cluster, 'certificate-authority-data',
            'certificate-authority'),
        tlsServerName: cluster['tls-server-name'] as String?,
        insecureSkipTLSVerify:
            cluster['insecure-skip-tls-verify'] as bool? ?? false,
        namespace: ctx['namespace'] as String?,
        auth: authFrom(user),
      ));
    }
    return Kubeconfig._(out);
  }

  static Future<Kubeconfig> load(String path) async =>
      Kubeconfig.parse(await File(path).readAsString());

  factory Kubeconfig.loadSync(String path) =>
      Kubeconfig.parse(File(path).readAsStringSync());

  KubeContext? context(String name) {
    for (final c in contexts) {
      if (c.name == name) return c;
    }
    return null;
  }

  /// One self-contained kubeconfig per context.
  ///
  /// A file with three contexts in it is three clusters, and after import it
  /// should be three independent things: removing one has no business touching
  /// the others. Splitting on the way in makes that true by construction,
  /// rather than by remembering which contexts were removed and filtering them
  /// out on every load.
  static List<({String name, String yaml})> split(String yaml) {
    final root = _root(yaml);
    final clusters = _byName(root['clusters'], 'cluster');
    final users = _byName(root['users'], 'user');
    final out = <({String name, String yaml})>[];

    for (final entry in _mapList(root['contexts'])) {
      final name = entry['name'];
      final ctx = _map(entry['context']);
      final clusterName = ctx?['cluster'];
      if (name is! String || ctx == null || clusterName is! String) continue;
      final cluster = clusters[clusterName];
      if (cluster == null) continue;
      final userName = ctx['user'];
      final document = <String, dynamic>{
        'apiVersion': 'v1',
        'kind': 'Config',
        'clusters': [
          {'name': clusterName, 'cluster': cluster}
        ],
        'contexts': [
          {'name': name, 'context': ctx}
        ],
        'current-context': name,
      };
      final user = userName is String ? users[userName] : null;
      if (user != null) {
        document['users'] = [
          {'name': userName, 'user': user}
        ];
      }
      out.add((name: name, yaml: emitYaml(document)));
    }
    return out;
  }

  // Auth

  static KubeAuth authFrom(Map<String, dynamic> user) {
    // exec: and auth-provider: both mean "run this program", which this app
    // does not do, on any platform. Name the binary in the reason: the user
    // has to replace it with a certificate or a token, and needs to know
    // which one is in the way.
    final exec = _map(user['exec']);
    if (exec != null) {
      final cmd = exec['command'] as String? ?? 'an external command';
      return UnsupportedAuth(
          'needs `$cmd`, and this app runs no binaries — supply a client certificate or a bearer token instead');
    }
    final provider = _map(user['auth-provider']);
    if (provider != null) {
      final name = provider['name'] as String? ?? 'an auth provider';
      return UnsupportedAuth(
          'uses the `$name` auth provider, which needs a helper binary — supply a client certificate or a bearer token instead');
    }
    final token = user['token'];
    if (token is String && token.isNotEmpty) return BearerTokenAuth(token);
    final cert =
        pemOrFile(user, 'client-certificate-data', 'client-certificate');
    final key = pemOrFile(user, 'client-key-data', 'client-key');
    if (cert != null && key != null) return ClientCertificateAuth(cert, key);
    if (user['username'] != null) {
      return const UnsupportedAuth(
          'uses HTTP basic auth, which Kubernetes removed in 1.19');
    }
    return const UnsupportedAuth('carries no credentials Field can present');
  }

  // Helpers

  static final _notBase64 = RegExp(r'[^A-Za-z0-9+/=]');

  /// `*-data` is base64 inline; the plain key is a path on the machine that
  /// wrote the file. On a tablet that path does not exist, so a file reference
  /// is read when it happens to resolve (a desktop, tests) and otherwise
  /// dropped; the caller reports the context as unusable rather than guessing.
  static Uint8List? pemOrFile(
      Map<String, dynamic> m, String dataKey, String fileKey) {
    final b64 = m[dataKey];
    if (b64 is String) {
      try {
        return base64.decode(base64.normalize(b64.replaceAll(_notBase64, '')));
      } on FormatException {
        // fall through to the file form
      }
    }
    final path = m[fileKey];
    if (path is String) {
      try {
        return File(path).readAsBytesSync();
      } on IOException {
        return null;
      }
    }
    return null;
  }

  static Map<String, dynamic> _root(String yaml) {
    final Object? loaded;
    try {
      loaded = loadYaml(yaml);
    } on YamlException catch (e) {
      throw KubeconfigException('kubeconfig is not valid YAML: ${e.message}');
    }
    final root = _plain(loaded);
    if (root is! Map<String, dynamic>) {
      throw const KubeconfigException.notAMapping();
    }
    return root;
  }

  static Map<String, Map<String, dynamic>> _byName(Object? any, String key) {
    final out = <String, Map<String, dynamic>>{};
    for (final e in _mapList(any)) {
      final name = e['name'];
      if (name is! String) continue;
      out[name] = _map(e[key]) ?? <String, dynamic>{};
    }
    return out;
  }

  static List<Map<String, dynamic>> _mapList(Object? any) {
    if (any is! List) return const [];
    return [
      for (final e in any)
        if (e is Map<String, dynamic>) e
    ];
  }

  static Map<String, dynamic>? _map(Object? any) =>
      any is Map<String, dynamic> ? any : null;

  /// YAML nodes to plain Dart values, with string keys throughout.
  static Object? _plain(Object? node) {
    if (node is Map) {
      return <String, dynamic>{
        for (final e in node.entries) e.key.toString(): _plain(e.value)
      };
    }
    if (node is List) return [for (final e in node) _plain(e)];
    return node;
  }
}
