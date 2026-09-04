import 'dart:convert';

import 'json.dart';
import 'k8s_types.dart';
import 'kube_client.dart';

/// KubeVirt: virtual machines as Kubernetes objects.
///
/// Two kinds, and the difference decides what can be done to them. A
/// [VirtualMachine] is the durable declaration: it has a run state, so it can
/// be started, stopped and restarted, and it survives its own instance. A
/// [VirtualMachineInstance] is one running machine. Usually a VMI belongs to
/// a VM, but not always. A VMI applied on its own is legal and is what a
/// hand-written lab manifest produces; it runs perfectly and there is nothing
/// to start or stop, because the object that would hold that state does not
/// exist. Anything acting on these has to tell the two apart rather than
/// assume the pairing.
class KubeVirt {
  static const group = 'kubevirt.io';

  /// Lifecycle verbs live in their own group, served by the virt-api
  /// aggregated apiserver rather than by the CRD.
  static const subresourceGroup = 'subresources.kubevirt.io';
}

/// What can be asked of a [VirtualMachine].
enum VmAction { start, stop, restart }

/// A machine's declared run state.
class VirtualMachine {
  final ObjectMeta metadata;
  final VmSpec? spec;
  final VmStatus? status;

  VirtualMachine.fromJson(JsonMap j)
      : metadata = ObjectMeta.fromJson(mapOrEmpty(j['metadata'])),
        spec = asMap(j['spec']).let(VmSpec.fromJson),
        status = asMap(j['status']).let(VmStatus.fromJson);

  String get id => '${metadata.namespace ?? ''}/${metadata.name}';

  /// Whether the declaration asks for the machine to be up.
  ///
  /// `Always` and `Halted` say so outright. `Manual`, `RerunOnFailure` and
  /// `Once` do not: under those the machine is up when it has been started
  /// and not stopped, and the only record of that is the status: `created`
  /// says an instance exists. Reading "not Halted" as "running" offered Stop
  /// to a manually managed machine that was stopped, and never Start.
  bool get isRunning {
    final running = spec?.running;
    if (running != null) return running;
    switch (spec?.runStrategy) {
      case 'Always':
        return true;
      case 'Halted':
        return false;
      default:
        final created = status?.created;
        if (created != null) return created;
        final printable = status?.printableStatus;
        return printable != null && printable != 'Stopped';
    }
  }

  String get state =>
      status?.printableStatus ?? (isRunning ? 'Starting' : 'Stopped');
}

class VmSpec {
  /// `Always`, `Halted`, `Manual`, `RerunOnFailure`.
  final String? runStrategy;

  /// The older spelling. Still what most manifests carry.
  final bool? running;

  /// The instance the machine is built from: `template.spec`.
  final VmiSpec? templateSpec;

  VmSpec.fromJson(JsonMap j)
      : runStrategy = asString(j['runStrategy']),
        running = asBool(j['running']),
        templateSpec = asMap(asMap(j['template'])?['spec']).let(VmiSpec.fromJson);
}

class VmStatus {
  final bool? created;
  final bool? ready;

  /// `Running`, `Stopped`, `Starting`, `Paused`, `Migrating`, …
  final String? printableStatus;
  final List<Condition>? conditions;

  VmStatus.fromJson(JsonMap j)
      : created = asBool(j['created']),
        ready = asBool(j['ready']),
        printableStatus = asString(j['printableStatus']),
        conditions = asListOrNull(j['conditions'], Condition.fromJson);
}

class VmiSpec {
  final Domain? domain;
  final List<VmNetwork>? networks;
  final List<VmVolume>? volumes;

  VmiSpec.fromJson(JsonMap j)
      : domain = asMap(j['domain']).let(Domain.fromJson),
        networks = asListOrNull(j['networks'], VmNetwork.fromJson),
        volumes = asListOrNull(j['volumes'], VmVolume.fromJson);
}

class Domain {
  final Cpu? cpu;
  final VmMemory? memory;
  final Devices? devices;

  /// `q35`, or `pc` on something old.
  final String? machineType;

  Domain.fromJson(JsonMap j)
      : cpu = asMap(j['cpu']).let(Cpu.fromJson),
        memory = asMap(j['memory']).let(VmMemory.fromJson),
        devices = asMap(j['devices']).let(Devices.fromJson),
        machineType = asString(asMap(j['machine'])?['type']);
}

class Cpu {
  final int? cores;
  final int? sockets;
  final int? threads;

