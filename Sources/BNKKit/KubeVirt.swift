import Foundation

/// KubeVirt — virtual machines as Kubernetes objects.
///
/// Two kinds, and the difference decides what can be done to them. A
/// `VirtualMachine` is the durable declaration: it has a run state, so it can be
/// started, stopped and restarted, and it survives its own instance. A
/// `VirtualMachineInstance` is one running machine. Usually a VMI belongs to a
/// VM — but not always. A VMI applied on its own is legal and is what a hand-
/// written lab manifest produces; it runs perfectly and there is nothing to
/// start or stop, because the object that would hold that state does not exist.
/// It also does not come back after the node reboots. Anything acting on these
/// has to tell the two apart rather than assume the pairing.
public enum KubeVirt {

    public static let group = "kubevirt.io"
    /// Lifecycle verbs live in their own group, served by the virt-api
    /// aggregated apiserver rather than by the CRD.
    public static let subresourceGroup = "subresources.kubevirt.io"

    /// A machine's declared run state.
    public struct VirtualMachine: Decodable, Sendable, Identifiable {
        public let metadata: K8s.ObjectMeta
        public let spec: Spec?
        public let status: Status?

        public var id: String { "\(metadata.namespace ?? "")/\(metadata.name)" }

        public struct Spec: Decodable, Sendable {
            /// `Always`, `Halted`, `Manual`, `RerunOnFailure`.
            public let runStrategy: String?
            /// The older spelling. Still what most manifests carry.
            public let running: Bool?
            public let template: Template?
        }
        public struct Template: Decodable, Sendable {
            public let spec: VirtualMachineInstance.Spec?
        }
        public struct Status: Decodable, Sendable {
            public let created: Bool?
            public let ready: Bool?
            /// `Running`, `Stopped`, `Starting`, `Paused`, `Migrating`, …
            public let printableStatus: String?
            public let conditions: [K8s.Condition]?
        }

        public var isRunning: Bool {
            if let running = spec?.running { return running }
            return (spec?.runStrategy ?? "") != "Halted"
        }

        public var state: String { status?.printableStatus ?? (isRunning ? "Starting" : "Stopped") }
    }

    /// One running machine.
    public struct VirtualMachineInstance: Decodable, Sendable, Identifiable {
        public let metadata: K8s.ObjectMeta
        public let spec: Spec?
        public let status: Status?

        public var id: String { "\(metadata.namespace ?? "")/\(metadata.name)" }

        public struct Spec: Decodable, Sendable {
            public let domain: Domain?
            public let networks: [Network]?
            public let volumes: [Volume]?
        }
        public struct Domain: Decodable, Sendable {
            public let cpu: CPU?
            public let memory: Memory?
            public let devices: Devices?
            public let machine: Machine?
        }
        public struct Machine: Decodable, Sendable {
            /// `q35`, or `pc` on something old.
            public let type: String?
        }
        public struct CPU: Decodable, Sendable {
            public let cores: Int?
            public let sockets: Int?
            public let threads: Int?
            /// `host-model`, `host-passthrough`, or a named model.
            public let model: String?
            public let dedicatedCpuPlacement: Bool?
        }
        public struct Memory: Decodable, Sendable {
            public let guest: String?
            /// The hotplug ceiling. `guest` is what the machine has now.
            public let maxGuest: String?
        }
        public struct Devices: Decodable, Sendable {
            public let gpus: [GPU]?
            public let interfaces: [Interface]?
            public let disks: [Disk]?
        }
        public struct Disk: Decodable, Sendable {
            public let name: String
            public let bootOrder: Int?
            public let disk: Target?
            public let cdrom: Target?
            public let lun: Target?

            public struct Target: Decodable, Sendable {
                public let bus: String?
            }

            public var kind: String { cdrom != nil ? "cdrom" : lun != nil ? "lun" : "disk" }
            public var bus: String? { (disk ?? cdrom ?? lun)?.bus }
        }

