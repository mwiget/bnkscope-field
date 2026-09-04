import 'package:bnk_kit/bnk_kit.dart';

import 'cluster_store.dart';
import 'observable.dart';

class NicoTenant {
  final String name;
  final String namespace;
  final String? version;
  final bool ready;
  final String? endpoint;
  Certificate? ca;

  /// Whether a cluster Field already holds points at this endpoint. The
  /// clusters in the sidebar are related and nothing else says so.
  final String? knownCluster;

  NicoTenant({required this.name, required this.namespace, required this.version, required this.ready,
      required this.endpoint, this.ca, this.knownCluster});

  String get id => name;
}

class NicoSnapshot {
  List<Pod> apiPods = const [];
  List<Pod> providerPods = const [];
  Certificate? adminCert;
  String? adminCertSecret;
  String? endpoint;
  List<NicoTenant> tenants = [];
  Map<String, double> metrics = const {};
  List<String> problems = [];
}

/// What Field can learn about NICo without speaking to Forge.
///
/// The tenant and load-balancer inventory lives behind Forge's gRPC API,
/// which needs server reflection and a dynamic protobuf stack; that is the
/// Edge collector's job, and it is not here. Everything on this screen is
/// either a plain Kubernetes read or a scrape of nico-api's own metrics
/// port, which turns out to be most of what the desktop build shows.
class NicoEngine extends Observable {
  /// The admin identity the desktop build surfaces; its expiry is the single
  /// most useful fact here, and lab CAs do lapse.
  static const adminCertSecret = 'tmm-lb-admin-cert';
  static const namespace = 'nico-system';

  NicoSnapshot _snapshot = NicoSnapshot();
  bool _loading = false;

  NicoSnapshot get snapshot => _snapshot;
  bool get loading => _loading;

  Future<void> load(ManagedCluster cluster, {required List<ManagedCluster> known}) async {
    final client = cluster.clientOrNull;
    if (client == null) return;
    _loading = true;
    notify();
    final snap = NicoSnapshot();

    List<Pod> pods = const [];
    try {
      pods = await client.pods(namespace: namespace);
    } catch (_) {}
    snap.apiPods = pods.where((p) => p.metadata.labels?['app.kubernetes.io/name'] == 'nico-api').toList();
    snap.providerPods = pods.where((p) => (p.metadata.labels?['app'] ?? '').startsWith('nico-lb-provider')).toList();

    try {
      final secret = await client.secret(namespace: namespace, name: adminCertSecret);
      snap.adminCertSecret = adminCertSecret;
      final pem = secret.pem('tls.crt');
      if (pem != null) {
        try {
          snap.adminCert = Certificate.firstInPem(pem);
        } catch (_) {}
      }
    } catch (_) {
      snap.problems.add('Could not read $adminCertSecret — this kubeconfig may not be allowed to read secrets in $namespace.');
    }

    List<TenantControlPlane> tcps = const [];
    try {
      tcps = await client.tenantControlPlanes();
    } catch (_) {}
    for (final tcp in tcps) {
      final endpoint = tcp.status?.controlPlaneEndpoint;
      final tenant = NicoTenant(
        name: tcp.metadata.name,
        namespace: tcp.metadata.namespace ?? '—',
        version: tcp.status?.kubernetesResources?.version?.version,
        ready: tcp.isReady,
        endpoint: endpoint,
        knownCluster: endpoint == null ? null : match(endpoint, known),
      );
      final caSecret = tcp.status?.certificates?['ca']?.secretName;
      final ns = tcp.metadata.namespace;
      if (caSecret != null && ns != null) {
        try {
          final pem = (await client.secret(namespace: ns, name: caSecret)).pem('ca.crt');
          if (pem != null) tenant.ca = Certificate.firstInPem(pem);
        } catch (_) {}
      }
      snap.tenants.add(tenant);
    }

    // nico-api publishes its own Prometheus metrics on a second port.
    // Reached the same way TMM's exporter is: a tunnel to the pod.
    final pod = snap.apiPods.where((p) => p.status?.phase == 'Running').firstOrNull;
    if (pod != null) {
      final scraper = PodScraper(client: client, namespace: namespace, pod: pod.metadata.name, port: 1080);
      try {
        snap.metrics = headline(await scraper.scrape());
        snap.endpoint = '${pod.metadata.name}:1080';
      } catch (_) {
        snap.problems.add('nico-api is running but its metrics port did not answer.');
      }
      await scraper.stop();
    }

    _snapshot = snap;
    _loading = false;
    notify();
  }

  /// A tenant control plane's endpoint against the servers Field already
  /// holds, by host and port rather than by name: the names differ.
  static String? match(String endpoint, List<ManagedCluster> clusters) {
    for (final c in clusters) {
      final server = c.context.server;
      if (server.host.isEmpty || !server.hasPort) continue;
      if (endpoint == '${server.host}:${server.port}') return c.displayName;
    }
    return null;
  }

  /// Totals worth a tile. Only those actually present are returned, because
  /// a metric name that has been renamed upstream should show as absent
  /// rather than as zero.
  static Map<String, double> headline(List<Sample> samples) {
    const wanted = [
      'nico_api_db_queries_total',
      'nico_api_grpc_server_duration_milliseconds_count',
      'nico_active_host_firmware_update_count',
    ];
    final out = <String, double>{};
    for (final name in wanted) {
      var total = 0.0;
      var present = false;
      for (final s in samples) {
        if (s.name == name) {
          present = true;
          total += s.value;
        }
      }
      if (present) out[name] = total;
    }
    return out;
  }
}