  /// `host-model`, `host-passthrough`, or a named model.
  final String? model;
  final bool? dedicatedCpuPlacement;

  Cpu.fromJson(JsonMap j)
      : cores = asInt(j['cores']),
        sockets = asInt(j['sockets']),
        threads = asInt(j['threads']),
        model = asString(j['model']),
        dedicatedCpuPlacement = asBool(j['dedicatedCpuPlacement']);
}

class VmMemory {
  final String? guest;

  /// The hotplug ceiling. [guest] is what the machine has now.
  final String? maxGuest;

  VmMemory.fromJson(JsonMap j)
      : guest = asString(j['guest']),
        maxGuest = asString(j['maxGuest']);
}

class Devices {
  final List<Gpu>? gpus;
  final List<VmInterface>? interfaces;
  final List<VmDisk>? disks;

  Devices.fromJson(JsonMap j)
      : gpus = asListOrNull(j['gpus'], Gpu.fromJson),
        interfaces = asListOrNull(j['interfaces'], VmInterface.fromJson),
        disks = asListOrNull(j['disks'], VmDisk.fromJson);
}

class VmDisk {
  final String name;
  final int? bootOrder;
  final String? _diskBus;
  final String? _cdromBus;
  final String? _lunBus;
  final bool _isCdrom;
  final bool _isLun;

  VmDisk.fromJson(JsonMap j)
      : name = j['name'] as String,
        bootOrder = asInt(j['bootOrder']),
        _diskBus = asString(asMap(j['disk'])?['bus']),
        _cdromBus = asString(asMap(j['cdrom'])?['bus']),
        _lunBus = asString(asMap(j['lun'])?['bus']),
        _isCdrom = j['cdrom'] != null,
        _isLun = j['lun'] != null;

  String get kind => _isCdrom ? 'cdrom' : _isLun ? 'lun' : 'disk';
  String? get bus => _diskBus ?? _cdromBus ?? _lunBus;
}

/// What a volume is backed by, which decides whether it outlives a stop.
class VmVolume {
  final String name;
  final String? containerDiskImage;
  final String? claimName;
  final String? dataVolumeName;
  final bool cloudInit;
  final String? emptyDiskCapacity;
  final bool hasEmptyDisk;
  final String? hostDiskPath;
  final String? hostDiskCapacity;
  final bool hasHostDisk;
  final bool ephemeral;
  final bool configMap;
  final bool secret;
  final bool serviceAccount;

  VmVolume.fromJson(JsonMap j)
      : name = j['name'] as String,
        containerDiskImage = asString(asMap(j['containerDisk'])?['image']),
        claimName = asString(asMap(j['persistentVolumeClaim'])?['claimName']),
        dataVolumeName = asString(asMap(j['dataVolume'])?['name']),
        cloudInit = j['cloudInitNoCloud'] != null || j['cloudInitConfigDrive'] != null,
        emptyDiskCapacity = asString(asMap(j['emptyDisk'])?['capacity']),
        hasEmptyDisk = j['emptyDisk'] != null,
        hostDiskPath = asString(asMap(j['hostDisk'])?['path']),
        hostDiskCapacity = asString(asMap(j['hostDisk'])?['capacity']),
        hasHostDisk = j['hostDisk'] != null,
        ephemeral = j['ephemeral'] != null,
        configMap = j['configMap'] != null,
        secret = j['secret'] != null,
        serviceAccount = j['serviceAccount'] != null;

  /// The backing, as a reader would say it.
  String get backing {
    if (containerDiskImage != null) return 'containerDisk $containerDiskImage';
    if (claimName != null) return 'PVC $claimName';
    if (dataVolumeName != null) return 'DataVolume $dataVolumeName';
    if (cloudInit) return 'cloud-init';
    if (emptyDiskCapacity != null) return 'emptyDisk $emptyDiskCapacity';
    if (hasHostDisk) {
      return 'hostDisk ${hostDiskPath ?? ''}${hostDiskCapacity == null ? '' : ' $hostDiskCapacity'}';
    }
    if (ephemeral) return 'ephemeral copy of a PVC';
    if (configMap) return 'configMap';
    if (secret) return 'secret';
    if (serviceAccount) return 'serviceAccount';
    return '—';
  }

  /// Whether what the machine writes here is gone when it stops.
  ///
  /// A `containerDisk` is an image: it boots the same every time and keeps
  /// nothing. That is fine for a throwaway and a surprise for anything else,
  /// and the manifest gives no other hint.
  bool get isEphemeral => containerDiskImage != null || hasEmptyDisk || ephemeral;
}

