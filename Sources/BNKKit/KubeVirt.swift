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
        }
        public struct Domain: Decodable, Sendable {
            public let cpu: CPU?
            public let memory: Memory?
            public let devices: Devices?
        }
        public struct CPU: Decodable, Sendable {
            public let cores: Int?
            public let sockets: Int?
            public let threads: Int?
        }
        public struct Memory: Decodable, Sendable {
            public let guest: String?
        }
        public struct Devices: Decodable, Sendable {
            public let gpus: [GPU]?
            public let interfaces: [Interface]?
        }
        public struct GPU: Decodable, Sendable {
            public let name: String
            /// The extended resource the device is claimed through —
            /// `nvidia.com/GA104GL_RTX_A4000`.
            public let deviceName: String?
        }
        public struct Interface: Decodable, Sendable {
            public let name: String
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
        }
        public struct InterfaceStatus: Decodable, Sendable {
            public let name: String?
            public let ipAddress: String?
            public let mac: String?
            public let linkState: String?
        }
        public struct GuestOS: Decodable, Sendable {
            public let prettyName: String?
        }

        public var phase: String { status?.phase ?? "Unknown" }
        public var isRunning: Bool { phase == "Running" }
        public var node: String { status?.nodeName ?? "—" }

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

    /// Both kinds, paired by name.
    ///
    /// Paired on namespace and name rather than on the instance's owner
    /// reference: a VMI created by hand has no owner, and dropping the unowned
    /// ones would hide exactly the machines that most need looking at.
    public func machines(groupVersion: String) async throws -> [KubeVirt.Machine] {
        async let vmsTask = virtualMachines(groupVersion: groupVersion)
        async let vmisTask = virtualMachineInstances(groupVersion: groupVersion)
        let (vms, vmis) = try await (vmsTask, vmisTask)

        var byID: [String: KubeVirt.Machine] = [:]
        for vm in vms {
            byID[vm.id] = KubeVirt.Machine(namespace: vm.metadata.namespace ?? "default",
                                           name: vm.metadata.name, vm: vm, vmi: nil)
        }
        for vmi in vmis {
            let existing = byID[vmi.id]
            byID[vmi.id] = KubeVirt.Machine(namespace: vmi.metadata.namespace ?? "default",
                                            name: vmi.metadata.name, vm: existing?.vm, vmi: vmi)
        }
        return byID.values.sorted { ($0.namespace, $0.name) < ($1.namespace, $1.name) }
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
