import 'package:bnk_engines/bnk_engines.dart';
import 'package:bnk_kit/bnk_kit.dart';
import 'package:flutter/material.dart';

import '../engines.dart';
import '../import.dart';
import '../observe.dart';
import '../platform.dart';
import '../theme.dart';
import '../widgets.dart';

/// One cluster: how it is reached, what probing found there, and the way to
/// forget it. Import and probe-all live in the sidebar, next to the list
/// they act on; this screen is about the one cluster that is selected.
class ClusterScreen extends StatefulWidget {
  const ClusterScreen({super.key});

  @override
  State<ClusterScreen> createState() => _ClusterScreenState();
}

class _ClusterScreenState extends State<ClusterScreen> {
  bool _probing = false;

  @override
  Widget build(BuildContext context) {
    final store = Engines.of(context).store;
    return Observe([store, ...store.clusters], builder: (context) {
      final cluster = store.current;
      return Column(children: [
        Toolbar(title: cluster?.displayName ?? 'Cluster', children: [
          if (cluster != null)
            Flexible(
              child: Text(cluster.context.server.toString(),
                  style: Tokens.mono(11.5, color: Tokens.muted), maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          const Spacer(),
          if (cluster != null && cluster.isUsable)
            OutlinedButton.icon(
              onPressed: _probing
                  ? null
                  : () async {
                      setState(() => _probing = true);
                      await cluster.probe();
                      if (mounted) setState(() => _probing = false);
                    },
              icon: const Icon(Icons.wifi, size: 15),
              label: Text(_probing ? 'Probing…' : 'Probe'),
            ),
        ]),
        Expanded(
          child: cluster != null
              ? ListView(padding: const EdgeInsets.all(20), children: [_ClusterCard(cluster: cluster)])
              : store.clusters.isEmpty
                  // The button is here as well as in the sidebar, because
                  // below 900 the sidebar is folded away and a sentence
                  // pointing at it points at nothing on screen.
                  ? Message(
                      title: 'No kubeconfigs yet',
                      detail: 'Import one ${deviceWords.importSource}. Field needs a context with a client certificate or a '
                          'bearer token — anything that shells out to aws, gcloud or kubelogin cannot be used here.',
                      action: FilledButton(
                        onPressed: () => importKubeconfigs(context, store),
                        child: const Text('Import kubeconfig'),
                      ),
                    )
                  : const Message(title: 'No cluster selected', detail: 'Pick one in the sidebar.'),
        ),
      ]);
    });
  }
}

class _ClusterCard extends StatelessWidget {
  final ManagedCluster cluster;
  const _ClusterCard({required this.cluster});

  @override
  Widget build(BuildContext context) {
    final store = Engines.of(context).store;
    final reach = cluster.reach;
    final reachable = reach is Reachable;
    final dot = switch (reach) {
      Reachable() => Tokens.ok,
      Unprobed() => Tokens.muted,
      _ => Tokens.deadDot,
    };
    final status = switch (reach) {
      Reachable(:final nodes, :final ready) => Pill('$ready/$nodes nodes ready', color: ready == nodes ? Tokens.ok : Tokens.warn),
      Unprobed() => const Pill('not probed'),
      Unreachable() => const Pill('no route', color: Color(0xFF8B94A6)),
      Unusable() => const Pill('unusable', color: Tokens.warn),
    };
    final roles = cluster.roles.toList()..sort((a, b) => a.label.compareTo(b.label));
    final streaming = cluster.tmmPods.any((p) => p.hasContainer(Exporter.containerName));
    final note = _note();
    final fields = [
      Field('SERVER', cluster.context.server.toString()),
      Field('AUTH', _authLabel),
      Field('CONTEXT', cluster.context.name),
    ];
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 10, runSpacing: 6, children: [
          StatusDot(color: dot, glow: reachable, size: 8),
          Text(cluster.displayName, style: Tokens.text(15, weight: FontWeight.w600, color: reachable ? Tokens.fg : Tokens.muted)),
          status,
          for (final role in roles) Pill(role.label, color: _roleColor(role)),
          if (streaming)
            Row(mainAxisSize: MainAxisSize.min, children: [
              const StatusDot(color: Tokens.ok, glow: true, size: 6),
              const SizedBox(width: 6),
              Text('streaming', style: Tokens.text(11.5, weight: FontWeight.w600, color: Tokens.ok)),
            ]),
        ]),
        const SizedBox(height: 13),
        LayoutBuilder(builder: (context, constraints) {
          final wide = constraints.maxWidth >= 720;
          return Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Expanded(
              child: wide
                  ? Row(children: [for (final f in fields) ...[Flexible(child: f), const SizedBox(width: 32)]])
                  : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      for (final f in fields) ...[f, const SizedBox(height: 8)]
                    ]),
            ),
            // The action sits with the fact it acts on: this cluster came
            // out of that file, and removing the file is what takes it away.
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text('from ${cluster.sourceFile}', style: Tokens.mono(10.5, color: Tokens.faint), maxLines: 1),
              const SizedBox(height: 4),
              OutlinedButton(
                style: OutlinedButton.styleFrom(foregroundColor: Tokens.bad, side: BorderSide(color: Tokens.bad.withValues(alpha: 0.4))),
                onPressed: () => _confirmRemoval(context, store),
                child: const Text('Remove'),
              ),
            ]),
          ]);
        }),
        if (note != null) ...[
          const SizedBox(height: 13),
          Inset(
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(reachable ? Icons.check_circle_outline : Icons.warning_amber_rounded,
                  size: 15, color: reachable ? Tokens.ok : Tokens.warn),
              const SizedBox(width: 8),
              Expanded(child: Text(note, style: Tokens.text(12, color: Tokens.muted))),
            ]),
          ),
        ],
      ]),
    );
  }

  Future<void> _confirmRemoval(BuildContext context, ClusterStore store) async {
    final siblings = store.siblings(cluster);
    final base = 'Nothing on the cluster is touched. Import ${cluster.sourceFile} again to bring it back.';
    final warning = siblings.isEmpty
        ? 'Removes this cluster and deletes ${cluster.sourceFile} — it holds nothing else.\n\n$base'
        : 'Removes this cluster only. ${siblings.join(', ')} came from the same file and stay.\n\n$base';
    final remove = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${cluster.displayName}?'),
        content: Text(warning),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Tokens.bad),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (remove == true) await store.remove(cluster);
  }

  String get _authLabel => switch (cluster.context.auth) {
        ClientCertificateAuth() => 'client certificate',
        BearerTokenAuth() => 'bearer token',
        UnsupportedAuth() => 'unsupported',
      };

  String? _note() {
    switch (cluster.reach) {
      case Unusable(:final why):
        return why;
      case Unreachable(:final why):
        return why;
      case Reachable(:final version):
        final tmm = cluster.tmmPods.length;
        final withExporter = cluster.tmmPods.where((p) => p.hasContainer(Exporter.containerName)).length;
        final base = tmm > 0
            ? 'Kubernetes $version. $tmm f5-tmm pod${tmm == 1 ? '' : 's'} found by label, of which $withExporter carry the exporter.'
            : 'Kubernetes $version. No f5-tmm pods here, so there is nothing for TMM Live to scrape.';
        return [base, ..._k0rdentNotes()].join(' ');
      case Unprobed():
        return null;
    }
  }

  /// What the k0rdent, GPU and KubeVirt probes found, as sentences.
  ///
  /// Written out rather than left to the badges because the badges say a
  /// cluster is managed and cannot say by what: the ClusterDeployment's
  /// namespace and name are the thread back to the management cluster.
  List<String> _k0rdentNotes() {
    final notes = <String>[];
    final k = cluster.k0rdent;
    switch (k.role) {
      case K0rdentRole.management:
        final edition = k.edition == K0rdentEdition.enterprise ? 'Enterprise' : 'Community';
        final version = k.version == null ? '' : ' ${k.version}';
        final providers = [
          for (final p in k.providers)
            if (p.startsWith('infrastructure-')) p.substring('infrastructure-'.length)
        ];
        notes.add('k0rdent $edition$version management cluster${providers.isEmpty ? '.' : ', providing ${providers.join(', ')}.'}');
      case K0rdentRole.managed:
        final by = k.managedBy;
        notes.add(by == null
            ? 'Managed by k0rdent.'
            : 'Managed by k0rdent as ${by.namespace}/${by.name}${by.clusterType == 'Capi' ? ', provisioned by it.' : ', adopted.'}');
      case null:
        break;
    }
    if (cluster.gpuDevices.isNotEmpty) notes.add('GPUs: ${cluster.gpuDevices.join(', ')}.');
    if (cluster.roles.contains(ClusterRole.kubevirt)) notes.add('KubeVirt is installed — see the KubeVirt tab.');
    return notes;
  }

  static Color _roleColor(ClusterRole role) => switch (role) {
        ClusterRole.bnk => Tokens.series[0],
        ClusterRole.dpu => Tokens.series[1],
        ClusterRole.nico => Tokens.series[2],
        // The same hue as k0rdent, because it is the same fact seen from
        // the other end: this cluster belongs to one of those.
        ClusterRole.k0rdent || ClusterRole.managed => Tokens.series[3],
        ClusterRole.kubevirt => Tokens.series[4],
        ClusterRole.gpu => Tokens.ember,
      };
}