class Gpu {
  final String name;

  /// The extended resource the device is claimed through:
  /// `nvidia.com/GA104GL_RTX_A4000`.
  final String? deviceName;

  Gpu.fromJson(JsonMap j)
      : name = j['name'] as String,
        deviceName = asString(j['deviceName']);
}

/// How an interface reaches its network. Each is a key whose presence is the
/// whole of the message, `"bridge": {}`, so the kind is read off which key is
/// there.
enum InterfaceBinding {
  masquerade,
  bridge,
  sriov,
  passt,
  slirp,
  macvtap,
  plugin,
  unknown;

  /// As a reader would say it: `SR-IOV VF` for a virtual function, the key
  /// otherwise.
  String get described => this == sriov ? 'SR-IOV VF' : name;
}

class VmInterface {
  final String name;
  final String? macAddress;
  final InterfaceBinding binding;

  /// The plugin's name, when the binding is one.
  final String? plugin;

  VmInterface.fromJson(JsonMap j)
      : name = j['name'] as String,
        macAddress = asString(j['macAddress']),
        plugin = asString(asMap(j['binding'])?['name']),
        binding = j.containsKey('masquerade')
            ? InterfaceBinding.masquerade
            : j.containsKey('bridge')
                ? InterfaceBinding.bridge
                : j.containsKey('sriov')
                    ? InterfaceBinding.sriov
                    : j.containsKey('passt')
                        ? InterfaceBinding.passt
                        : j.containsKey('slirp')
                            ? InterfaceBinding.slirp
                            : j.containsKey('macvtap')
                                ? InterfaceBinding.macvtap
                                : asString(asMap(j['binding'])?['name']) != null
                                    ? InterfaceBinding.plugin
                                    : InterfaceBinding.unknown;

  String get describedBinding =>
      binding == InterfaceBinding.plugin ? (plugin ?? 'plugin') : binding.described;
}

class VmNetwork {
  final String name;
  final String? multusNetworkName;

  VmNetwork.fromJson(JsonMap j)
      : name = j['name'] as String,
        multusNetworkName = asString(asMap(j['multus'])?['networkName']);

  /// The network as a reader would name it: the attachment for a Multus
  /// network, "pod" for the cluster network.
  String get described => multusNetworkName ?? 'pod';
}

class VmiStatus {
  final String? phase;
  final String? nodeName;
  final List<InterfaceStatus>? interfaces;
  final List<Condition>? conditions;
  final String? guestOSPrettyName;
  final List<PhaseTransition>? phaseTransitionTimestamps;
  final MemoryStatus? memory;
  final Cpu? currentCPUTopology;
  final String? launcherContainerImageVersion;
  final String? migrationMethod;
  final List<VolumeStatus>? volumeStatus;
  final String? machineType;

  VmiStatus.fromJson(JsonMap j)
      : phase = asString(j['phase']),
        nodeName = asString(j['nodeName']),
        interfaces = asListOrNull(j['interfaces'], InterfaceStatus.fromJson),
        conditions = asListOrNull(j['conditions'], Condition.fromJson),
        guestOSPrettyName = asString(asMap(j['guestOSInfo'])?['prettyName']),
        phaseTransitionTimestamps =
            asListOrNull(j['phaseTransitionTimestamps'], PhaseTransition.fromJson),
        memory = asMap(j['memory']).let(MemoryStatus.fromJson),
        currentCPUTopology = asMap(j['currentCPUTopology']).let(Cpu.fromJson),
        launcherContainerImageVersion = asString(j['launcherContainerImageVersion']),
        migrationMethod = asString(j['migrationMethod']),
        volumeStatus = asListOrNull(j['volumeStatus'], VolumeStatus.fromJson),
        machineType = asString(asMap(j['machine'])?['type']);
}

class InterfaceStatus {
  final String? name;
  final String? ipAddress;
  final List<String>? ipAddresses;
  final String? mac;
  final String? linkState;
  final int? queueCount;
  final String? podInterfaceName;

  InterfaceStatus.fromJson(JsonMap j)
      : name = asString(j['name']),
        ipAddress = asString(j['ipAddress']),
        ipAddresses = asStrings(j['ipAddresses']),
        mac = asString(j['mac']),
        linkState = asString(j['linkState']),
        queueCount = asInt(j['queueCount']),
        podInterfaceName = asString(j['podInterfaceName']);
}