        /// What a volume is backed by, which decides whether it outlives a stop.
        public struct Volume: Decodable, Sendable {
            public let name: String
            public let containerDisk: ContainerDisk?
            public let persistentVolumeClaim: Claim?
            public let dataVolume: Named?
            public let cloudInitNoCloud: Presence?
            public let cloudInitConfigDrive: Presence?
            public let emptyDisk: Sized?
            public let hostDisk: HostDisk?
            public let ephemeral: Presence?
            public let configMap: Presence?
            public let secret: Presence?
            public let serviceAccount: Presence?

            public struct ContainerDisk: Decodable, Sendable { public let image: String? }
            public struct Claim: Decodable, Sendable { public let claimName: String? }
            public struct Named: Decodable, Sendable { public let name: String? }
            public struct Sized: Decodable, Sendable { public let capacity: String? }
            public struct HostDisk: Decodable, Sendable {
                public let path: String?
                public let capacity: String?
            }
            /// The key is there; what is under it does not matter here.
            public struct Presence: Decodable, Sendable {
                public init(from decoder: Decoder) throws {}
            }

            /// The backing, as a reader would say it.
            public var backing: String {
                if let image = containerDisk?.image { return "containerDisk \(image)" }
                if let claim = persistentVolumeClaim?.claimName { return "PVC \(claim)" }
                if let dv = dataVolume?.name { return "DataVolume \(dv)" }
                if cloudInitNoCloud != nil || cloudInitConfigDrive != nil { return "cloud-init" }
                if let capacity = emptyDisk?.capacity { return "emptyDisk \(capacity)" }
                if let host = hostDisk { return "hostDisk \(host.path ?? "")\(host.capacity.map { " \($0)" } ?? "")" }
                if ephemeral != nil { return "ephemeral copy of a PVC" }
                if configMap != nil { return "configMap" }
                if secret != nil { return "secret" }
                if serviceAccount != nil { return "serviceAccount" }
                return "—"
            }

            /// Whether what the machine writes here is gone when it stops.
            ///
            /// A `containerDisk` is an image: it boots the same every time and
            /// keeps nothing. That is fine for a throwaway and a surprise for
            /// anything else, and the manifest gives no other hint.
            public var isEphemeral: Bool {
                containerDisk != nil || emptyDisk != nil || ephemeral != nil
            }
        }
        public struct GPU: Decodable, Sendable {
            public let name: String
            /// The extended resource the device is claimed through —
            /// `nvidia.com/GA104GL_RTX_A4000`.
            public let deviceName: String?
        }
        public struct Interface: Decodable, Sendable {
            public let name: String
            public let macAddress: String?
            public let binding: Binding
            /// The plugin's name, when the binding is one.
            public let plugin: String?

            /// How the interface reaches its network. Each is a key whose
            /// presence is the whole of the message — `"bridge": {}` — so the
            /// kind is read off which key is there.
            public enum Binding: String, Sendable {
                case masquerade, bridge, sriov, passt, slirp, macvtap, plugin, unknown

                /// As a reader would say it: `SR-IOV VF` for a virtual function,
                /// the plugin's name for a plugin, the key otherwise.
                public var described: String { self == .sriov ? "SR-IOV VF" : rawValue }
            }

            private enum Keys: String, CodingKey {
                case name, macAddress, masquerade, bridge, sriov, passt, slirp, macvtap, binding
            }
            private struct Plugin: Decodable { let name: String? }

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: Keys.self)
                name = try c.decode(String.self, forKey: .name)
                macAddress = try c.decodeIfPresent(String.self, forKey: .macAddress)
                let named = try c.decodeIfPresent(Plugin.self, forKey: .binding)?.name
                plugin = named
                binding = c.contains(.masquerade) ? .masquerade
                        : c.contains(.bridge) ? .bridge
                        : c.contains(.sriov) ? .sriov
                        : c.contains(.passt) ? .passt
                        : c.contains(.slirp) ? .slirp
                        : c.contains(.macvtap) ? .macvtap
                        : named != nil ? .plugin
                        : .unknown
            }

