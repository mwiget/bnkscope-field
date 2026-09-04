import 'package:bnk_kit/bnk_kit.dart';

import 'brief.dart';
import 'cluster_store.dart';
import 'observable.dart';

/// The virtual machines on a cluster, and the three things that can be done
/// to them.
class KubeVirtEngine extends Observable {
  List<Machine> _machines = const [];
  bool _loading = false;
  String? _failure;

  /// The machine an action is in flight on, so its row can say so and its
  /// buttons can refuse a second press.
  String? _busy;

  /// The last action's complaint, kept next to the machine it was about.
  ({String id, String why})? _actionFailure;

  /// The cluster the contents above belong to. Every write lands after an
  /// await, and the selection can change while one is in flight.
  String? _shown;

  List<Machine> get machines => _machines;
  bool get loading => _loading;
  String? get failure => _failure;
  String? get busy => _busy;
  ({String id, String why})? get actionFailure => _actionFailure;

  Future<void> load(ManagedCluster cluster) async {
    if (_shown != cluster.id) {
      // Emptied before the first await, not after the read. Until the new
      // cluster's machines arrive the old ones were still on screen under
      // the new cluster's name.
      _machines = const [];
      _busy = null;
    }
    _shown = cluster.id;
    // Keyed on `namespace/name`, which repeats across clusters deployed
    // from one template, so it cannot be allowed to outlive its cluster.
    _actionFailure = null;
    final version = cluster.apiGroups[KubeVirt.group];
    final client = cluster.clientOrNull;
    if (version == null || client == null) {
      _machines = const [];
      _failure = null;
      _loading = false;
      notify();
      return;
    }
    _loading = true;
    _failure = null;
    notify();
    try {
      final read = await client.machines(version);
      if (_shown != cluster.id) return;
      _machines = read;
      _failure = null;
    } catch (e) {
      if (_shown != cluster.id) return;
      _machines = const [];
      _failure = brief(e);
    }
    _loading = false;
    notify();
  }

  /// Run a lifecycle verb, then re-read.
  ///
  /// The re-read is not optional and it is not immediate. `start` returns
  /// as soon as virt-controller has accepted the change, well before a VMI
  /// exists, so a list refreshed on the same tick shows the machine exactly
  /// as it was and reads as a button that did nothing.
  Future<void> perform(VmAction action, Machine machine, ManagedCluster cluster,
      {Duration settle = const Duration(milliseconds: 1500)}) async {
    final groupVersion = cluster.apiGroups[KubeVirt.group];
    final client = cluster.clientOrNull;
    if (groupVersion == null || client == null) return;
    _busy = machine.id;
    _actionFailure = null;
    notify();
    try {
      await client.perform(action, machine, groupVersion: groupVersion);
    } catch (e) {
      if (_shown == cluster.id) _actionFailure = (id: machine.id, why: brief(e));
      _busy = null;
      notify();
      return;
    }
    // The verb was accepted. A re-read that fails is a different fact and
    // is said differently.
    await Future<void>.delayed(settle);
    try {
      final read = await client.machines(groupVersion);
      if (_shown == cluster.id) _machines = read;
    } catch (e) {
      if (_shown == cluster.id) {
        final verb = action.name[0].toUpperCase() + action.name.substring(1);
        _actionFailure = (
          id: machine.id,
          why: '$verb was accepted, but the list could not be refreshed: ${brief(e)}. Refresh to see the result.'
        );
      }
    }
    _busy = null;
    notify();
  }

  int get running => _machines.where((m) => m.isRunning).length;

  /// Machines that have no `VirtualMachine` behind them. Worth counting on
  /// its own, because it is the difference between a cluster whose VMs come
  /// back after a reboot and one whose VMs do not.
  int get standalone => _machines.where((m) => !m.isManageable).length;

  int get withGPUs => _machines.where((m) => m.gpus.isNotEmpty).length;

  /// Machines whose root disk is an image: the other thing that separates a
  /// VM that comes back from one that does not, after a stop this time.
  int get ephemeral => _machines.where((m) => m.bootsFromEphemeralDisk).length;

  /// Grouped by namespace, which is how tenancy is usually drawn.
  List<({String namespace, List<Machine> machines})> get byNamespace {
    final groups = <String, List<Machine>>{};
    for (final m in _machines) {
      groups.putIfAbsent(m.namespace, () => []).add(m);
    }
    final keys = groups.keys.toList()..sort();
    return [for (final k in keys) (namespace: k, machines: groups[k]!..sort((a, b) => a.name.compareTo(b.name)))];
  }
}