class PhaseTransition {
  final String? phase;
  final DateTime? phaseTransitionTimestamp;
  PhaseTransition.fromJson(JsonMap j)
      : phase = asString(j['phase']),
        phaseTransitionTimestamp = asDate(j['phaseTransitionTimestamp']);
}

class MemoryStatus {
  final String? guestAtBoot;
  final String? guestCurrent;
  final String? guestRequested;
  MemoryStatus.fromJson(JsonMap j)
      : guestAtBoot = asString(j['guestAtBoot']),
        guestCurrent = asString(j['guestCurrent']),
        guestRequested = asString(j['guestRequested']);
}

class VolumeStatus {
  final String? name;
  final int? size;

  /// The device the guest sees it as: `vda`.
  final String? target;
  VolumeStatus.fromJson(JsonMap j)
      : name = asString(j['name']),
        size = asInt(j['size']),
        target = asString(j['target']);
}

/// A disk as the row shows it: the device, what backs it, whether it
/// survives a stop.
class DiskSummary {
  final String name;
  final String? target;
  final String kind;
  final String? bus;
  final String backing;
  final bool isEphemeral;
  final int? bytes;
  final int? bootOrder;

  const DiskSummary(
      {required this.name,
      required this.target,
      required this.kind,
      required this.bus,
      required this.backing,
      required this.isEphemeral,
      required this.bytes,
      required this.bootOrder});

  String get id => name;
}

/// An interface as the row shows it: the binding it uses, the network it
/// reaches, and what the running machine reports on it.
class InterfaceSummary {
  final String name;
  final InterfaceBinding binding;
  final String describedBinding;
  final String network;
  final String? mac;
  final String? linkState;
  final List<String> addresses;

  /// What the attachment definition says the network is, when one was found
  /// for it.
  final NetworkAttachment? attachment;

  /// The device the launcher pod was handed, when the CNI reported one: a
  /// VF's PCI address.
  final PodDevice? device;

  const InterfaceSummary(
      {required this.name,
      required this.binding,
      required this.describedBinding,
      required this.network,
      required this.mac,
      required this.linkState,
      required this.addresses,
      required this.attachment,
      required this.device});

  String get id => name;

  /// The facts past the MAC, in the order they are asked for. For a VF: the
  /// resource it was claimed as, its PCI address, the PF it was cut from,
  /// VLAN and MTU. For a bridge: the bridge, and the VLAN and MTU when set.
  List<String> get details {
    final out = <String>[];
    final resource = attachment?.resourceName;
    if (resource != null) out.add(resource);
    final pci = device?.pciAddress;
    if (pci != null) out.add('PCI $pci');
    final pf = device?.pfAddress;
    if (pf != null) out.add('PF $pf');
    final bridge = attachment?.bridge;
    if (bridge != null) out.add('br $bridge');
    final vlan = attachment?.vlan;
    if (vlan != null && vlan != 0) out.add('VLAN $vlan');
    final mtu = attachment?.mtu;
    if (mtu != null) out.add('MTU $mtu');
    final type = attachment?.type;
    if (type != null && resource == null && bridge == null) out.add(type);
    return out;
  }
}

/// One running machine.
class VirtualMachineInstance {
  final ObjectMeta metadata;
  final VmiSpec? spec;
  final VmiStatus? status;

  VirtualMachineInstance.fromJson(JsonMap j)
      : metadata = ObjectMeta.fromJson(mapOrEmpty(j['metadata'])),
        spec = asMap(j['spec']).let(VmiSpec.fromJson),
        status = asMap(j['status']).let(VmiStatus.fromJson);

  String get id => '${metadata.namespace ?? ''}/${metadata.name}';

  String get phase => status?.phase ?? 'Unknown';
  bool get isRunning => phase == 'Running';
  String get node => status?.nodeName ?? '—';

  String? get cpuModel => spec?.domain?.cpu?.model;
  String? get machineType => status?.machineType ?? spec?.domain?.machineType;

  /// What the guest has, and the ceiling if there is one above it:
  /// `4Gi of 16Gi`. Current beats declared, because memory hotplugs.
  String? get memory {
    final now = status?.memory?.guestCurrent ?? spec?.domain?.memory?.guest;
    if (now == null) return null;
    final max = spec?.domain?.memory?.maxGuest;
    if (max != null && max != now) return '$now of $max';
    return now;
  }

  /// When the machine last entered `Running`.
  DateTime? get runningSince => (status?.phaseTransitionTimestamps ?? const [])
      .where((t) => t.phase == 'Running')
      .lastOrNull
      ?.phaseTransitionTimestamp;

