import Foundation

/// The DPU service API — `svc.dpu.nvidia.com`.
///
/// Not the DPF operator, which is a different API group and, on the cluster this
/// was built against, is not installed at all. This is the layer that steers
/// traffic on the DPU: interfaces are the ends, chains are the wiring between
/// them, and it is how packets reach HBN and TMM.
public enum DPU {
    public struct ServiceChain: Decodable, Sendable, Identifiable {
        public let metadata: K8s.ObjectMeta
        public let spec: Spec
        public let status: Status?

        public var id: String { "\(metadata.namespace ?? "")/\(metadata.name)" }

        public struct Spec: Decodable, Sendable {
            public let node: String?
            public let switches: [Switch]?
        }
        /// One hop: the ports it joins, and the MTU it carries.
        public struct Switch: Decodable, Sendable {
            public let ports: [Port]?
            public let serviceMTU: Int?
        }
        public struct Port: Decodable, Sendable {
            public let serviceInterface: Selector?
        }
        public struct Selector: Decodable, Sendable {
            public let matchLabels: [String: String]?

            /// What the selector is pointing at, in the words the object uses.
            ///
            /// A port is matched by label rather than named, so the readable end
            /// has to be reassembled: a physical port says `interface: p0`, a
            /// service end says which interface of which service.
            public var described: String {
                guard let labels = matchLabels else { return "—" }
                if let physical = labels["interface"] { return physical }
                let interface = labels["svc.dpu.nvidia.com/interface"]
                let service = labels["svc.dpu.nvidia.com/service"]
                switch (interface, service) {
                case let (i?, s?): return "\(i) · \(s)"
                case let (i?, nil): return i
                case let (nil, s?): return s
                default: return labels.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
                }
            }
        }
        public struct Status: Decodable, Sendable {
            public let conditions: [K8s.Condition]?
        }

        public var isReady: Bool { K8s.isReady(status?.conditions) }
    }

    public struct ServiceInterface: Decodable, Sendable, Identifiable {
        public let metadata: K8s.ObjectMeta
        public let spec: Spec
        public let status: Status?

        public var id: String { "\(metadata.namespace ?? "")/\(metadata.name)" }

        public struct Spec: Decodable, Sendable {
            public let interfaceType: String?
            public let node: String?
            public let service: Service?
            public let physical: Physical?
            public let pf: PF?
        }
        public struct Service: Decodable, Sendable {
            public let interfaceName: String?
            public let network: String?
            public let serviceID: String?
        }
        public struct Physical: Decodable, Sendable { public let interfaceName: String? }
        public struct PF: Decodable, Sendable { public let pfID: Int? }
        public struct Status: Decodable, Sendable {
            public let conditions: [K8s.Condition]?
        }

        public var isReady: Bool { K8s.isReady(status?.conditions) }

        /// The interface's own name, wherever the type happens to keep it.
        public var interfaceName: String {
            spec.service?.interfaceName
                ?? spec.physical?.interfaceName
                ?? spec.pf?.pfID.map { "pf\($0)" }
                ?? metadata.name
        }

        public var detail: String? {
            guard let service = spec.service else { return nil }
            return [service.network, service.serviceID].compactMap { $0 }.joined(separator: " · ")
        }
    }
}

extension K8s {
    /// The condition shape every one of these CRDs uses.
    public struct Condition: Decodable, Sendable {
        public let type: String
        public let status: String
        public let reason: String?
        public let message: String?
    }

    static func isReady(_ conditions: [Condition]?) -> Bool {
        (conditions ?? []).contains { $0.type == "Ready" && $0.status == "True" }
    }
}

extension KubeClient {
    public func serviceChains() async throws -> [DPU.ServiceChain] {
        try await getJSON(K8s.List<DPU.ServiceChain>.self,
                          "/apis/svc.dpu.nvidia.com/v1alpha1/servicechains").items
    }

    public func serviceInterfaces() async throws -> [DPU.ServiceInterface] {
        try await getJSON(K8s.List<DPU.ServiceInterface>.self,
                          "/apis/svc.dpu.nvidia.com/v1alpha1/serviceinterfaces").items
    }
}
