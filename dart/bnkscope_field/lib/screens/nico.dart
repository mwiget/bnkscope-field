import 'package:bnk_engines/bnk_engines.dart';
import 'package:bnk_kit/bnk_kit.dart';
import 'package:flutter/material.dart';

import '../chart.dart';
import '../engines.dart';
import '../observe.dart';
import '../theme.dart';
import '../widgets.dart';

/// What Field can learn about NICo without speaking to Forge.
class NicoScreen extends StatefulWidget {
  const NicoScreen({super.key});

  @override
  State<NicoScreen> createState() => _NicoScreenState();
}

class _NicoScreenState extends State<NicoScreen> {
  String? _loadedFor;

  @override
  Widget build(BuildContext context) {
    final engines = Engines.of(context);
    final store = engines.store;
    final nico = engines.nico;
    final cluster = store.current;
    return Observe([store, nico, if (cluster != null) cluster], builder: (context) {
      // Keyed on the probe as well as the selection: the first render lands
      // before probing has said what this cluster is.
      final key = '${store.selected ?? ''}#${cluster?.probeGeneration ?? 0}';
      if (_loadedFor != key) {
        _loadedFor = key;
        WidgetsBinding.instance.addPostFrameCallback((_) => _reload(store, nico));
      }
      return Column(children: [
        Toolbar(title: 'NICo', children: [
          if (cluster != null) Flexible(child: Text(cluster.displayName, style: Tokens.mono(11.5, color: Tokens.muted), maxLines: 1, overflow: TextOverflow.ellipsis)),
          const Spacer(),
          if (nico.loading) ...[const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)), const SizedBox(width: 12)],
          OutlinedButton(onPressed: nico.loading ? null : () => _reload(store, nico), child: const Text('Refresh')),
        ]),
        Expanded(child: _content(store, nico)),
      ]);
    });
  }

  Widget _content(ClusterStore store, NicoEngine nico) {
    if (store.current?.roles.contains(ClusterRole.nico) != true) {
      return const Message(
          title: 'No NVIDIA Infra Controller here',
          detail: "This screen appears on a cluster running NICo. Field detects it from the nico-api pod's labels.");
    }
    final snap = nico.snapshot;
    return ListView(padding: const EdgeInsets.all(20), children: [
      for (final problem in snap.problems) ...[Notice(problem), const SizedBox(height: 16)],
      LayoutBuilder(builder: (context, constraints) {
        final wide = constraints.maxWidth >= 760;
        final left = _controlPlane(snap);
        final right = _adminCertificate(snap);
        return wide
            ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: left), const SizedBox(width: 16), Expanded(child: right)])
            : Column(children: [left, const SizedBox(height: 16), right]);
      }),
      const SizedBox(height: 16),
      _tenants(snap),
      const SizedBox(height: 16),
      _metrics(snap),
      const SizedBox(height: 16),
      const Note("Tenants, VPCs and load-balancer services live behind Forge's gRPC API, which needs server reflection and a "
          'dynamic protobuf stack. That belongs in the in-cluster collector, not on this device — everything on this screen '
          "is a plain Kubernetes read or a scrape of nico-api's metrics port."),
    ]);
  }

  Widget _controlPlane(NicoSnapshot snap) {
    final pods = [...snap.apiPods, ...snap.providerPods];
    return TitledPanel(title: 'Control plane', children: [
      if (pods.isEmpty) Text('No nico pods found in nico-system.', style: Tokens.text(12.5, color: Tokens.muted)),
      for (final pod in pods)
        () {
          final running = pod.status?.phase == 'Running';
          final restarts = pod.status?.containerStatuses?.firstOrNull?.restartCount ?? 0;
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(color: Tokens.bg, borderRadius: BorderRadius.circular(8), border: Border.all(color: Tokens.border)),
            child: Row(children: [
              StatusDot(color: running ? Tokens.ok : Tokens.warn, glow: running),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(pod.metadata.name, style: Tokens.mono(12), maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text(pod.spec?.containers.firstOrNull?.image ?? '—', style: Tokens.mono(10.5, color: Tokens.faint), maxLines: 1, overflow: TextOverflow.ellipsis),
                ]),
              ),
              if (restarts > 0) ...[const SizedBox(width: 8), Pill('$restarts restarts', color: Tokens.warn)],
            ]),
          );
        }(),
    ]);
  }

  Widget _adminCertificate(NicoSnapshot snap) {
    final cert = snap.adminCert;
    return TitledPanel(title: 'Admin certificate', children: [
      if (cert == null)
        Text('Not read. Forge is reached with this client certificate, so its expiry is worth knowing before it stops working.',
            style: Tokens.text(12.5, color: Tokens.muted))
      else ...[
        Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
          Text('${cert.daysRemaining}', style: Tokens.mono(30, weight: FontWeight.w600, color: _expiryColour(cert))),
          const SizedBox(width: 6),
          Text('days left', style: Tokens.mono(12, color: Tokens.muted)),
        ]),
        Field('SUBJECT', cert.subject ?? '—'),
        Field('ISSUER', cert.issuer ?? '—'),
        Field('EXPIRES', shortDate(cert.notAfter)),
        Field('SECRET', snap.adminCertSecret ?? '—'),
      ],
    ]);
  }

  static Color _expiryColour(Certificate cert) {
    if (cert.isExpired) return Tokens.bad;
    if (cert.daysRemaining < 30) return Tokens.warn;
    return Tokens.ok;
  }

  Widget _tenants(NicoSnapshot snap) => TitledPanel(title: 'Tenant control planes', children: [
        if (snap.tenants.isEmpty)
          Text("None. Kamaji hosts the tenant clusters' control planes; on this cluster there are none registered.",
              style: Tokens.text(12.5, color: Tokens.muted)),
        for (final tenant in snap.tenants)
          Inset(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Wrap(spacing: 10, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                StatusDot(color: tenant.ready ? Tokens.ok : Tokens.warn, glow: tenant.ready),
                Text(tenant.name, style: Tokens.text(14, weight: FontWeight.w600)),
                Pill(tenant.version ?? '?'),
                Pill(tenant.ready ? 'Ready' : 'not ready', color: tenant.ready ? Tokens.ok : Tokens.warn),
                if (tenant.knownCluster case final known?)
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.link, size: 13, color: Tokens.primary),
                    const SizedBox(width: 6),
                    Text('this is $known', style: Tokens.text(11.5, weight: FontWeight.w600, color: Tokens.primary)),
                  ]),
              ]),
              const SizedBox(height: 8),
              Wrap(spacing: 28, runSpacing: 8, children: [
                Field('ENDPOINT', tenant.endpoint ?? '—'),
                Field('NAMESPACE', tenant.namespace),
                if (tenant.ca case final ca?) Field('CLUSTER CA', '${ca.daysRemaining} days left'),
              ]),
            ]),
          ),
      ]);

  Widget _metrics(NicoSnapshot snap) {
    final names = snap.metrics.keys.toList()..sort();
    return TitledPanel(title: 'nico-api', children: [
      if (names.isEmpty)
        Text("No metrics read. nico-api publishes them on its own port, reached the same way TMM's exporter is — a tunnel to the pod, nothing installed.",
            style: Tokens.text(12.5, color: Tokens.muted))
      else
        Row(children: [
          for (final name in names) ...[
            Expanded(child: Tile(label: _label(name), value: compact(snap.metrics[name]!), sub: name)),
            if (name != names.last) const SizedBox(width: 14),
          ],
        ]),
    ]);
  }

  static String _label(String metric) => switch (metric) {
        'nico_api_db_queries_total' => 'DB QUERIES',
        'nico_api_grpc_server_duration_milliseconds_count' => 'GRPC CALLS',
        'nico_active_host_firmware_update_count' => 'FIRMWARE UPDATES',
        _ => metric.toUpperCase(),
      };

  Future<void> _reload(ClusterStore store, NicoEngine nico) async {
    final cluster = store.current;
    if (cluster == null || !cluster.isUsable) return;
    // Probe on demand rather than assuming someone else already has.
    if (cluster.reach is Unprobed) await cluster.probe();
    if (!cluster.roles.contains(ClusterRole.nico)) return;
    await nico.load(cluster, known: store.clusters);
  }
}