  /// Whether it can leave the node without stopping. `null` when the cluster
  /// has not said: a machine that is not running has no answer.
  bool? get isLiveMigratable => status?.conditions
      ?.where((c) => c.type == 'LiveMigratable')
      .firstOrNull
      .let((c) => c.status == 'True');

  String? get launcherVersion => status?.launcherContainerImageVersion;

  /// The disks in the order the device list gives them, each joined to its
  /// volume by name and to the guest's device name when the machine is
  /// running.
  static List<DiskSummary> disksOf(VmiSpec? spec, VmiStatus? status) {
    final volumes = <String, VmVolume>{};
    for (final v in spec?.volumes ?? const <VmVolume>[]) {
      volumes.putIfAbsent(v.name, () => v);
    }
    final seen = <String, VolumeStatus>{};
    for (final v in status?.volumeStatus ?? const <VolumeStatus>[]) {
      final n = v.name;
      if (n != null) seen.putIfAbsent(n, () => v);
    }
    return [
      for (final disk in spec?.domain?.devices?.disks ?? const <VmDisk>[])
        DiskSummary(
          name: disk.name,
          target: seen[disk.name]?.target,
          kind: disk.kind,
          bus: disk.bus,
          backing: volumes[disk.name]?.backing ?? '—',
          isEphemeral: volumes[disk.name]?.isEphemeral ?? false,
          bytes: seen[disk.name]?.size,
          bootOrder: disk.bootOrder,
        )
    ];
  }

  List<DiskSummary> get disks => disksOf(spec, status);

  /// The disk the machine boots from: the lowest `bootOrder`, or the first
  /// disk when nothing says.
  static DiskSummary? bootDisk(List<DiskSummary> disks) {
    DiskSummary? best;
    for (final d in disks) {
      final order = d.bootOrder;
      if (order == null) continue;
      if (best == null || order < best.bootOrder!) best = d;
    }
    return best ?? disks.firstOrNull;
  }

  static List<InterfaceSummary> interfacesOf(VmiSpec? spec, VmiStatus? status,
      {String namespace = 'default',
      List<NetworkAttachment> attachments = const [],
      List<PodNetwork> podNetworks = const []}) {
    final networks = <String, VmNetwork>{};
    for (final n in spec?.networks ?? const <VmNetwork>[]) {
      networks.putIfAbsent(n.name, () => n);
    }
    final reported = <String, InterfaceStatus>{};
    for (final i in status?.interfaces ?? const <InterfaceStatus>[]) {
      final n = i.name;
      if (n != null) reported.putIfAbsent(n, () => i);
    }
    return [
      for (final iface in spec?.domain?.devices?.interfaces ?? const <VmInterface>[])
        () {
          final live = reported[iface.name];
          final addresses = live?.ipAddresses ??
              (live?.ipAddress == null ? const <String>[] : [live!.ipAddress!]);
          final network = networks[iface.name];
          // Multus names an attachment `name` for the machine's own
          // namespace and `namespace/name` for another's.
          final ref = network?.multusNetworkName;
          final qualified =
              ref == null ? null : (ref.contains('/') ? ref : '$namespace/$ref');
          final attachment = qualified == null
              ? null
              : attachments.where((a) => a.id == qualified).firstOrNull;
          // The CNI reports on the pod's side of the interface, so the pod
          // interface name is the join; the attachment name is the fallback
          // for a runtime that did not fill it in.
          final pod = podNetworks
                  .where((p) =>
                      p.interface != null && p.interface == live?.podInterfaceName)
                  .firstOrNull ??
              (qualified == null
                  ? null
                  : podNetworks.where((p) => p.name == qualified).firstOrNull);
          return InterfaceSummary(
            name: iface.name,
            binding: iface.binding,
            describedBinding: iface.describedBinding,
            network: network?.described ?? '—',
            mac: live?.mac ?? iface.macAddress,
            linkState: live?.linkState,
            addresses: addresses.where((a) => a.isNotEmpty).toList(),
            attachment: attachment,
            device: pod?.device,
          );
        }()
    ];
  }

  List<InterfaceSummary> get interfaces => interfacesOf(spec, status);

  /// Every address the machine actually has, in interface order.
  ///
  /// Not just the first. A tenant VM here has two, the pod network and the
  /// interface that carries its tenancy, and the second is the one worth
  /// reading.
  List<({String interface, String ip})> get addresses => [
        for (final iface in status?.interfaces ?? const <InterfaceStatus>[])
          if (iface.ipAddress case final ip? when ip.isNotEmpty)
            (interface: iface.name ?? '—', ip: ip)
      ];