            public var describedBinding: String { binding == .plugin ? (plugin ?? "plugin") : binding.described }
        }
        public struct Network: Decodable, Sendable {
            public let name: String
            public let multus: Multus?

            public struct Multus: Decodable, Sendable {
                public let networkName: String?
            }

            /// The network as a reader would name it: the attachment for a
            /// Multus network, "pod" for the cluster network.
            public var described: String { multus?.networkName ?? "pod" }
        }

        public struct Status: Decodable, Sendable {
            public let phase: String?
            public let nodeName: String?
            public let interfaces: [InterfaceStatus]?
            public let conditions: [K8s.Condition]?
            public let guestOSInfo: GuestOS?
            public let phaseTransitionTimestamps: [PhaseTransition]?
            public let memory: MemoryStatus?
            public let currentCPUTopology: CPU?
            public let launcherContainerImageVersion: String?
            public let migrationMethod: String?
            public let volumeStatus: [VolumeStatus]?
            public let machine: Machine?
        }
        public struct InterfaceStatus: Decodable, Sendable {
            public let name: String?
            public let ipAddress: String?
            public let ipAddresses: [String]?
            public let mac: String?
            public let linkState: String?
            public let queueCount: Int?
            public let podInterfaceName: String?
        }
        public struct GuestOS: Decodable, Sendable {
            public let prettyName: String?
        }
        public struct PhaseTransition: Decodable, Sendable {
            public let phase: String?
            public let phaseTransitionTimestamp: Date?
        }
        public struct MemoryStatus: Decodable, Sendable {
            public let guestAtBoot: String?
            public let guestCurrent: String?
            public let guestRequested: String?
        }
        public struct VolumeStatus: Decodable, Sendable {
            public let name: String?
            public let size: Int64?
            /// The device the guest sees it as: `vda`.
            public let target: String?
        }

        public var phase: String { status?.phase ?? "Unknown" }
        public var isRunning: Bool { phase == "Running" }
        public var node: String { status?.nodeName ?? "—" }

        public var cpuModel: String? { spec?.domain?.cpu?.model }
        public var machineType: String? { status?.machine?.type ?? spec?.domain?.machine?.type }

        /// What the guest has, and the ceiling if there is one above it:
        /// `4Gi of 16Gi`. Current beats declared, because memory hotplugs.
        public var memory: String? {
            guard let now = status?.memory?.guestCurrent ?? spec?.domain?.memory?.guest else { return nil }
            if let max = spec?.domain?.memory?.maxGuest, max != now { return "\(now) of \(max)" }
            return now
        }

        /// When the machine last entered `Running`.
        public var runningSince: Date? {
            status?.phaseTransitionTimestamps?.last { $0.phase == "Running" }?.phaseTransitionTimestamp
        }

        /// Whether it can leave the node without stopping. `nil` when the
        /// cluster has not said — a machine that is not running has no answer.
        public var isLiveMigratable: Bool? {
            status?.conditions?.first { $0.type == "LiveMigratable" }.map { $0.status == "True" }
        }

        public var launcherVersion: String? { status?.launcherContainerImageVersion }

        /// A disk as the row shows it: the device, what backs it, whether it
        /// survives a stop.
        public struct DiskSummary: Sendable, Identifiable {
            public let name: String
            public let target: String?
            public let kind: String
            public let bus: String?
            public let backing: String
            public let isEphemeral: Bool
            public let bytes: Int64?
            public let bootOrder: Int?
            public var id: String { name }
        }

        /// The disks in the order the device list gives them, each joined to
        /// its volume by name and to the guest's device name when the machine
        /// is running.
        public static func disks(spec: Spec?, status: Status?) -> [DiskSummary] {
            var volumes: [String: Volume] = [:]
            for v in spec?.volumes ?? [] where volumes[v.name] == nil { volumes[v.name] = v }
            var seen: [String: VolumeStatus] = [:]
            for v in status?.volumeStatus ?? [] { if let n = v.name, seen[n] == nil { seen[n] = v } }
            return (spec?.domain?.devices?.disks ?? []).map { disk in
                let volume = volumes[disk.name]
                return DiskSummary(name: disk.name, target: seen[disk.name]?.target, kind: disk.kind,
                                   bus: disk.bus, backing: volume?.backing ?? "—",
                                   isEphemeral: volume?.isEphemeral ?? false,
                                   bytes: seen[disk.name]?.size, bootOrder: disk.bootOrder)
            }
        }

        public var disks: [DiskSummary] { Self.disks(spec: spec, status: status) }

        /// The disk the machine boots from: the lowest `bootOrder`, or the
        /// first disk when nothing says.
        public static func bootDisk(_ disks: [DiskSummary]) -> DiskSummary? {
            disks.filter { $0.bootOrder != nil }.min { $0.bootOrder! < $1.bootOrder! } ?? disks.first
        }

        /// An interface as the row shows it: the binding it uses, the network
        /// it reaches, and what the running machine reports on it.
        public struct InterfaceSummary: Sendable, Identifiable {
            public let name: String
            public let binding: Interface.Binding
            public let describedBinding: String
            public let network: String
            public let mac: String?
            public let linkState: String?
            public let addresses: [String]
            /// What the attachment definition says the network is, when one
            /// was found for it.
            public let attachment: KubeVirt.NetworkAttachment?
            /// The device the launcher pod was handed, when the CNI reported
            /// one — a VF's PCI address.
            public let device: KubeVirt.PodNetwork.Device?
            public var id: String { name }

            /// The facts past the MAC, in the order they are asked for. For a
            /// VF: the resource it was claimed as, its PCI address, the PF it
            /// was cut from, VLAN and MTU. For a bridge: the bridge, and the
            /// VLAN and MTU when set.
            public var details: [String] {
                var out: [String] = []
                if let resource = attachment?.resourceName { out.append(resource) }
                if let pci = device?.pciAddress { out.append("PCI \(pci)") }
                if let pf = device?.pfAddress { out.append("PF \(pf)") }
                if let bridge = attachment?.bridge { out.append("br \(bridge)") }
                if let vlan = attachment?.vlan, vlan != 0 { out.append("VLAN \(vlan)") }
                if let mtu = attachment?.mtu { out.append("MTU \(mtu)") }
                if let type = attachment?.type, attachment?.resourceName == nil, attachment?.bridge == nil {
                    out.append(type)
                }
                return out
            }
        }

        public static func interfaces(spec: Spec?, status: Status?, namespace: String = "default",
                                      attachments: [KubeVirt.NetworkAttachment] = [],
                                      podNetworks: [KubeVirt.PodNetwork] = []) -> [InterfaceSummary] {
            var networks: [String: Network] = [:]
            for n in spec?.networks ?? [] where networks[n.name] == nil { networks[n.name] = n }
            var reported: [String: InterfaceStatus] = [:]
            for i in status?.interfaces ?? [] { if let n = i.name, reported[n] == nil { reported[n] = i } }
            return (spec?.domain?.devices?.interfaces ?? []).map { iface in
                let live = reported[iface.name]
                let addresses = live?.ipAddresses ?? live?.ipAddress.map { [$0] } ?? []
                let network = networks[iface.name]
                // Multus names an attachment `name` for the machine's own
                // namespace and `namespace/name` for another's.
                let qualified = network?.multus?.networkName.map { ref -> String in
                    ref.contains("/") ? ref : "\(namespace)/\(ref)"
                }
                let attachment = qualified.flatMap { q in attachments.first { $0.id == q } }
                // The CNI reports on the pod's side of the interface, so the
                // pod interface name is the join; the attachment name is the
                // fallback for a runtime that did not fill it in.
                let pod = podNetworks.first { $0.interface != nil && $0.interface == live?.podInterfaceName }
                    ?? qualified.flatMap { q in podNetworks.first { $0.name == q } }
                return InterfaceSummary(name: iface.name, binding: iface.binding,
                                        describedBinding: iface.describedBinding,
                                        network: network?.described ?? "—",
                                        mac: live?.mac ?? iface.macAddress, linkState: live?.linkState,
                                        addresses: addresses.filter { !$0.isEmpty },
                                        attachment: attachment, device: pod?.device)
            }
        }

        public var interfaces: [InterfaceSummary] { Self.interfaces(spec: spec, status: status) }

        /// Every address the machine actually has, in interface order.
        ///
        /// Not just the first. A tenant VM here has two — the pod network and
        /// the interface that carries its tenancy — and the second is the one
        /// worth reading.
        public var addresses: [(interface: String, ip: String)] {
            (status?.interfaces ?? []).compactMap { iface in
                guard let ip = iface.ipAddress, !ip.isEmpty else { return nil }
                return (interface: iface.name ?? "—", ip: ip)
            }
        }

        public var gpus: [GPU] { spec?.domain?.devices?.gpus ?? [] }

        /// `2 vCPU · 4Gi`, or as much of it as the spec states.
        public var size: String {
            let cpu = spec?.domain?.cpu
            let cores = (cpu?.cores ?? 1) * (cpu?.sockets ?? 1) * (cpu?.threads ?? 1)
            let parts = [cores > 0 ? "\(cores) vCPU" : nil, spec?.domain?.memory?.guest]
            return parts.compactMap { $0 }.joined(separator: " · ")
        }
    }

    /// A machine as the UI shows it: the declaration and the instance together,
    /// either of which may be missing.
    public struct Machine: Sendable, Identifiable {
        public let namespace: String
        public let name: String
        public let vm: VirtualMachine?
        public let vmi: VirtualMachineInstance?
        /// The attachment definitions this machine's networks name.
        public let attachments: [NetworkAttachment]
        /// What the CNI told the launcher pod about each of its interfaces.
        public let podNetworks: [PodNetwork]

        public init(namespace: String, name: String, vm: VirtualMachine?, vmi: VirtualMachineInstance?,
                    attachments: [NetworkAttachment] = [], podNetworks: [PodNetwork] = []) {
            self.namespace = namespace; self.name = name; self.vm = vm; self.vmi = vmi
            self.attachments = attachments; self.podNetworks = podNetworks
        }

        public var id: String { "\(namespace)/\(name)" }

        /// Whether there is a `VirtualMachine` to act on. Without one the
        /// lifecycle verbs have nothing to address — the API returns 404, not a
        /// stopped machine.
        public var isManageable: Bool { vm != nil }

        /// One word for the row. The instance is believed over the declaration
        /// when both are present: `printableStatus` lags a machine that has
        /// just crashed, and `Failed` is the thing worth seeing.
        public var state: String {
            if let vmi, vmi.phase != "Succeeded" { return vmi.phase }
            return vm?.state ?? "Stopped"
        }

        /// Whether an instance is up right now. Drives the status dot, where
        /// "is it serving" is the question being asked.
        public var isRunning: Bool { vmi?.isRunning ?? false }

        /// Whether the declaration asks for this machine to be up — which is
        /// the state the lifecycle verbs act on, and not the same question.
        ///
        /// The two disagree exactly where it matters. A machine declared
        /// running whose VMI cannot be placed sits at `Scheduling` with nothing
        /// running; `Start` is rejected there and `Stop` is what is wanted. A
        /// standalone VMI has no declaration at all, so it falls back to the
        /// instance — it is never offered a verb anyway, `isManageable` sees to
        /// that, but the answer should still describe the machine.
        public var isDeclaredRunning: Bool { vm?.isRunning ?? (vmi != nil) }

        public var node: String? { vmi?.node }
        public var gpus: [VirtualMachineInstance.GPU] {
            vmi?.gpus ?? vm?.spec?.template?.spec?.domain?.devices?.gpus ?? []
        }
        public var addresses: [(interface: String, ip: String)] { vmi?.addresses ?? [] }
        public var size: String { vmi?.size ?? "—" }
        public var networks: [VirtualMachineInstance.Network] {
            vmi?.spec?.networks ?? vm?.spec?.template?.spec?.networks ?? []
        }

        /// The instance's spec when there is one, the declaration's template
        /// when there is not — a stopped machine still has disks and NICs.
        private var spec: VirtualMachineInstance.Spec? { vmi?.spec ?? vm?.spec?.template?.spec }

        public var cpuModel: String? { spec?.domain?.cpu?.model }
        public var machineType: String? { vmi?.machineType ?? spec?.domain?.machine?.type }
        public var memory: String? { vmi?.memory ?? spec?.domain?.memory?.guest }
        public var runningSince: Date? { vmi?.runningSince }
        public var isLiveMigratable: Bool? { vmi?.isLiveMigratable }
        public var disks: [VirtualMachineInstance.DiskSummary] {
            VirtualMachineInstance.disks(spec: spec, status: vmi?.status)
        }
        public var interfaces: [VirtualMachineInstance.InterfaceSummary] {
            VirtualMachineInstance.interfaces(spec: spec, status: vmi?.status, namespace: namespace,
                                              attachments: attachments, podNetworks: podNetworks)
        }
        /// Whether a stop throws the root filesystem away.
        public var bootsFromEphemeralDisk: Bool {
            VirtualMachineInstance.bootDisk(disks)?.isEphemeral == true
        }
    }

    /// A Multus NetworkAttachmentDefinition, reduced to what a machine's row
    /// wants to know about the network it is attached to.
    ///
    /// The definition's `spec.config` is a CNI config as a JSON *string*, and
    /// a conflist wraps the real plugin in `plugins[0]`. What is worth reading
    /// out of it: the plugin type, the bridge for a bridge plugin, VLAN and
    /// MTU where set. The one fact that is not in the config is the most
    /// important for a VF — the extended resource the VF is claimed as lives
    /// in an annotation on the definition, `k8s.v1.cni.cncf.io/resourceName`.
    public struct NetworkAttachment: Sendable, Identifiable {
        public let namespace: String
        public let name: String
        public let type: String?
        public let resourceName: String?
        public let bridge: String?
        public let vlan: Int?
        public let mtu: Int?

        public var id: String { "\(namespace)/\(name)" }

        public init(namespace: String, name: String, type: String? = nil, resourceName: String? = nil,
                    bridge: String? = nil, vlan: Int? = nil, mtu: Int? = nil) {
            self.namespace = namespace; self.name = name; self.type = type
            self.resourceName = resourceName; self.bridge = bridge; self.vlan = vlan; self.mtu = mtu
        }

        /// As the apiserver serves it.
        public struct Object: Decodable, Sendable {
            public let metadata: K8s.ObjectMeta
            public let spec: Spec?
            public struct Spec: Decodable, Sendable { public let config: String? }
        }

        public init(_ object: Object) {
            namespace = object.metadata.namespace ?? "default"
            name = object.metadata.name
            resourceName = object.metadata.annotations?["k8s.v1.cni.cncf.io/resourceName"]
            var plugin: [String: Any] = [:]
            if let text = object.spec?.config, let data = text.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                plugin = (json["plugins"] as? [[String: Any]])?.first ?? json
            }
            type = plugin["type"] as? String
            bridge = plugin["bridge"] as? String
            vlan = plugin["vlan"] as? Int
            mtu = plugin["mtu"] as? Int
        }
    }

    /// One entry of a launcher pod's `k8s.v1.cni.cncf.io/network-status`
    /// annotation: what the CNI actually gave the pod on one interface.
    ///
    /// This is where a VF's PCI address is. The machine's own status says the
    /// interface exists and is up; only the CNI knows which function on which
    /// card it is, and it says so in `device-info` on the pod, not on the VMI.
    public struct PodNetwork: Decodable, Sendable {
        /// `namespace/attachment`, or the cluster network's own name.
        public let name: String
        /// The pod-side interface: `net1`, `pod822b33ad87c`, `eth0`.
        public let interface: String?
        public let ips: [String]?
        public let mac: String?
        public let device: Device?

        public struct Device: Decodable, Sendable {
            public let type: String?
            public let pciAddress: String?
            public let pfAddress: String?

            private enum Keys: String, CodingKey { case type, pci }
            private enum PCIKeys: String, CodingKey {
                case pciAddress = "pci-address", pfAddress = "pf-pci-address"
            }
            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: Keys.self)
                type = try c.decodeIfPresent(String.self, forKey: .type)
                if c.contains(.pci) {
                    let pci = try c.nestedContainer(keyedBy: PCIKeys.self, forKey: .pci)
                    pciAddress = try pci.decodeIfPresent(String.self, forKey: .pciAddress)
                    pfAddress = try pci.decodeIfPresent(String.self, forKey: .pfAddress)
                } else {
                    pciAddress = nil; pfAddress = nil
                }
            }
        }

        private enum Keys: String, CodingKey { case name, interface, ips, mac, device = "device-info" }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            name = try c.decode(String.self, forKey: .name)
            interface = try c.decodeIfPresent(String.self, forKey: .interface)
            ips = try c.decodeIfPresent([String].self, forKey: .ips)
            mac = try c.decodeIfPresent(String.self, forKey: .mac)
            device = try c.decodeIfPresent(Device.self, forKey: .device)
        }

        public static let annotation = "k8s.v1.cni.cncf.io/network-status"

        /// The annotation's value, parsed. Absent or malformed reads as empty
        /// — a pod on the cluster network alone has nothing to say here.
        public static func parse(_ text: String?) -> [PodNetwork] {
            guard let text, let data = text.data(using: .utf8) else { return [] }
            return (try? KubeClient.decoder.decode([PodNetwork].self, from: data)) ?? []
        }
    }

    /// What can be asked of a `VirtualMachine`.
    public enum Action: String, Sendable, CaseIterable {
        case start, stop, restart
    }
}

