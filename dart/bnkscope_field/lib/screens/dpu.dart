import 'package:bnk_engines/bnk_engines.dart';
import 'package:bnk_kit/bnk_kit.dart';
import 'package:flutter/material.dart';

import '../engines.dart';
import '../observe.dart';
import '../theme.dart';
import '../widgets.dart';

/// The DPU service wiring, read straight off the cluster.
class DpuScreen extends StatefulWidget {
  const DpuScreen({super.key});

  @override
  State<DpuScreen> createState() => _DpuScreenState();
}

class _DpuScreenState extends State<DpuScreen> {
  String? _loadedFor;

  @override
  Widget build(BuildContext context) {
    final engines = Engines.of(context);
    final store = engines.store;
    final dpu = engines.dpu;
    final cluster = store.current;
    return Observe([store, dpu, if (cluster != null) cluster], builder: (context) {
      final key = '${store.selected ?? ''}#${cluster?.probeGeneration ?? 0}';
      if (_loadedFor != key) {
        _loadedFor = key;
        WidgetsBinding.instance.addPostFrameCallback((_) => _reload(store, dpu));
      }
      return Column(children: [
        Toolbar(title: 'DPU Services', children: [
          Text('svc.dpu.nvidia.com', style: Tokens.mono(11.5, color: Tokens.muted)),
          const Spacer(),
          if (dpu.loading) ...[const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)), const SizedBox(width: 12)],
          OutlinedButton(onPressed: dpu.loading ? null : () => _reload(store, dpu), child: const Text('Refresh')),
        ]),
        Expanded(child: _content(store, dpu)),
      ]);
    });
  }

  Widget _content(ClusterStore store, DpuEngine dpu) {
    if (store.current?.roles.contains(ClusterRole.dpu) != true) {
      return const Message(title: 'No DPU services here', detail: 'This screen appears on a cluster whose workloads carry svc.dpu.nvidia.com labels.');
    }
    final failure = dpu.failure;
    if (failure != null) return Message(title: 'Could not read the DPU service API', detail: failure, tone: Tokens.bad);
    return ListView(padding: const EdgeInsets.all(20), children: [
      _chains(dpu),
      const SizedBox(height: 16),
      _interfaces(dpu),
      const SizedBox(height: 16),
      const Note('This is the DPU service API, not the DPF operator — a different API group, and not installed on this '
          'cluster. Chains are read-only here: changing how traffic is steered is not something to do from a tablet by accident.'),
    ]);
  }

  Widget _chains(DpuEngine dpu) => TitledPanel(
        title: 'Service chains',
        trailing: Pill('${dpu.readyChains}/${dpu.chains.length} ready', color: dpu.readyChains == dpu.chains.length ? Tokens.ok : Tokens.warn),
        children: [
          if (dpu.chains.isEmpty) Text('None. Nothing is steering traffic through this DPU.', style: Tokens.text(12.5, color: Tokens.muted)),
          for (final group in dpu.chainsByNode)
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(group.node, style: Tokens.mono(11.5, color: Tokens.muted)),
              for (final chain in group.chains) ...[
                const SizedBox(height: 9),
                Inset(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      StatusDot(color: chain.isReady ? Tokens.ok : Tokens.warn, glow: chain.isReady),
                      const SizedBox(width: 9),
                      Expanded(child: Text(chain.metadata.name, style: Tokens.mono(12))),
                    ]),
                    for (final hop in chain.spec.switches ?? const <ServiceSwitch>[]) ...[
                      const SizedBox(height: 7),
                      _HopRow(hop: hop),
                    ],
                  ]),
                ),
              ],
            ]),
        ],
      );

  Widget _interfaces(DpuEngine dpu) => TitledPanel(
        title: 'Service interfaces',
        trailing: Pill('${dpu.readyInterfaces}/${dpu.interfaces.length} ready',
            color: dpu.readyInterfaces == dpu.interfaces.length ? Tokens.ok : Tokens.warn),
        children: [
          for (final group in dpu.interfacesByType)
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text(group.type, style: Tokens.text(12, weight: FontWeight.w600)),
                const SizedBox(width: 8),
                Expanded(child: Text(_explain(group.type), style: Tokens.text(11.5, color: Tokens.faint), maxLines: 1, overflow: TextOverflow.ellipsis)),
                Text('${group.interfaces.length}', style: Tokens.mono(11.5, color: Tokens.muted)),
              ]),
              for (final i in group.interfaces) ...[
                const SizedBox(height: 7),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  decoration: BoxDecoration(color: Tokens.bg, borderRadius: BorderRadius.circular(8), border: Border.all(color: Tokens.border)),
                  child: Row(children: [
                    StatusDot(color: i.isReady ? Tokens.ok : Tokens.warn, size: 6),
                    const SizedBox(width: 10),
                    SizedBox(width: 120, child: Text(i.interfaceName, style: Tokens.mono(11.5), maxLines: 1, overflow: TextOverflow.ellipsis)),
                    const SizedBox(width: 10),
                    Expanded(child: Text(i.detail ?? '—', style: Tokens.mono(11, color: Tokens.muted), maxLines: 1, overflow: TextOverflow.ellipsis)),
                    const SizedBox(width: 8),
                    Text(shortPodName(i.spec.node ?? '—'), style: Tokens.mono(11, color: Tokens.faint)),
                  ]),
                ),
              ],
            ]),
        ],
      );

  static String _explain(String type) => switch (type) {
        'physical' => 'the wire — uplinks out of the DPU',
        'pf' => "host-facing functions, the ports TMM's dataplane counters name",
        'service' => 'ends belonging to a service running on the DPU',
        _ => '',
      };

  Future<void> _reload(ClusterStore store, DpuEngine dpu) async {
    final cluster = store.current;
    if (cluster == null || !cluster.roles.contains(ClusterRole.dpu)) return;
    await dpu.load(cluster);
  }
}

/// One hop of a chain: the ports it joins, drawn as joined rather than listed.
class _HopRow extends StatelessWidget {
  final ServiceSwitch hop;
  const _HopRow({required this.hop});

  @override
  Widget build(BuildContext context) {
    final ends = [for (final p in hop.ports ?? const <ServicePort>[]) p.serviceInterface?.described ?? '—'];
    final mtu = hop.serviceMTU;
    return Row(children: [
      Expanded(
        child: Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          for (var i = 0; i < ends.length; i++) ...[
            if (i > 0) const Icon(Icons.swap_horiz, size: 12, color: Tokens.faint),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(color: Tokens.secondary, borderRadius: BorderRadius.circular(6), border: Border.all(color: Tokens.border)),
              child: Text(ends[i], style: Tokens.mono(11), maxLines: 1),
            ),
          ],
        ]),
      ),
      if (mtu != null) ...[const SizedBox(width: 8), Text('mtu $mtu', style: Tokens.mono(10, color: Tokens.faint))],
    ]);
  }
}
