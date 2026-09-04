import 'package:bnk_kit/bnk_kit.dart';

import 'brief.dart';
import 'cluster_store.dart';
import 'observable.dart';

/// The DPU service wiring, read straight off the cluster.
class DpuEngine extends Observable {
  List<ServiceChain> _chains = const [];
  List<ServiceInterface> _interfaces = const [];
  bool _loading = false;
  String? _failure;

  List<ServiceChain> get chains => _chains;
  List<ServiceInterface> get interfaces => _interfaces;
  bool get loading => _loading;
  String? get failure => _failure;

  Future<void> load(ManagedCluster cluster) async {
    final client = cluster.clientOrNull;
    if (client == null) return;
    _loading = true;
    _failure = null;
    notify();
    try {
      _chains = await client.serviceChains();
      _interfaces = await client.serviceInterfaces();
    } catch (e) {
      _chains = const [];
      _interfaces = const [];
      _failure = brief(e);
    }
    _loading = false;
    notify();
  }

  /// Chains sit on one node each, and the pair of nodes carry the same
  /// wiring, so grouping by node is how you see whether they actually match.
  List<({String node, List<ServiceChain> chains})> get chainsByNode {
    final groups = <String, List<ServiceChain>>{};
    for (final c in _chains) {
      groups.putIfAbsent(c.spec.node ?? 'unassigned', () => []).add(c);
    }
    final keys = groups.keys.toList()..sort();
    return [for (final k in keys) (node: k, chains: groups[k]!)];
  }

  /// Interfaces by kind, in the order traffic meets them: the wire first,
  /// then the host PFs, then the service ends inside.
  List<({String type, List<ServiceInterface> interfaces})> get interfacesByType {
    const order = {'physical': 0, 'pf': 1, 'service': 2};
    final groups = <String, List<ServiceInterface>>{};
    for (final i in _interfaces) {
      groups.putIfAbsent(i.spec.interfaceType ?? 'other', () => []).add(i);
    }
    final keys = groups.keys.toList()
      ..sort((a, b) {
        final byOrder = (order[a] ?? 9).compareTo(order[b] ?? 9);
        return byOrder != 0 ? byOrder : a.compareTo(b);
      });
    return [
      for (final k in keys)
        (type: k, interfaces: groups[k]!..sort((a, b) => a.interfaceName.compareTo(b.interfaceName)))
    ];
  }

  int get readyChains => _chains.where((c) => c.isReady).length;
  int get readyInterfaces => _interfaces.where((i) => i.isReady).length;
}
