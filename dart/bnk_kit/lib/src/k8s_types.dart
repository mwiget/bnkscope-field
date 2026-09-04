import 'dart:convert';
import 'dart:typed_data';

import 'json.dart';
import 'kube_client.dart';

/// The slices of the Kubernetes API Field reads. Every field here is one the
/// UI actually renders.

class VersionInfo {
  final String gitVersion;
  final String? platform;
  VersionInfo.fromJson(JsonMap j)
      : gitVersion = j['gitVersion'] as String,
        platform = asString(j['platform']);
}

class ObjectMeta {
  final String name;
  final String? namespace;
  final Map<String, String>? labels;
  final Map<String, String>? annotations;
  final DateTime? creationTimestamp;
  final List<OwnerReference>? ownerReferences;

  ObjectMeta.fromJson(JsonMap j)
      : name = j['name'] as String,
        namespace = asString(j['namespace']),
        labels = asStringMap(j['labels']),
        annotations = asStringMap(j['annotations']),
        creationTimestamp = asDate(j['creationTimestamp']),
        ownerReferences =
            asListOrNull(j['ownerReferences'], OwnerReference.fromJson);
}

class OwnerReference {
  final String kind;
  final String name;
  final bool? controller;
  OwnerReference.fromJson(JsonMap j)
      : kind = j['kind'] as String,
        name = j['name'] as String,
        controller = asBool(j['controller']);
}

/// Just enough of a ReplicaSet to hop from it to the Deployment that made it.
class ReplicaSet {
  final ObjectMeta metadata;
  ReplicaSet.fromJson(JsonMap j)
      : metadata = ObjectMeta.fromJson(mapOrEmpty(j['metadata']));
}

/// The `items` of a list response.
List<T> listItems<T>(JsonMap j, T Function(JsonMap) parse) =>
    asList(j['items'], parse);

/// The condition shape every CRD here uses.
class Condition {
  final String type;
  final String status;
  final String? reason;
  final String? message;
  Condition.fromJson(JsonMap j)
      : type = j['type'] as String,
        status = j['status'] as String,
        reason = asString(j['reason']),
        message = asString(j['message']);
}

bool isReady(List<Condition>? conditions) =>
    (conditions ?? const []).any((c) => c.type == 'Ready' && c.status == 'True');

/// How a container came to be in this pod, which decides how long it lasts.
enum ContainerKind {
  /// Declared in the pod spec. Survives a restart of the pod.
  durable,

  /// Attached to a running pod after the fact. Cannot be removed in place,
  /// and is gone the moment the pod is recreated.
  ephemeral,
}

class Pod {
  final ObjectMeta metadata;
  final PodSpec? spec;
  final PodStatus? status;

  Pod.fromJson(JsonMap j)
      : metadata = ObjectMeta.fromJson(mapOrEmpty(j['metadata'])),
        spec = asMap(j['spec']).let(PodSpec.fromJson),
        status = asMap(j['status']).let(PodStatus.fromJson);

  String get node => spec?.nodeName ?? '—';

  String get ready {
    final cs = status?.containerStatuses ?? const [];
    return '${cs.where((c) => c.ready == true).length}/${cs.length}';
  }

  /// Where a container is, if it is here at all.
  ///
  /// bnkscope injects the exporter as an ephemeral container, but a cluster
  /// can equally have it in the pod spec. Reporting which is not pedantry: an
  /// ephemeral exporter stops the next time TMM restarts, and a page that does
  /// not say so lets you find out later.
  ContainerKind? containerKind(String name) {
    if ((status?.containerStatuses ?? const []).any((c) => c.name == name)) {
      return ContainerKind.durable;
    }
    if ((status?.ephemeralContainerStatuses ?? const [])
        .any((c) => c.name == name)) {
      return ContainerKind.ephemeral;
    }
    return null;
  }

  bool hasContainer(String name) => containerKind(name) != null;

  /// Every container whose log can be followed.
  ///
  /// The log endpoint refuses a pod with more than one container unless told
  /// which, so a viewer that wants the whole pod has to ask for each
  /// separately: an f5-tmm pod is eight streams, not one.
  List<String> get logSources => [
        for (final c in spec?.containers ?? const <Container>[]) c.name,
        for (final c in spec?.ephemeralContainers ?? const <Container>[]) c.name,
      ];
}

class PodSpec {
  final String? nodeName;
  final List<Container> containers;
  final List<Container>? ephemeralContainers;
  final List<Volume>? volumes;
  PodSpec.fromJson(JsonMap j)
      : nodeName = asString(j['nodeName']),
        containers = asList(j['containers'], Container.fromJson),
        ephemeralContainers =
            asListOrNull(j['ephemeralContainers'], Container.fromJson),
        volumes = asListOrNull(j['volumes'], Volume.fromJson);
}