  List<Gpu> get gpus => spec?.domain?.devices?.gpus ?? const [];

  /// `2 vCPU · 4Gi`, or as much of it as the spec states.
  String get size {
    final cpu = spec?.domain?.cpu;
    final cores = (cpu?.cores ?? 1) * (cpu?.sockets ?? 1) * (cpu?.threads ?? 1);
    return [
      if (cores > 0) '$cores vCPU',
      if (spec?.domain?.memory?.guest case final guest?) guest,
    ].join(' · ');
  }
}

/// A machine as the UI shows it: the declaration and the instance together,
/// either of which may be missing.
class Machine {
  final String namespace;
  final String name;
  final VirtualMachine? vm;
  final VirtualMachineInstance? vmi;

  /// The attachment definitions this machine's networks name.
  final List<NetworkAttachment> attachments;

  /// What the CNI told the launcher pod about each of its interfaces.
  final List<PodNetwork> podNetworks;

  const Machine(
      {required this.namespace,
      required this.name,
      this.vm,
      this.vmi,
      this.attachments = const [],
      this.podNetworks = const []});

  String get id => '$namespace/$name';

  /// Whether there is a [VirtualMachine] to act on. Without one the lifecycle
  /// verbs have nothing to address: the API returns 404, not a stopped
  /// machine.
  bool get isManageable => vm != null;

  /// One word for the row. The instance is believed over the declaration
  /// when both are present: `printableStatus` lags a machine that has just
  /// crashed, and `Failed` is the thing worth seeing.
  String get state {
    final instance = vmi;
    if (instance != null && instance.phase != 'Succeeded') return instance.phase;
    return vm?.state ?? 'Stopped';
  }

  /// Whether an instance is up right now. Drives the status dot, where "is
  /// it serving" is the question being asked.
  bool get isRunning => vmi?.isRunning ?? false;

  /// Whether the declaration asks for this machine to be up, which is the
  /// state the lifecycle verbs act on, and not the same question.
  ///
  /// The two disagree exactly where it matters. A machine declared running
  /// whose VMI cannot be placed sits at `Scheduling` with nothing running;
  /// `Start` is rejected there and `Stop` is what is wanted. A standalone VMI
  /// has no declaration at all, so it falls back to the instance.
  bool get isDeclaredRunning => vm?.isRunning ?? (vmi != null);

  String? get node => vmi?.node;

  List<Gpu> get gpus =>
      vmi?.gpus ?? vm?.spec?.templateSpec?.domain?.devices?.gpus ?? const [];

  List<({String interface, String ip})> get addresses => vmi?.addresses ?? const [];

  String get size => vmi?.size ?? '—';

  List<VmNetwork> get networks =>
      vmi?.spec?.networks ?? vm?.spec?.templateSpec?.networks ?? const [];

  /// The instance's spec when there is one, the declaration's template when
  /// there is not: a stopped machine still has disks and NICs.
  VmiSpec? get _spec => vmi?.spec ?? vm?.spec?.templateSpec;

  String? get cpuModel => _spec?.domain?.cpu?.model;
  String? get machineType => vmi?.machineType ?? _spec?.domain?.machineType;
  String? get memory => vmi?.memory ?? _spec?.domain?.memory?.guest;
  DateTime? get runningSince => vmi?.runningSince;
  bool? get isLiveMigratable => vmi?.isLiveMigratable;

  List<DiskSummary> get disks =>
      VirtualMachineInstance.disksOf(_spec, vmi?.status);

  List<InterfaceSummary> get interfaces => VirtualMachineInstance.interfacesOf(
      _spec, vmi?.status,
      namespace: namespace, attachments: attachments, podNetworks: podNetworks);

  /// Whether a stop throws the root filesystem away.
  bool get bootsFromEphemeralDisk =>
      VirtualMachineInstance.bootDisk(disks)?.isEphemeral == true;
}

/// A Multus NetworkAttachmentDefinition, reduced to what a machine's row
/// wants to know about the network it is attached to.
///
/// The definition's `spec.config` is a CNI config as a JSON *string*, and a
/// conflist wraps the real plugin in `plugins[0]`. What is worth reading out
/// of it: the plugin type, the bridge for a bridge plugin, VLAN and MTU where
/// set. The one fact that is not in the config is the most important for a
/// VF: the extended resource the VF is claimed as lives in an annotation on
/// the definition, `k8s.v1.cni.cncf.io/resourceName`.
class NetworkAttachment {
  final String namespace;
  final String name;
  final String? type;
  final String? resourceName;
  final String? bridge;
  final int? vlan;
  final int? mtu;

