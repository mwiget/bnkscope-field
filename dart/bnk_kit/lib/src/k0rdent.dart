import 'json.dart';
import 'k8s_types.dart';
import 'kube_client.dart';

/// Recognising k0rdent, Mirantis' cluster manager, from the inside of a
/// cluster, without being told which cluster it is.
///
/// Two questions that look like one and are not. "Is this a k0rdent
/// management cluster" is answered by the `k0rdent.mirantis.com` API being
/// served here. "Is this cluster managed by k0rdent" is answered somewhere
/// else entirely, because k0rdent leaves a managed cluster almost unmarked:
/// no labels, no annotations, no CRDs of its own. What it does leave is a
/// Sveltos agent, and that agent is launched with the name of the object it
/// belongs to.
class K0rdent {
  static const group = 'k0rdent.mirantis.com';

  /// `--name=value` out of a container's argument list.
  static String? flag(String name, List<String> args) {
    for (final arg in args) {
      if (arg.startsWith('$name=')) return arg.substring(name.length + 1);
    }
    return null;
  }
}

/// What a cluster is to k0rdent.
enum K0rdentRole {
  /// Runs the controllers, serves the API, holds the ClusterDeployments.
  management,

  /// Provisioned or adopted by a management cluster elsewhere.
  managed,
}

/// Which distribution. The chart names differ and nothing else does.
enum K0rdentEdition {
  /// Mirantis' commercial build, `k0rdent-enterprise`. Adds a licence
  /// controller and the `licenses` API.
  enterprise,

  /// Upstream k0rdent/KCM.
  community,
}

/// The k0rdent object a managed cluster belongs to, read out of the agent
/// that k0rdent installed on it.
class ManagedBy {
  /// The namespace of the ClusterDeployment on the management cluster,
  /// `kcm-system` on a default install.
  final String namespace;

  /// The ClusterDeployment's name.
  final String name;

  /// `Capi` for a cluster k0rdent provisioned, `Sveltos` for one adopted
  /// through the `adopted-cluster` template. Absent on older agents.
  final String? clusterType;

  const ManagedBy(
      {required this.namespace, required this.name, this.clusterType});

  @override
  bool operator ==(Object other) =>
      other is ManagedBy &&
      other.namespace == namespace &&
      other.name == name &&
      other.clusterType == clusterType;

  @override
  int get hashCode => Object.hash(namespace, name, clusterType);
}

/// Everything the probe managed to learn. All of it optional: a read-only
/// token, a partially installed cluster and an unreachable apiserver all
/// produce a partial answer, and a partial answer is worth more than none.
class K0rdentFingerprint {
  K0rdentRole? role;
  K0rdentEdition? edition;

  /// The k0rdent version, from the Release object: `2.1.0-rc1.2`.
  String? version;

  /// The Release name, which is also the KCM template name.
  String? release;

  /// CAPI providers the management cluster reports as available.
  List<String> providers = const [];
  ManagedBy? managedBy;

  bool get isK0rdent => role != null;

  /// A single line for a badge or a subtitle.
  String get summary {
    switch (role) {
      case null:
        return 'not k0rdent';
      case K0rdentRole.management:
        final name = switch (edition) {
          K0rdentEdition.enterprise => 'Enterprise',
          K0rdentEdition.community => 'Community',
          null => 'k0rdent',
        };
        return [name, version].nonNulls.join(' ');
      case K0rdentRole.managed:
        final by = managedBy;
        if (by == null) return 'managed by k0rdent';
        return 'managed as ${by.namespace}/${by.name}';
    }
  }
}

/// The singleton that says a management cluster is a management cluster.
class K0rdentManagement {
  final ObjectMeta metadata;
  final String? specRelease;
  final String? statusRelease;
  final List<String>? availableProviders;
  final List<Condition>? conditions;

  K0rdentManagement.fromJson(JsonMap j)
      : metadata = ObjectMeta.fromJson(mapOrEmpty(j['metadata'])),
        specRelease = asString(asMap(j['spec'])?['release']),
        statusRelease = asString(asMap(j['status'])?['release']),
        availableProviders = asStrings(asMap(j['status'])?['availableProviders']),
        conditions = asListOrNull(asMap(j['status'])?['conditions'], Condition.fromJson);

  bool get isReady => isReadyConditions(conditions);
}

/// What a management cluster is pinned to: one CAPI version, one KCM chart,
/// one regional chart, and the provider set.
class K0rdentRelease {
  final ObjectMeta metadata;
  final String? version;
  final String? kcmTemplate;
  final String? capiTemplate;
  final String? regionalTemplate;
  final List<String> providerTemplates;

  K0rdentRelease.fromJson(JsonMap j)
      : metadata = ObjectMeta.fromJson(mapOrEmpty(j['metadata'])),
        version = asString(asMap(j['spec'])?['version']),
        kcmTemplate = _template(asMap(j['spec'])?['kcm']),
        capiTemplate = _template(asMap(j['spec'])?['capi']),
        regionalTemplate = _template(asMap(j['spec'])?['regional']),
        providerTemplates = [
          for (final p in asList(asMap(j['spec'])?['providers'], (m) => m))
            if (_template(p) case final t?) t
        ];

  static String? _template(Object? ref) => asString(asMap(ref)?['template']);
}