class Volume {
  final String name;
  Volume.fromJson(JsonMap j) : name = j['name'] as String;
}

class Container {
  final String name;
  final String? image;

  /// Read because an operator frequently says what it is for only here. The
  /// Sveltos agent names the k0rdent object it reports for in its own flags
  /// and nowhere else on the cluster.
  final List<String>? args;
  Container.fromJson(JsonMap j)
      : name = j['name'] as String,
        image = asString(j['image']),
        args = asStrings(j['args']);
}

class PodStatus {
  final String? phase;
  final String? podIP;
  final List<ContainerStatus>? containerStatuses;
  final List<ContainerStatus>? ephemeralContainerStatuses;
  PodStatus.fromJson(JsonMap j)
      : phase = asString(j['phase']),
        podIP = asString(j['podIP']),
        containerStatuses =
            asListOrNull(j['containerStatuses'], ContainerStatus.fromJson),
        ephemeralContainerStatuses = asListOrNull(
            j['ephemeralContainerStatuses'], ContainerStatus.fromJson);
}

class ContainerStatus {
  final String name;
  final bool? ready;
  final int? restartCount;
  final String? image;
  ContainerStatus.fromJson(JsonMap j)
      : name = j['name'] as String,
        ready = asBool(j['ready']),
        restartCount = asInt(j['restartCount']),
        image = asString(j['image']);
}

class Namespace {
  final ObjectMeta metadata;
  Namespace.fromJson(JsonMap j)
      : metadata = ObjectMeta.fromJson(mapOrEmpty(j['metadata']));
}

class Event {
  final ObjectMeta metadata;
  final String? reason;
  final String? message;
  final String? type;
  final int? count;
  final DateTime? lastTimestamp;
  final DateTime? eventTime;
  final InvolvedObject? involvedObject;

  Event.fromJson(JsonMap j)
      : metadata = ObjectMeta.fromJson(mapOrEmpty(j['metadata'])),
        reason = asString(j['reason']),
        message = asString(j['message']),
        type = asString(j['type']),
        count = asInt(j['count']),
        lastTimestamp = asDate(j['lastTimestamp']),
        eventTime = asDate(j['eventTime']),
        involvedObject = asMap(j['involvedObject']).let(InvolvedObject.fromJson);

  /// Events written by the newer API set `eventTime` and leave
  /// `lastTimestamp` null; the older path does the reverse.
  DateTime? get at => lastTimestamp ?? eventTime;
}

class InvolvedObject {
  final String? kind;
  final String? name;
  final String? namespace;
  InvolvedObject.fromJson(JsonMap j)
      : kind = asString(j['kind']),
        name = asString(j['name']),
        namespace = asString(j['namespace']);
}

class Secret {
  final ObjectMeta metadata;
  final Map<String, String>? data;
  Secret.fromJson(JsonMap j)
      : metadata = ObjectMeta.fromJson(mapOrEmpty(j['metadata'])),
        data = asStringMap(j['data']);

  /// Secret values are base64 in the API on top of whatever they already are,
  /// so a PEM arrives doubly wrapped.
  Uint8List? pem(String key) {
    final encoded = data?[key];
    if (encoded == null) return null;
    try {
      return base64.decode(base64.normalize(encoded.replaceAll(RegExp(r'\s'), '')));
    } on FormatException {
      return null;
    }
  }
}

/// A Kamaji tenant control plane: one hosted Kubernetes control plane, which
/// is how the DPF tenant clusters are run.
class TenantControlPlane {
  final ObjectMeta metadata;
  final TenantControlPlaneStatus? status;
  TenantControlPlane.fromJson(JsonMap j)
      : metadata = ObjectMeta.fromJson(mapOrEmpty(j['metadata'])),
        status = asMap(j['status']).let(TenantControlPlaneStatus.fromJson);

  bool get isReady => status?.kubernetesResources?.version?.status == 'Ready';
}

class TenantControlPlaneStatus {
  final String? controlPlaneEndpoint;
  final TenantResources? kubernetesResources;
  final Map<String, CertificateRef>? certificates;
  final CertificateRef? adminKubeconfig;
  TenantControlPlaneStatus.fromJson(JsonMap j)
      : controlPlaneEndpoint = asString(j['controlPlaneEndpoint']),
        kubernetesResources =
            asMap(j['kubernetesResources']).let(TenantResources.fromJson),
        certificates = asMap(j['certificates']).let((m) => {
              for (final e in m.entries)
                if (e.value is Map)
                  e.key: CertificateRef.fromJson(Map<String, dynamic>.from(e.value as Map))
            }),
        adminKubeconfig =
            asMap(asMap(j['kubeconfig'])?['admin']).let(CertificateRef.fromJson);
}