extension KubeClient {

    /// Whether KubeVirt is installed, and at which version of its API.
    ///
    /// Presence of the group is the test. The `KubeVirt` custom resource that
    /// configures the operator would be a stronger one, but reading it needs a
    /// namespace that varies by install — `kubevirt`, `kubevirt-hyperconverged`
    /// under HCO, whatever an operator chose — and the group is served either
    /// way.
    public func kubeVirtVersion(groups: [String: String]) -> String? { groups[KubeVirt.group] }

    public func virtualMachines(groupVersion: String) async throws -> [KubeVirt.VirtualMachine] {
        try await getJSON(K8s.List<KubeVirt.VirtualMachine>.self,
                          "/apis/\(groupVersion)/virtualmachines").items
    }

    public func virtualMachineInstances(groupVersion: String) async throws -> [KubeVirt.VirtualMachineInstance] {
        try await getJSON(K8s.List<KubeVirt.VirtualMachineInstance>.self,
                          "/apis/\(groupVersion)/virtualmachineinstances").items
    }

    /// Every Multus attachment definition on the cluster. Empty, not an error,
    /// on a cluster without Multus — the group is simply not served there.
    public func networkAttachments() async throws -> [KubeVirt.NetworkAttachment] {
        try await getJSON(K8s.List<KubeVirt.NetworkAttachment.Object>.self,
                          "/apis/k8s.cni.cncf.io/v1/network-attachment-definitions")
            .items.map(KubeVirt.NetworkAttachment.init)
    }

