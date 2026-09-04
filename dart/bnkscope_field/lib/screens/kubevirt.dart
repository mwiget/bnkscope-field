import 'package:bnk_engines/bnk_engines.dart';
import 'package:bnk_kit/bnk_kit.dart';
import 'package:flutter/material.dart';

import '../engines.dart';
import '../observe.dart';
import '../theme.dart';
import '../widgets.dart';

/// Virtual machines on a cluster running KubeVirt.
class KubeVirtScreen extends StatefulWidget {
  const KubeVirtScreen({super.key});

  @override
  State<KubeVirtScreen> createState() => _KubeVirtScreenState();
}

class _KubeVirtScreenState extends State<KubeVirtScreen> {
  String? _loadedFor;

  @override
  Widget build(BuildContext context) {
    final engines = Engines.of(context);
    final store = engines.store;
    final kubevirt = engines.kubevirt;
    final cluster = store.current;
    return Observe([store, kubevirt, if (cluster != null) cluster], builder: (context) {
      final key = '${store.selected ?? ''}#${cluster?.probeGeneration ?? 0}';
      if (_loadedFor != key) {
        _loadedFor = key;
        WidgetsBinding.instance.addPostFrameCallback((_) => _reload(store, kubevirt));
      }
      return Column(children: [
        Toolbar(title: 'KubeVirt', children: [
          if (kubevirt.machines.isNotEmpty)
            Flexible(
              child: Text(
                  '${kubevirt.running}/${kubevirt.machines.length} running${kubevirt.withGPUs > 0 ? ' · ${kubevirt.withGPUs} with a GPU' : ''}',
                  style: Tokens.mono(11.5, color: Tokens.muted),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ),
          const Spacer(),
          if (kubevirt.loading) ...[const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)), const SizedBox(width: 12)],
          OutlinedButton(onPressed: kubevirt.loading ? null : () => _reload(store, kubevirt), child: const Text('Refresh')),
        ]),
        Expanded(child: _content(store, kubevirt)),
      ]);
    });
  }

  Widget _content(ClusterStore store, KubeVirtEngine kubevirt) {
    final cluster = store.current;
    if (cluster?.roles.contains(ClusterRole.kubevirt) != true) {
      return const Message(title: 'KubeVirt is not installed here', detail: 'This screen appears on a cluster whose apiserver serves kubevirt.io.');
    }
    // A failed probe clears the API groups but leaves the roles behind, so
    // this tab stays on screen and the load empties the list. The reach is
    // the one fact that separates "no machines" from "no answer".
    final unreachable = switch (cluster!.reach) {
      Unreachable(:final why) => why,
      Unusable(:final why) => why,
      _ => null,
    };
    if (unreachable != null) return Message(title: 'Cannot reach ${cluster.displayName}', detail: unreachable, tone: Tokens.bad);
    final failure = kubevirt.failure;
    if (failure != null) return Message(title: 'Could not read the KubeVirt API', detail: failure, tone: Tokens.bad);
    if (kubevirt.machines.isEmpty && !kubevirt.loading) {
      return const Message(
          title: 'No virtual machines',
          detail: 'KubeVirt is installed and serving, but no VirtualMachine or VirtualMachineInstance exists on this cluster.');
    }
    return ListView(padding: const EdgeInsets.all(20), children: [
      // Said once at the top rather than on every row it applies to. A
      // standalone VMI is not a fault and the screen should not shout, but it
      // is the reason those rows have no buttons.
      if (kubevirt.standalone > 0) ...[
        Notice(
            '${kubevirt.standalone} of these are VirtualMachineInstances with no VirtualMachine. They run, but they have no run '
            'state to start or stop and they do not come back after the node reboots — re-apply the manifest to recreate them.',
            tone: Tokens.muted),
        const SizedBox(height: 16),
      ],
      if (kubevirt.ephemeral > 0) ...[
        Notice(
            '${kubevirt.ephemeral} of these boot from a containerDisk. That is an image, not a disk: whatever the machine writes '
            'to its root filesystem is discarded when it stops, and Start brings back the image.',
            tone: Tokens.muted),
        const SizedBox(height: 16),
      ],
      for (final group in kubevirt.byNamespace) ...[
        TitledPanel(
          title: group.namespace,
          trailing: Pill('${group.machines.length}'),
          spacing: 12,
          children: [for (final machine in group.machines) _MachineRow(machine: machine)],
        ),
        const SizedBox(height: 16),
      ],
    ]);
  }

  Future<void> _reload(ClusterStore store, KubeVirtEngine kubevirt) async {
    final cluster = store.current;
    if (cluster == null || !cluster.roles.contains(ClusterRole.kubevirt)) return;
    await kubevirt.load(cluster);
  }
}