class TenantResources {
  final TenantVersion? version;
  TenantResources.fromJson(JsonMap j)
      : version = asMap(j['version']).let(TenantVersion.fromJson);
}

class TenantVersion {
  final String? status;
  final String? version;
  TenantVersion.fromJson(JsonMap j)
      : status = asString(j['status']),
        version = asString(j['version']);
}

class CertificateRef {
  final String? secretName;
  final DateTime? lastUpdate;
  CertificateRef.fromJson(JsonMap j)
      : secretName = asString(j['secretName']),
        lastUpdate = asDate(j['lastUpdate']);
}

class Node {
  final ObjectMeta metadata;
  final NodeStatus? status;
  Node.fromJson(JsonMap j)
      : metadata = ObjectMeta.fromJson(mapOrEmpty(j['metadata'])),
        status = asMap(j['status']).let(NodeStatus.fromJson);

  bool get isReady => isReadyConditions(status?.conditions);

  /// Device names under a GPU vendor's prefix that are not GPUs: BlueField
  /// scalable functions and virtual functions, and the generic passthrough
  /// resource the SR-IOV device plugin uses for NICs.
  static const notAGPU = ['bf_sf', 'bf_vf', 'hostdev', 'mlnx', 'sriov'];

  /// Extended resources this node offers for GPUs, as name and count.
  ///
  /// Two naming schemes turn up and they mean different things. The GPU
  /// Operator advertises `nvidia.com/gpu` for containers; KubeVirt advertises
  /// one resource per PCI device it is permitted to pass through, named after
  /// the device, `nvidia.com/GA104GL_RTX_A4000`. So the vendor prefix has to
  /// be matched rather than either exact name. Which is why the exclusions
  /// exist: `nvidia.com/` is a vendor, not a product line, and a BlueField
  /// DPU cluster advertises `nvidia.com/bf_sf`, scalable functions, which are
  /// NICs. Counting those reported twenty-six GPUs on a cluster that has none.
  List<({String name, int count})> get gpuResources {
    final out = <({String name, int count})>[];
    for (final e in (status?.allocatable ?? const {}).entries) {
      if (!e.key.startsWith('nvidia.com/') && !e.key.startsWith('amd.com/')) {
        continue;
      }
      final device = e.key.split('/').last;
      if (notAGPU.any(device.startsWith)) continue;
      final count = int.tryParse(e.value);
      if (count == null || count <= 0) continue;
      out.add((name: device, count: count));
    }
    out.sort((a, b) => a.name.compareTo(b.name));
    return out;
  }
}

/// [isReady] under a name that does not clash with the getters that call it.
bool isReadyConditions(List<Condition>? conditions) => isReady(conditions);

class NodeStatus {
  final NodeInfo? nodeInfo;
  final List<Condition>? conditions;

  /// Quantities as strings, `"2"`, `"64Gi"`. Only the extended resources are
  /// read here and those are always whole numbers, so nothing parses the
  /// suffix form.
  final Map<String, String>? allocatable;
  NodeStatus.fromJson(JsonMap j)
      : nodeInfo = asMap(j['nodeInfo']).let(NodeInfo.fromJson),
        conditions = asListOrNull(j['conditions'], Condition.fromJson),
        allocatable = asStringMap(j['allocatable']);
}

class NodeInfo {
  final String? architecture;
  final String? osImage;
  final String? kubeletVersion;
  NodeInfo.fromJson(JsonMap j)
      : architecture = asString(j['architecture']),
        osImage = asString(j['osImage']),
        kubeletVersion = asString(j['kubeletVersion']);
}

/// Just enough of a Deployment to read what its pods are launched with.
class Deployment {
  final ObjectMeta metadata;
  final DeploymentSpec? spec;
  Deployment.fromJson(JsonMap j)
      : metadata = ObjectMeta.fromJson(mapOrEmpty(j['metadata'])),
        spec = asMap(j['spec']).let(DeploymentSpec.fromJson);

  /// The flags of the first container, which for a single-purpose operator is
  /// the only container.
  List<String> get podArgs =>
      spec?.template?.spec?.containers.firstOrNull?.args ?? const [];
}

class DeploymentSpec {
  final int? replicas;
  final PodTemplate? template;
  DeploymentSpec.fromJson(JsonMap j)
      : replicas = asInt(j['replicas']),
        template = asMap(j['template']).let(PodTemplate.fromJson);
}

class PodTemplate {
  final PodSpec? spec;
  PodTemplate.fromJson(JsonMap j)
      : spec = asMap(j['spec']).let(PodSpec.fromJson);
}