    /// What the CNI reported to each launcher pod, keyed by the machine's
    /// `namespace/name`.
    ///
    /// The launcher is the pod that *is* the machine, and it carries the
    /// machine's name in its `kubevirt.io/domain` annotation; the VMI's own
    /// `status.activePods` maps UIDs to nodes and never names the pod.
    public func launcherNetworks() async throws -> [String: [KubeVirt.PodNetwork]] {
        var out: [String: [KubeVirt.PodNetwork]] = [:]
        for pod in try await pods(labelSelector: "kubevirt.io=virt-launcher") {
            guard let domain = pod.metadata.annotations?["kubevirt.io/domain"] else { continue }
            let key = "\(pod.metadata.namespace ?? "default")/\(domain)"
            out[key] = KubeVirt.PodNetwork.parse(pod.metadata.annotations?[KubeVirt.PodNetwork.annotation])
        }
        return out
    }

    /// Both kinds, paired by name, with what their networks are attached to.
    ///
    /// Paired on namespace and name rather than on the instance's owner
    /// reference: a VMI created by hand has no owner, and dropping the unowned
    /// ones would hide exactly the machines that most need looking at.
    ///
    /// The attachment definitions and the launcher pods are read alongside,
    /// and either failing costs the detail, not the list — a cluster without
    /// Multus has no definitions to read and still has machines.
    public func machines(groupVersion: String) async throws -> [KubeVirt.Machine] {
        async let vmsTask = virtualMachines(groupVersion: groupVersion)
        async let vmisTask = virtualMachineInstances(groupVersion: groupVersion)
        async let attachmentsTask = (try? networkAttachments()) ?? []
        async let launchersTask = (try? launcherNetworks()) ?? [:]
        let (vms, vmis) = try await (vmsTask, vmisTask)
        let (attachments, launchers) = await (attachmentsTask, launchersTask)

        var byID: [String: (vm: KubeVirt.VirtualMachine?, vmi: KubeVirt.VirtualMachineInstance?)] = [:]
        for vm in vms { byID[vm.id] = (vm, nil) }
        for vmi in vmis { byID[vmi.id] = (byID[vmi.id]?.vm, vmi) }

        return byID.map { id, pair in
            let namespace = (pair.vmi?.metadata.namespace ?? pair.vm?.metadata.namespace) ?? "default"
            let name = (pair.vmi?.metadata.name ?? pair.vm?.metadata.name) ?? id
            // Only the definitions this machine names, resolved the way
            // Multus resolves them: bare names are in the machine's namespace.
            let networks = pair.vmi?.spec?.networks ?? pair.vm?.spec?.template?.spec?.networks ?? []
            let wanted = Set(networks.compactMap { $0.multus?.networkName }
                .map { $0.contains("/") ? $0 : "\(namespace)/\($0)" })
            return KubeVirt.Machine(namespace: namespace, name: name, vm: pair.vm, vmi: pair.vmi,
                                    attachments: attachments.filter { wanted.contains($0.id) },
                                    podNetworks: launchers[id] ?? [])
        }
        .sorted { ($0.namespace, $0.name) < ($1.namespace, $1.name) }
    }

