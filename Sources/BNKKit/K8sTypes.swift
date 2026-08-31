import Foundation

/// The slices of the Kubernetes API Field reads.
///
/// Hand-written rather than generated: the full openapi schema is megabytes and
/// almost none of it is used. Every field here is one the UI actually renders.
public enum K8s {
    public struct VersionInfo: Decodable, Sendable {
        public let gitVersion: String
        public let platform: String?
    }

    public struct ObjectMeta: Decodable, Sendable {
        public let name: String
        public let namespace: String?
        public let labels: [String: String]?
        public let annotations: [String: String]?
        public let creationTimestamp: Date?
        public let ownerReferences: [OwnerReference]?
    }

    public struct OwnerReference: Decodable, Sendable {
        public let kind: String
        public let name: String
        public let controller: Bool?
    }

    /// Just enough of a ReplicaSet to hop from it to the Deployment that made it.
    public struct ReplicaSet: Decodable, Sendable {
        public let metadata: ObjectMeta
    }

    public struct List<Item: Decodable & Sendable>: Decodable, Sendable {
        public let items: [Item]
    }

    public struct Pod: Decodable, Sendable {
        public let metadata: ObjectMeta
        public let spec: Spec?
        public let status: Status?

        public struct Spec: Decodable, Sendable {
            public let nodeName: String?
            public let containers: [Container]
            public let ephemeralContainers: [Container]?
            public let volumes: [Volume]?
        }
        public struct Volume: Decodable, Sendable {
            public let name: String
        }
        public struct Container: Decodable, Sendable {
            public let name: String
            public let image: String?
        }
        public struct Status: Decodable, Sendable {
            public let phase: String?
            public let podIP: String?
            public let containerStatuses: [ContainerStatus]?
            public let ephemeralContainerStatuses: [ContainerStatus]?
        }
        public struct ContainerStatus: Decodable, Sendable {
            public let name: String
            public let ready: Bool?
            public let restartCount: Int?
            public let image: String?
        }

        public var node: String { spec?.nodeName ?? "—" }
        public var ready: String {
            let cs = status?.containerStatuses ?? []
            return "\(cs.filter { $0.ready == true }.count)/\(cs.count)"
        }

        /// How a container came to be in this pod, which decides how long it
        /// lasts.
        public enum ContainerKind: Sendable {
            /// Declared in the pod spec. Survives a restart of the pod.
            case durable
            /// Attached to a running pod after the fact. Cannot be removed in
            /// place, and is gone the moment the pod is recreated.
            case ephemeral
        }

        /// Where a container is, if it is here at all.
        ///
        /// bnkscope injects the exporter as an ephemeral container, but a
        /// cluster can equally have it in the pod spec — the lab this was
        /// written against does. Reporting which is not pedantry: an ephemeral
        /// exporter stops the next time TMM restarts, and a page that does not
        /// say so lets you find out later.
        public func container(named name: String) -> ContainerKind? {
            if (status?.containerStatuses ?? []).contains(where: { $0.name == name }) { return .durable }
            if (status?.ephemeralContainerStatuses ?? []).contains(where: { $0.name == name }) { return .ephemeral }
            return nil
        }

        public func has(container name: String) -> Bool { container(named: name) != nil }
    }

    public struct Node: Decodable, Sendable {
        public let metadata: ObjectMeta
        public let status: Status?

        public struct Status: Decodable, Sendable {
            public let nodeInfo: NodeInfo?
            public let conditions: [Condition]?
        }
        public struct NodeInfo: Decodable, Sendable {
            public let architecture: String?
            public let osImage: String?
            public let kubeletVersion: String?
        }
        public struct Condition: Decodable, Sendable {
            public let type: String
            public let status: String
        }

        public var isReady: Bool {
            (status?.conditions ?? []).contains { $0.type == "Ready" && $0.status == "True" }
        }
    }
}

extension KubeClient {
    public func version() async throws -> K8s.VersionInfo {
        try await getJSON(K8s.VersionInfo.self, "/version")
    }

    public func nodes() async throws -> [K8s.Node] {
        try await getJSON(K8s.List<K8s.Node>.self, "/api/v1/nodes").items
    }

    public func pods(namespace: String? = nil, labelSelector: String? = nil) async throws -> [K8s.Pod] {
        let path = namespace.map { "/api/v1/namespaces/\($0)/pods" } ?? "/api/v1/pods"
        var q: [String: String] = [:]
        if let labelSelector { q["labelSelector"] = labelSelector }
        return try await getJSON(K8s.List<K8s.Pod>.self, path, query: q).items
    }

    /// Scrape a port inside a pod, through the apiserver.
    ///
    /// One-shot: opens a tunnel, reads, closes. Fine for a probe or a test, but
    /// a repeated scrape should hold `PodScraper` instead — the tunnel setup
    /// dominates everything else on a real device.
    public func scrape(namespace: String, pod: String, port: Int, path: String = "/metrics") async throws -> [Sample] {
        let scraper = PodScraper(client: self, namespace: namespace, pod: pod, port: port)
        defer { Task { await scraper.stop() } }
        return try await scraper.scrape(path: path)
    }
}
