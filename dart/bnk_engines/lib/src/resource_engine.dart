import 'package:bnk_kit/bnk_kit.dart';

import 'brief.dart';
import 'cluster_store.dart';
import 'observable.dart';

enum SummaryTone { good, bad, neutral }

/// Lists objects of one kind, and holds what a detail view needs.
class ResourceEngine extends Observable {
  List<RawObject> _objects = const [];
  List<String> _namespaces = const [];
  bool _loading = false;
  String? _failure;
  List<Event> _events = const [];
  bool _loadingEvents = false;

  ResourceKind _kind = ResourceKind.all[0];
  String? _namespace;
  String _query = '';

  List<RawObject> get objects => _objects;
  List<String> get namespaces => _namespaces;
  bool get loading => _loading;
  String? get failure => _failure;
  List<Event> get events => _events;
  bool get loadingEvents => _loadingEvents;

  ResourceKind get kind => _kind;
  set kind(ResourceKind v) {
    _kind = v;
    notify();
  }

  String? get namespace => _namespace;
  set namespace(String? v) {
    _namespace = v;
    notify();
  }

  String get query => _query;
  set query(String v) {
    _query = v;
    notify();
  }

  List<RawObject> get visible {
    final needle = _query.trim().toLowerCase();
    if (needle.isEmpty) return _objects;
    return [
      for (final o in _objects)
        if (o.name.toLowerCase().contains(needle) || (o.namespace ?? '').toLowerCase().contains(needle)) o
    ];
  }

  Future<void> loadNamespaces(ManagedCluster cluster) async {
    final client = cluster.clientOrNull;
    if (client == null) return;
    try {
      _namespaces = await client.namespaces();
    } catch (_) {
      _namespaces = const [];
    }
    notify();
  }

  Future<void> load(ManagedCluster cluster) async {
    final client = cluster.clientOrNull;
    if (client == null) return;
    _loading = true;
    _failure = null;
    notify();
    try {
      final list = await client.list(_kind, namespace: _kind.namespaced ? _namespace : null);
      list.sort((a, b) {
        final ns = (a.namespace ?? '').compareTo(b.namespace ?? '');
        return ns != 0 ? ns : a.name.compareTo(b.name);
      });
      _objects = list;
    } catch (e) {
      _objects = const [];
      _failure = brief(e);
    }
    _loading = false;
    notify();
  }

  /// What has been said about one object. The reason to open a pod at all
  /// is usually that something is wrong with it, and the events are where
  /// the cluster says what.
  Future<void> loadEvents(RawObject object, ManagedCluster cluster) async {
    _events = const [];
    final namespace = object.namespace;
    final client = cluster.clientOrNull;
    if (namespace == null || client == null) {
      notify();
      return;
    }
    _loadingEvents = true;
    notify();
    try {
      _events = await client.events(about: object.name, namespace: namespace);
    } catch (_) {
      _events = const [];
    }
    _loadingEvents = false;
    notify();
  }
}

/// The one-line summary a row shows, per kind.
///
/// Written per kind rather than generically because a useful summary is
/// different every time: a pod's is its readiness, a service's is its
/// address, a node's is its version.
class ResourceSummary {
  static ({String text, SummaryTone tone}) line(RawObject object, ResourceKind kind) {
    switch (kind.plural) {
      case 'pods':
        final statuses = object.array(['status', 'containerStatuses']);
        final ready = statuses.where((s) => s['ready'] == true).length;
        var restarts = 0;
        for (final s in statuses) {
          final r = s['restartCount'];
          if (r is num && r > restarts) restarts = r.toInt();
        }
        final phase = object.string(['status', 'phase']) ?? '?';
        final node = object.string(['spec', 'nodeName']) ?? '—';
        final text = '$ready/${statuses.length} ready · $phase'
            '${restarts > 0 ? ' · $restarts restarts' : ''} · $node';
        final healthy = phase == 'Running' && ready == statuses.length && statuses.isNotEmpty;
        return (text: text, tone: phase == 'Succeeded' ? SummaryTone.neutral : (healthy ? SummaryTone.good : SummaryTone.bad));

      case 'deployments' || 'statefulsets':
        final ready = object.integer(['status', 'readyReplicas']) ?? 0;
        final wanted = object.integer(['spec', 'replicas']) ?? 0;
        return (text: '$ready/$wanted ready', tone: ready == wanted ? SummaryTone.good : SummaryTone.bad);

      case 'daemonsets':
        final ready = object.integer(['status', 'numberReady']) ?? 0;
        final wanted = object.integer(['status', 'desiredNumberScheduled']) ?? 0;
        return (text: '$ready/$wanted ready', tone: ready == wanted ? SummaryTone.good : SummaryTone.bad);

      case 'services':
        final type = object.string(['spec', 'type']) ?? 'ClusterIP';
        final ip = object.string(['spec', 'clusterIP']) ?? '—';
        final ports = [for (final p in object.array(['spec', 'ports'])) if (p['port'] != null) '${p['port']}'].join(',');
        return (text: '$type · $ip${ports.isEmpty ? '' : ' · $ports'}', tone: SummaryTone.neutral);

      case 'configmaps':
        final data = object.json['data'];
        final keys = data is Map ? data.length : 0;
        return (text: '$keys key${keys == 1 ? '' : 's'}', tone: SummaryTone.neutral);

      case 'events':
        final type = object.string(['type']) ?? '?';
        final reason = object.string(['reason']) ?? '';
        final about = object.string(['involvedObject', 'name']) ?? '';
        return (text: '$reason · $about', tone: type == 'Warning' ? SummaryTone.bad : SummaryTone.neutral);

      case 'nodes':
        final ready = object.array(['status', 'conditions']).any((c) => c['type'] == 'Ready' && c['status'] == 'True');
        final version = object.string(['status', 'nodeInfo', 'kubeletVersion']) ?? '?';
        final arch = object.string(['status', 'nodeInfo', 'architecture']) ?? '';
        return (text: '${ready ? 'Ready' : 'NotReady'} · $version · $arch', tone: ready ? SummaryTone.good : SummaryTone.bad);

      default:
        return (text: '', tone: SummaryTone.neutral);
    }
  }
}