  const NetworkAttachment(
      {required this.namespace,
      required this.name,
      this.type,
      this.resourceName,
      this.bridge,
      this.vlan,
      this.mtu});

  String get id => '$namespace/$name';

  /// From the object as the apiserver serves it.
  factory NetworkAttachment.fromJson(JsonMap j) {
    final metadata = ObjectMeta.fromJson(mapOrEmpty(j['metadata']));
    var plugin = <String, dynamic>{};
    final text = asString(asMap(j['spec'])?['config']);
    if (text != null) {
      try {
        final decoded = jsonDecode(text);
        if (decoded is Map) {
          final json = Map<String, dynamic>.from(decoded);
          final plugins = asList(json['plugins'], (m) => m);
          plugin = plugins.firstOrNull ?? json;
        }
      } on FormatException {
        // A config that is not JSON says nothing.
      }
    }
    return NetworkAttachment(
      namespace: metadata.namespace ?? 'default',
      name: metadata.name,
      resourceName: metadata.annotations?['k8s.v1.cni.cncf.io/resourceName'],
      type: asString(plugin['type']),
      bridge: asString(plugin['bridge']),
      vlan: asInt(plugin['vlan']),
      mtu: asInt(plugin['mtu']),
    );
  }
}

class PodDevice {
  final String? type;
  final String? pciAddress;
  final String? pfAddress;

  PodDevice.fromJson(JsonMap j)
      : type = asString(j['type']),
        pciAddress = asString(asMap(j['pci'])?['pci-address']),
        pfAddress = asString(asMap(j['pci'])?['pf-pci-address']);
}

/// One entry of a launcher pod's `k8s.v1.cni.cncf.io/network-status`
/// annotation: what the CNI actually gave the pod on one interface.
///
/// This is where a VF's PCI address is. The machine's own status says the
/// interface exists and is up; only the CNI knows which function on which
/// card it is, and it says so in `device-info` on the pod, not on the VMI.
class PodNetwork {
  static const annotation = 'k8s.v1.cni.cncf.io/network-status';

  /// `namespace/attachment`, or the cluster network's own name.
  final String name;

  /// The pod-side interface: `net1`, `pod822b33ad87c`, `eth0`.
  final String? interface;
  final List<String>? ips;
  final String? mac;
  final PodDevice? device;

  PodNetwork.fromJson(JsonMap j)
      : name = j['name'] as String,
        interface = asString(j['interface']),
        ips = asStrings(j['ips']),
        mac = asString(j['mac']),
        device = asMap(j['device-info']).let(PodDevice.fromJson);

  /// The annotation's value, parsed. Absent or malformed reads as empty: a
  /// pod on the cluster network alone has nothing to say here.
  static List<PodNetwork> parse(String? text) {
    if (text == null) return const [];
    try {
      return asList(jsonDecode(text), PodNetwork.fromJson);
    } catch (_) {
      return const [];
    }
  }
}

extension KubeVirtApi on KubeClient {
  /// Whether KubeVirt is installed, and at which version of its API.
  ///
  /// Presence of the group is the test. The `KubeVirt` custom resource that
  /// configures the operator would be a stronger one, but reading it needs a
  /// namespace that varies by install, and the group is served either way.
  String? kubeVirtVersion(Map<String, String> groups) => groups[KubeVirt.group];

  Future<List<VirtualMachine>> virtualMachines(String groupVersion) => getJson(
      '/apis/$groupVersion/virtualmachines',
      (j) => listItems(j, VirtualMachine.fromJson));

  Future<List<VirtualMachineInstance>> virtualMachineInstances(String groupVersion) =>
      getJson('/apis/$groupVersion/virtualmachineinstances',
          (j) => listItems(j, VirtualMachineInstance.fromJson));

  /// Every Multus attachment definition on the cluster. Empty, not an error,
  /// on a cluster without Multus: the group is simply not served there.
  Future<List<NetworkAttachment>> networkAttachments() => getJson(
      '/apis/k8s.cni.cncf.io/v1/network-attachment-definitions',
      (j) => listItems(j, NetworkAttachment.fromJson));