/// One managed cluster, as the management cluster sees it.
class ClusterDeployment {
  final ObjectMeta metadata;
  final String? template;
  final String? credential;
  final List<Condition>? conditions;

  ClusterDeployment.fromJson(JsonMap j)
      : metadata = ObjectMeta.fromJson(mapOrEmpty(j['metadata'])),
        template = asString(asMap(j['spec'])?['template']),
        credential = asString(asMap(j['spec'])?['credential']),
        conditions = asListOrNull(asMap(j['status'])?['conditions'], Condition.fromJson);

  String get id => '${metadata.namespace ?? ''}/${metadata.name}';
  bool get isReady => isReadyConditions(conditions);
}

extension K0rdentApi on KubeClient {
  /// Ask the cluster what it is, in as few round trips as it can be done.
  ///
  /// [groups] is the discovery map from [CoreApi.apiGroups]. It is passed in
  /// rather than fetched because the caller is already probing several things
  /// and `/apis` answers all of them at once.
  Future<K0rdentFingerprint> k0rdentFingerprint(Map<String, String> groups) async {
    final found = K0rdentFingerprint();

    // The management cluster is checked FIRST, and its answer wins, because
    // the managed-cluster test below fires on it too. k0rdent registers the
    // management cluster with Sveltos as a cluster it manages, so the agent
    // there is launched with exactly the flag that otherwise means "I am
    // somebody's child". Testing in the other order labels every management
    // cluster as managed.
    final groupVersion = groups[K0rdent.group];
    if (groupVersion != null) {
      // The group is served, so the answer is here; if its resource list
      // cannot be read the answer is unknown, not "managed".
      final Set<String> resources;
      try {
        resources = await apiResources(groupVersion);
      } catch (_) {
        return found;
      }
      final servesManagements = resources.contains('managements');
      K0rdentManagement? management;
      if (servesManagements) {
        try {
          management = await k0rdentManagement(groupVersion);
        } catch (_) {}
      }
      if (management != null) {
        found.role = K0rdentRole.management;
        found.release = management.statusRelease ?? management.specRelease;

        // Two independent reads of the edition, because either can be
        // missing. The Release object carries the chart name, and the
        // enterprise chart is called `k0rdent-enterprise` where upstream is
        // `kcm`. If no Release is readable, the `licenses` API is the
        // fallback: it ships only with enterprise, and the API is there from
        // the moment the chart is applied.
        K0rdentRelease? release;
        try {
          release = await k0rdentRelease(groupVersion, named: found.release);
        } catch (_) {}
        if (release != null) {
          found.version = release.version;
          final template = release.kcmTemplate ?? release.metadata.name;
          found.edition = template.startsWith('k0rdent-enterprise')
              ? K0rdentEdition.enterprise
              : K0rdentEdition.community;
        }
        found.edition ??= resources.contains('licenses')
            ? K0rdentEdition.enterprise
            : K0rdentEdition.community;
        found.providers = management.availableProviders ?? const [];
        return found;
      }

      // The group serves `managements` and the object did not come back:
      // RBAC that forbids the read, or the aggregated API answering 500.
      // Falling through would run the managed test on a management cluster,
      // the one thing the ordering above exists to prevent. Say what is
      // known instead of guessing.
      if (servesManagements) {
        found.role = K0rdentRole.management;
        return found;
      }
    }

    // Nothing k0rdent installs on a managed cluster names k0rdent. The
    // Sveltos agent is the exception, and only in its arguments: it is told
    // which object on which management cluster it reports for, and those
    // three flags are the whole of the evidence.
    Deployment? agent;
    try {
      agent = await deployment(
          namespace: 'projectsveltos', name: 'sveltos-agent-manager');
    } catch (_) {}
    if (agent != null) {
      final args = agent.podArgs;
      final namespace = K0rdent.flag('--cluster-namespace', args);
      final name = K0rdent.flag('--cluster-name', args);
      if (args.contains('--current-cluster=managed-cluster') &&
          namespace != null &&
          name != null) {
        found.role = K0rdentRole.managed;
        found.managedBy = ManagedBy(
            namespace: namespace,
            name: name,
            clusterType: K0rdent.flag('--cluster-type', args));
      }
    }
    return found;
  }

  /// The Management singleton, whatever the served version happens to be.
  Future<K0rdentManagement?> k0rdentManagement(String groupVersion) async {
    final items = await getJson('/apis/$groupVersion/managements',
        (j) => listItems(j, K0rdentManagement.fromJson));
    return items.firstOrNull;
  }

  Future<K0rdentRelease?> k0rdentRelease(String groupVersion,
      {String? named}) async {
    final releases = await getJson('/apis/$groupVersion/releases',
        (j) => listItems(j, K0rdentRelease.fromJson));
    // Prefer the one the Management is actually on. A cluster keeps every
    // Release it has ever been offered, so "the first one" is frequently a
    // version this cluster is not running.
    return releases.where((r) => r.metadata.name == named).firstOrNull ??
        releases.firstOrNull;
  }

  /// Every managed cluster this management cluster owns.
  Future<List<ClusterDeployment>> clusterDeployments(String groupVersion) =>
      getJson('/apis/$groupVersion/clusterdeployments',
          (j) => listItems(j, ClusterDeployment.fromJson));
}