/// One machine: what it is, where it is, and what can be done to it.
class _MachineRow extends StatelessWidget {
  final Machine machine;
  const _MachineRow({required this.machine});

  @override
  Widget build(BuildContext context) {
    final engines = Engines.of(context);
    final kubevirt = engines.kubevirt;
    final tone = switch (machine.state) {
      'Running' => Tokens.ok,
      'Failed' || 'Unknown' => Tokens.bad,
      'Stopped' || 'Succeeded' => Tokens.muted,
      _ => Tokens.warn,
    };
    final failure = kubevirt.actionFailure;
    final platform = _platform();
    return Inset(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          StatusDot(color: tone, glow: machine.isRunning),
          const SizedBox(width: 9),
          Flexible(child: Text(machine.name, style: Tokens.mono(12), maxLines: 1, overflow: TextOverflow.ellipsis)),
          const SizedBox(width: 9),
          Pill(machine.state, color: tone),
          if (machine.gpus.isNotEmpty) ...[
            const SizedBox(width: 6),
            Pill(machine.gpus.length == 1 ? 'GPU' : '${machine.gpus.length}× GPU', color: Tokens.ember),
          ],
          // Said only when it is running and the cluster has said no. A
          // passed-through card pins a machine to its node, and that is the
          // fact that matters the day the node has to be drained.
          if (machine.isRunning && machine.isLiveMigratable == false) ...[
            const SizedBox(width: 6),
            const Pill('not migratable', color: Tokens.warn),
          ],
          const Spacer(),
          _actions(context, kubevirt),
        ]),
        const SizedBox(height: 8),
        // The first line is where and how big; the second is what it is
        // built as.
        Text(_facts(), style: Tokens.mono(11, color: Tokens.muted), maxLines: 2, overflow: TextOverflow.ellipsis),
        if (platform.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(platform, style: Tokens.mono(11, color: Tokens.faint), maxLines: 2, overflow: TextOverflow.ellipsis),
        ],
        // One line per interface: the binding is the part that says how the
        // packet leaves.
        for (final iface in machine.interfaces) ...[
          const SizedBox(height: 6),
          Row(children: [
            Text(iface.name, style: Tokens.mono(11)),
            const SizedBox(width: 8),
            Pill(iface.describedBinding, color: iface.binding == InterfaceBinding.sriov ? Tokens.ember : Tokens.muted),
            const SizedBox(width: 8),
            Text(iface.network, style: Tokens.mono(11, color: Tokens.muted)),
            if (iface.addresses.isNotEmpty) ...[const SizedBox(width: 8), Text(iface.addresses.join(', '), style: Tokens.mono(11))],
            if (iface.mac case final mac?) ...[const SizedBox(width: 8), Text(mac, style: Tokens.mono(11, color: Tokens.faint))],
            if (iface.linkState case final link?) ...[const SizedBox(width: 8), StatusDot(color: link == 'up' ? Tokens.ok : Tokens.bad, size: 6)],
            if (iface.details.isNotEmpty) ...[
              const SizedBox(width: 8),
              Flexible(
                child: Text(iface.details.join(' · '),
                    style: Tokens.mono(11, color: iface.binding == InterfaceBinding.sriov ? Tokens.muted : Tokens.faint),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ),
            ],
          ]),
        ],
        // One line per disk, and the word "ephemeral" on the ones that keep
        // nothing.
        for (final disk in machine.disks) ...[
          const SizedBox(height: 6),
          Row(children: [
            SizedBox(width: 32, child: Text(disk.target ?? disk.kind, style: Tokens.mono(11))),
            const SizedBox(width: 8),
            Text(disk.name, style: Tokens.mono(11, color: Tokens.muted)),
            if (disk.bus case final bus?) ...[const SizedBox(width: 8), Text(bus, style: Tokens.mono(11, color: Tokens.faint))],
            const SizedBox(width: 8),
            Flexible(child: Text(disk.backing, style: Tokens.mono(11, color: Tokens.muted), maxLines: 1, overflow: TextOverflow.ellipsis)),
            if (disk.bytes case final bytes?) ...[const SizedBox(width: 8), Text(bytesBinary(bytes), style: Tokens.mono(11, color: Tokens.faint))],
            if (disk.isEphemeral) ...[const SizedBox(width: 8), Text('ephemeral', style: Tokens.text(10.5, weight: FontWeight.w600, color: Tokens.warn))],
          ]),
        ],
        if (failure != null && failure.id == machine.id) ...[
          const SizedBox(height: 8),
          Text(failure.why, style: Tokens.text(11.5, color: Tokens.bad)),
        ],
      ]),
    );
  }

  Widget _actions(BuildContext context, KubeVirtEngine kubevirt) {
    if (kubevirt.busy == machine.id) {
      return const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (!machine.isManageable) {
      // Not a disabled button. A greyed-out Start invites a press and then
      // explains nothing; the word says why there is no button.
      return Text('standalone VMI', style: Tokens.text(11, color: Tokens.faint));
    }
    final disabled = kubevirt.busy != null;
    // Declared state, not the instance phase. A machine whose VMI is stuck
    // at Scheduling because no node has a free card is declared running and
    // is not running: keying on the phase offers it Start, which the API
    // answers 409, and withholds Stop, which is the verb that unsticks it.
    if (machine.isDeclaredRunning) {
      return Row(mainAxisSize: MainAxisSize.min, children: [
        OutlinedButton(onPressed: disabled ? null : () => _confirm(context, kubevirt, VmAction.restart), child: const Text('Restart')),
        const SizedBox(width: 6),
        OutlinedButton(onPressed: disabled ? null : () => _confirm(context, kubevirt, VmAction.stop), child: const Text('Stop')),
      ]);
    }
    return OutlinedButton(onPressed: disabled ? null : () => _run(context, kubevirt, VmAction.start), child: const Text('Start'));
  }

  /// Stop and Restart interrupt a running machine, so the verb does not
  /// fire straight off a tap. Start is additive and asks nothing.
  Future<void> _confirm(BuildContext context, KubeVirtEngine kubevirt, VmAction action) async {
    final verb = action.name[0].toUpperCase() + action.name.substring(1);
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('$verb ${machine.name}?'),
        content: Text(action == VmAction.stop
            ? 'The machine is powered off. Anything running on it stops now, and its disks are kept — Start brings it back.'
            : 'The machine is powered off and started again. Anything running on it stops now.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          TextButton(style: TextButton.styleFrom(foregroundColor: Tokens.bad), onPressed: () => Navigator.of(context).pop(true), child: Text(verb)),
        ],
      ),
    );
    if (go == true && context.mounted) await _run(context, kubevirt, action);
  }

  Future<void> _run(BuildContext context, KubeVirtEngine kubevirt, VmAction action) async {
    final cluster = Engines.of(context).store.current;
    if (cluster == null) return;
    await kubevirt.perform(action, machine, cluster);
  }

  /// `q35 · host-model · 4Gi of 16Gi · up 6 hours`, or as much as is known.
  String _platform() {
    final parts = <String>[];
    if (machine.machineType case final type?) parts.add(type);
    if (machine.cpuModel case final model?) parts.add(model);
    if (machine.memory case final memory?) parts.add(memory);
    final since = machine.runningSince;
    if (since != null && machine.isRunning) parts.add('up ${relative(since).replaceAll(' ago', '')}');
    return parts.join('  ·  ');
  }

  String _facts() {
    final parts = [machine.size];
    final node = machine.node;
    if (node != null && node != '—') parts.add('on $node');
    final networks = [for (final n in machine.networks) n.described];
    if (networks.isNotEmpty) parts.add(networks.join(', '));
    // The device name, not the alias in the manifest: `a4000` is what the
    // author called it, `GA104GL_RTX_A4000` is what they actually got.
    final gpus = [for (final g in machine.gpus) if (g.deviceName case final d?) d.split('/').last];
    if (gpus.isNotEmpty) parts.add(gpus.join(', '));
    return parts.join('  ·  ');
  }
}
