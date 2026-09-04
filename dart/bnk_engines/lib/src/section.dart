import 'cluster_store.dart';
import 'observable.dart';

/// The screens, in sidebar order.
enum Section {
  overview('Overview'),

  /// The cluster itself: how it is reached, what it is, and the way to
  /// forget it. First under every cluster, because it is where "Open" lands.
  cluster('Cluster'),
  tmmLive('TMM Live'),
  resources('Resources'),
  logs('Logs'),
  dpu('DPU Services'),
  nico('NICo'),
  kubevirt('KubeVirt'),
  terminal('Terminal');

  final String title;
  const Section(this.title);

  /// Whether this screen exists on a given cluster.
  ///
  /// NICo, DPU and KubeVirt appear only on a cluster running them, and
  /// better than a screen that is permanently empty on most clusters.
  /// Overview is nobody's: it reads every cluster.
  bool isAvailable(ManagedCluster cluster) {
    // A cluster the app cannot talk to has one screen: the one that says
    // why, and offers to forget it.
    if (!cluster.isUsable) return this == Section.cluster;
    return switch (this) {
      Section.overview => false,
      Section.nico => cluster.roles.contains(ClusterRole.nico),
      Section.dpu => cluster.roles.contains(ClusterRole.dpu),
      Section.kubevirt => cluster.roles.contains(ClusterRole.kubevirt),
      _ => true,
    };
  }

  /// The screens one cluster offers, in sidebar order.
  static List<Section> available(ManagedCluster cluster) =>
      [for (final s in values) if (s.isAvailable(cluster)) s];
}

/// An object another screen asked Resources to open.
class RevealRequest {
  final String kind;
  final String? namespace;
  final String name;
  const RevealRequest({required this.kind, required this.namespace, required this.name});

  @override
  bool operator ==(Object other) =>
      other is RevealRequest && other.kind == kind && other.namespace == namespace && other.name == name;

  @override
  int get hashCode => Object.hash(kind, namespace, name);
}

/// Which screen is showing, and what it was asked to show.
///
/// Exists because Overview names a broken pod and the natural next move is
/// to open it, which means one screen has to be able to send another
/// somewhere. Named to stay clear of the toolkit's own navigator.
class ScreenNavigator extends Observable {
  Section _section = Section.overview;
  RevealRequest? _pending;

  Section get section => _section;
  set section(Section value) {
    if (_section == value) return;
    _section = value;
    notify();
  }

  RevealRequest? get pending => _pending;

  /// Send the reader to one object, wherever they are now.
  void revealPod(String name, {String? namespace}) {
    _pending = RevealRequest(kind: 'pods', namespace: namespace, name: name);
    _section = Section.resources;
    notify();
  }

  /// Cleared only once the request has been acted on. The screen that
  /// honours a request keys its work on [pending], so clearing it first
  /// would cancel that work halfway.
  void clear() {
    if (_pending == null) return;
    _pending = null;
    notify();
  }
}