/// `/apis`: which API groups this server serves, and at which version.
class APIGroupList {
  final List<APIGroup> groups;
  APIGroupList.fromJson(JsonMap j)
      : groups = asList(j['groups'], APIGroup.fromJson);
}

class APIGroup {
  final String name;
  final String? preferredVersion;
  APIGroup.fromJson(JsonMap j)
      : name = j['name'] as String,
        preferredVersion = asString(asMap(j['preferredVersion'])?['groupVersion']);
}

/// `/apis/<group>/<version>`: which kinds that group serves.
class APIResourceList {
  final List<String> resources;
  APIResourceList.fromJson(JsonMap j)
      : resources = [
          for (final r in asList(j['resources'], (m) => m['name']))
            if (r is String) r
        ];
}

/// The group to preferred-version map, split out so the duplicate case can
/// be tested without a cluster that misbehaves on demand.
///
/// First one wins. The list is assembled by the apiserver out of whatever the
/// aggregated APIServices register, so a duplicate is somebody else's bug,
/// but it must not take the app down from inside a call every caller believes
/// is safe.
Map<String, String> preferredVersions(APIGroupList list) {
  final out = <String, String>{};
  for (final group in list.groups) {
    final version = group.preferredVersion;
    if (version != null) out.putIfAbsent(group.name, () => version);
  }
  return out;
}

extension CoreApi on KubeClient {
  Future<VersionInfo> version() => getJson('/version', VersionInfo.fromJson);

  Future<List<Node>> nodes() =>
      getJson('/api/v1/nodes', (j) => listItems(j, Node.fromJson));

  Future<Secret> secret({required String namespace, required String name}) =>
      getJson('/api/v1/namespaces/$namespace/secrets/$name', Secret.fromJson);

  /// Every API group the server serves, mapped to its preferred version:
  /// `"kubevirt.io": "kubevirt.io/v1"`.
  ///
  /// One request that answers "is this thing installed" for every operator
  /// at once, which is why detection asks for it first and passes the result
  /// around rather than probing each group separately. It also removes the
  /// need to guess a version: k0rdent serves `v1beta1` on a management
  /// cluster and `v1alpha1` on a cluster that picked up a stray CRD from a
  /// service template, and a hard-coded path would 404 on one of them.
  Future<Map<String, String>> apiGroups() async =>
      preferredVersions(await getJson('/apis', APIGroupList.fromJson));

  /// The plural resource names one group version serves.
  ///
  /// Distinguishes a group that is fully installed from one represented by a
  /// single stray CRD, and is the cheapest way to see an API that exists but
  /// holds no objects: `licenses` on a k0rdent Enterprise cluster that has
  /// not been given its licence yet.
  Future<Set<String>> apiResources(String groupVersion) async =>
      (await getJson('/apis/$groupVersion', APIResourceList.fromJson))
          .resources
          .toSet();

  Future<Deployment> deployment(
          {required String namespace, required String name}) =>
      getJson('/apis/apps/v1/namespaces/$namespace/deployments/$name',
          Deployment.fromJson);

  /// Kamaji's tenant control planes, cluster-wide.
  ///
  /// This is the link between the two clusters in the sidebar: infra hosts
  /// tenant1's control plane, and the endpoint here is the one in tenant1's
  /// kubeconfig. Nothing else in the app says they are related.
  Future<List<TenantControlPlane>> tenantControlPlanes() => getJson(
      '/apis/kamaji.clastix.io/v1alpha1/tenantcontrolplanes',
      (j) => listItems(j, TenantControlPlane.fromJson));

  /// Warning events, cluster-wide.
  ///
  /// The server-side filter matters: on a busy cluster the Normal events
  /// outnumber the Warnings by orders of magnitude, and none of them are what
  /// "is anything wrong" is asking about.
  Future<List<Event>> warningEvents() => getJson(
      '/api/v1/events', (j) => listItems(j, Event.fromJson),
      query: const {'fieldSelector': 'type=Warning'});

  Future<List<String>> namespaces() async {
    final items = await getJson(
        '/api/v1/namespaces', (j) => listItems(j, Namespace.fromJson));
    return [for (final n in items) n.metadata.name]..sort();
  }

  Future<List<Pod>> pods({String? namespace, String? labelSelector}) {
    final path =
        namespace == null ? '/api/v1/pods' : '/api/v1/namespaces/$namespace/pods';
    return getJson(path, (j) => listItems(j, Pod.fromJson), query: {
      if (labelSelector != null) 'labelSelector': labelSelector,
    });
  }
}

extension Let<T extends Object> on T? {
  R? let<R>(R Function(T) f) {
    final self = this;
    return self == null ? null : f(self);
  }
}
