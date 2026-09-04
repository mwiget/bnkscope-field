import 'json.dart';
import 'k8s_types.dart';
import 'kube_client.dart';

/// The DPU service API, `svc.dpu.nvidia.com`.
///
/// Not the DPF operator, which is a different API group. This is the layer
/// that steers traffic on the DPU: interfaces are the ends, chains are the
/// wiring between them, and it is how packets reach HBN and TMM.
class ServiceChain {
  final ObjectMeta metadata;
  final ServiceChainSpec spec;
  final List<Condition>? conditions;

  ServiceChain.fromJson(JsonMap j)
      : metadata = ObjectMeta.fromJson(mapOrEmpty(j['metadata'])),
        spec = ServiceChainSpec.fromJson(mapOrEmpty(j['spec'])),
        conditions = asListOrNull(asMap(j['status'])?['conditions'], Condition.fromJson);

  String get id => '${metadata.namespace ?? ''}/${metadata.name}';
  bool get isReady => isReadyConditions(conditions);
}

class ServiceChainSpec {
  final String? node;
  final List<ServiceSwitch>? switches;
  ServiceChainSpec.fromJson(JsonMap j)
      : node = asString(j['node']),
        switches = asListOrNull(j['switches'], ServiceSwitch.fromJson);
}

/// One hop: the ports it joins, and the MTU it carries.
class ServiceSwitch {
  final List<ServicePort>? ports;
  final int? serviceMTU;
  ServiceSwitch.fromJson(JsonMap j)
      : ports = asListOrNull(j['ports'], ServicePort.fromJson),
        serviceMTU = asInt(j['serviceMTU']);
}

class ServicePort {
  final InterfaceSelector? serviceInterface;
  ServicePort.fromJson(JsonMap j)
      : serviceInterface = asMap(j['serviceInterface']).let(InterfaceSelector.fromJson);
}

class InterfaceSelector {
  final Map<String, String>? matchLabels;
  InterfaceSelector.fromJson(JsonMap j) : matchLabels = asStringMap(j['matchLabels']);

  /// What the selector is pointing at, in the words the object uses.
  ///
  /// A port is matched by label rather than named, so the readable end has
  /// to be reassembled: a physical port says `interface: p0`, a service end
  /// says which interface of which service.
  String get described {
    final labels = matchLabels;
    if (labels == null) return '—';
    final physical = labels['interface'];
    if (physical != null) return physical;
    final interface = labels['svc.dpu.nvidia.com/interface'];
    final service = labels['svc.dpu.nvidia.com/service'];
    return switch ((interface, service)) {
      (final i?, final s?) => '$i · $s',
      (final i?, null) => i,
      (null, final s?) => s,
      _ => ([for (final e in labels.entries) '${e.key}=${e.value}']..sort()).join(' '),
    };
  }
}

class ServiceInterface {
  final ObjectMeta metadata;
  final ServiceInterfaceSpec spec;
  final List<Condition>? conditions;

  ServiceInterface.fromJson(JsonMap j)
      : metadata = ObjectMeta.fromJson(mapOrEmpty(j['metadata'])),
        spec = ServiceInterfaceSpec.fromJson(mapOrEmpty(j['spec'])),
        conditions = asListOrNull(asMap(j['status'])?['conditions'], Condition.fromJson);

  String get id => '${metadata.namespace ?? ''}/${metadata.name}';
  bool get isReady => isReadyConditions(conditions);

  /// The interface's own name, wherever the type happens to keep it.
  String get interfaceName =>
      spec.service?.interfaceName ??
      spec.physical?.interfaceName ??
      spec.pf?.pfID.let((id) => 'pf$id') ??
      metadata.name;

  String? get detail {
    final service = spec.service;
    if (service == null) return null;
    return [service.network, service.serviceID].nonNulls.join(' · ');
  }
}

class ServiceInterfaceSpec {
  final String? interfaceType;
  final String? node;
  final ServiceEnd? service;
  final PhysicalEnd? physical;
  final PFEnd? pf;
  ServiceInterfaceSpec.fromJson(JsonMap j)
      : interfaceType = asString(j['interfaceType']),
        node = asString(j['node']),
        service = asMap(j['service']).let(ServiceEnd.fromJson),
        physical = asMap(j['physical']).let(PhysicalEnd.fromJson),
        pf = asMap(j['pf']).let(PFEnd.fromJson);
}

class ServiceEnd {
  final String? interfaceName;
  final String? network;
  final String? serviceID;
  ServiceEnd.fromJson(JsonMap j)
      : interfaceName = asString(j['interfaceName']),
        network = asString(j['network']),
        serviceID = asString(j['serviceID']);
}

class PhysicalEnd {
  final String? interfaceName;
  PhysicalEnd.fromJson(JsonMap j) : interfaceName = asString(j['interfaceName']);
}

class PFEnd {
  final int? pfID;
  PFEnd.fromJson(JsonMap j) : pfID = asInt(j['pfID']);
}

extension DpuApi on KubeClient {
  Future<List<ServiceChain>> serviceChains() => getJson(
      '/apis/svc.dpu.nvidia.com/v1alpha1/servicechains',
      (j) => listItems(j, ServiceChain.fromJson));

  Future<List<ServiceInterface>> serviceInterfaces() => getJson(
      '/apis/svc.dpu.nvidia.com/v1alpha1/serviceinterfaces',
      (j) => listItems(j, ServiceInterface.fromJson));
}