  /// What the CNI reported to each launcher pod, keyed by the machine's
  /// `namespace/name`.
  ///
  /// The launcher is the pod that *is* the machine, and it carries the
  /// machine's name in its `kubevirt.io/domain` annotation; the VMI's own
  /// `status.activePods` maps UIDs to nodes and never names the pod.
  Future<Map<String, List<PodNetwork>>> launcherNetworks() async {
    final out = <String, List<PodNetwork>>{};
    for (final pod in await pods(labelSelector: 'kubevirt.io=virt-launcher')) {
      final domain = pod.metadata.annotations?['kubevirt.io/domain'];
      if (domain == null) continue;
      final key = '${pod.metadata.namespace ?? 'default'}/$domain';
      out[key] = PodNetwork.parse(pod.metadata.annotations?[PodNetwork.annotation]);
    }
    return out;
  }

  /// Both kinds, paired by name, with what their networks are attached to.
  ///
  /// Paired on namespace and name rather than on the instance's owner
  /// reference: a VMI created by hand has no owner, and dropping the unowned
  /// ones would hide exactly the machines that most need looking at.
  ///
  /// The attachment definitions and the launcher pods are read alongside,
  /// and either failing costs the detail, not the list: a cluster without
  /// Multus has no definitions to read and still has machines.
  Future<List<Machine>> machines(String groupVersion) async {
    final vmsTask = virtualMachines(groupVersion);
    final vmisTask = virtualMachineInstances(groupVersion);
    final attachmentsTask =
        networkAttachments().catchError((_) => <NetworkAttachment>[]);
    final launchersTask =
        launcherNetworks().catchError((_) => <String, List<PodNetwork>>{});
    final vms = await vmsTask;
    final vmis = await vmisTask;
    final attachments = await attachmentsTask;
    final launchers = await launchersTask;

    final byId = <String, ({VirtualMachine? vm, VirtualMachineInstance? vmi})>{};
    for (final vm in vms) {
      byId[vm.id] = (vm: vm, vmi: null);
    }
    for (final vmi in vmis) {
      byId[vmi.id] = (vm: byId[vmi.id]?.vm, vmi: vmi);
    }

    final out = <Machine>[];
    for (final e in byId.entries) {
      final pair = e.value;
      final namespace =
          pair.vmi?.metadata.namespace ?? pair.vm?.metadata.namespace ?? 'default';
      final name = pair.vmi?.metadata.name ?? pair.vm?.metadata.name ?? e.key;
      // Only the definitions this machine names, resolved the way Multus
      // resolves them: bare names are in the machine's namespace.
      final networks =
          pair.vmi?.spec?.networks ?? pair.vm?.spec?.templateSpec?.networks ?? const [];
      final wanted = {
        for (final n in networks)
          if (n.multusNetworkName case final ref?)
            ref.contains('/') ? ref : '$namespace/$ref'
      };
      out.add(Machine(
        namespace: namespace,
        name: name,
        vm: pair.vm,
        vmi: pair.vmi,
        attachments: attachments.where((a) => wanted.contains(a.id)).toList(),
        podNetworks: launchers[e.key] ?? const [],
      ));
    }
    out.sort((a, b) {
      final ns = a.namespace.compareTo(b.namespace);
      return ns != 0 ? ns : a.name.compareTo(b.name);
    });
    return out;
  }

  /// Start, stop or restart a [VirtualMachine].
  ///
  /// PUT to the subresource API, not a patch of the object. Editing
  /// `spec.running` gets a machine started and stopped too, but it skips
  /// virt-controller's own handling, and `restart` has no field at all, so
  /// half the verbs would have to work a different way. An empty JSON body is
  /// required: the endpoint rejects a request with no body.
  Future<List<int>> perform(VmAction action, Machine machine,
      {required String groupVersion}) {
    if (!machine.isManageable) {
      throw KubeFailure.unusable(
          '${machine.name} is a VirtualMachineInstance with no VirtualMachine behind it, '
          'so there is no run state to change. Re-apply it to start it again.');
    }
    // The subresource group is versioned independently of kubevirt.io, but
    // it has tracked it since v1 and deriving one from the other keeps a
    // second discovery call out of the path.
    final version = groupVersion.split('/').last;
    return send(
      'PUT',
      '/apis/${KubeVirt.subresourceGroup}/$version'
      '/namespaces/${machine.namespace}/virtualmachines/${machine.name}/${action.name}',
      body: utf8.encode('{}'),
      contentType: 'application/json',
    );
  }
}