    /// Start, stop or restart a `VirtualMachine`.
    ///
    /// PUT to the subresource API, not a patch of the object. Editing
    /// `spec.running` gets a machine started and stopped too, but it skips
    /// virt-controller's own handling — and `restart` has no field at all, so
    /// half the verbs would have to work a different way. An empty JSON body is
    /// required: the endpoint rejects a request with no body.
    @discardableResult
    public func perform(_ action: KubeVirt.Action, on machine: KubeVirt.Machine,
                        groupVersion: String) async throws -> Data {
        guard machine.isManageable else {
            throw Failure.unusable(
                "\(machine.name) is a VirtualMachineInstance with no VirtualMachine behind it, "
                + "so there is no run state to change. Re-apply it to start it again.")
        }
        // The subresource group is versioned independently of kubevirt.io, but
        // it has tracked it since v1 and deriving one from the other keeps a
        // second discovery call out of the path.
        let version = groupVersion.split(separator: "/").last.map(String.init) ?? "v1"
        return try await send("PUT",
                              "/apis/\(KubeVirt.subresourceGroup)/\(version)"
                              + "/namespaces/\(machine.namespace)/virtualmachines/\(machine.name)/\(action.rawValue)",
                              body: Data("{}".utf8),
                              contentType: "application/json")
    }
}
