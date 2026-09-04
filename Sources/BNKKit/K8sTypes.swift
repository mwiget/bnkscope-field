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
            /// Read because an operator frequently says what it is for only
            /// here. The Sveltos agent names the k0rdent object it reports for
            /// in its own flags and nowhere else on the cluster.
            public let args: [String]?
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

        /// Every container whose log can be followed.
        ///
        /// The log endpoint refuses a pod with more than one container unless
        /// told which, so a viewer that wants the whole pod has to ask for each
        /// separately — an f5-tmm pod is eight streams, not one.
        public var logSources: [String] {
            let declared = (spec?.containers ?? []).map(\.name)
            let attached = (spec?.ephemeralContainers ?? []).map(\.name)
            return declared + attached
        }
    }

    public struct Namespace: Decodable, Sendable {
        public let metadata: ObjectMeta
    }

    public struct Event: Decodable, Sendable {
        public let metadata: ObjectMeta
        public let reason: String?
        public let message: String?
        public let type: String?
        public let count: Int?
        public let lastTimestamp: Date?
        public let eventTime: Date?
        public let involvedObject: InvolvedObject?

        public struct InvolvedObject: Decodable, Sendable {
            public let kind: String?
            public let name: String?
            public let namespace: String?
        }

        /// Events written by the newer API set `eventTime` and leave
        /// `lastTimestamp` nil; the older path does the reverse.
        public var at: Date? { lastTimestamp ?? eventTime }
    }

    public struct Secret: Decodable, Sendable {
        public let metadata: ObjectMeta
        public let data: [String: String]?

        /// Secret values are base64 in the API on top of whatever they already
        /// are, so a PEM arrives doubly wrapped.
        public func pem(_ key: String) -> Data? {
            guard let encoded = data?[key] else { return nil }
            return Data(base64Encoded: encoded, options: .ignoreUnknownCharacters)
        }
    }

    /// A Kamaji tenant control plane — one hosted Kubernetes control plane, which
    /// is how the DPF tenant clusters are run.
    public struct TenantControlPlane: Decodable, Sendable {
        public let metadata: ObjectMeta
        public let status: Status?

        public struct Status: Decodable, Sendable {
            public let controlPlaneEndpoint: String?
            public let kubernetesResources: Resources?
            public let certificates: [String: CertificateRef]?
            public let kubeconfig: Kubeconfigs?
        }
        public struct Resources: Decodable, Sendable {
            public let version: Version?
        }
        public struct Version: Decodable, Sendable {
            public let status: String?
            public let version: String?
        }
        public struct CertificateRef: Decodable, Sendable {
            public let secretName: String?
            public let lastUpdate: Date?
        }
        public struct Kubeconfigs: Decodable, Sendable {
            public let admin: CertificateRef?
        }

        public var isReady: Bool { status?.kubernetesResources?.version?.status == "Ready" }
    }

    public struct Node: Decodable, Sendable {
        public let metadata: ObjectMeta
        public let status: Status?

        public struct Status: Decodable, Sendable {
            public let nodeInfo: NodeInfo?
            public let conditions: [Condition]?
            /// Quantities as strings — `"2"`, `"64Gi"`. Only the extended
            /// resources are read here and those are always whole numbers, so
            /// nothing parses the suffix form.
            public let allocatable: [String: String]?
        }
        public struct NodeInfo: Decodable, Sendable {
            public let architecture: String?
            public let osImage: String?
            public let kubeletVersion: String?
        }

        public var isReady: Bool { K8s.isReady(status?.conditions) }

        /// Extended resources this node offers for GPUs, as name and count.
        ///
        /// Two naming schemes turn up and they mean different things. The GPU
        /// Operator advertises `nvidia.com/gpu` for containers; KubeVirt
        /// advertises one resource per PCI device it is permitted to pass
        /// through, named after the device — `nvidia.com/GA104GL_RTX_A4000`.
        /// A k0rdent cluster only ever has the second: the catalog ships no GPU
        /// Operator, and the only GPU components anywhere in it belong to
        /// KubeVirt. So the vendor prefix has to be matched rather than either
        /// exact name, since the device half is whatever the card is called.
        ///
        /// Which is why the exclusions exist. `nvidia.com/` is a vendor, not a
        /// product line: a BlueField DPU cluster advertises `nvidia.com/bf_sf`
        /// and `nvidia.com/bf_sf_trusted` — scalable functions, which are NICs.
        /// Counting those reported twenty-six GPUs on a cluster that has none.
        /// The list is by name shape because there is nothing in the node
        /// status that says what kind of device a resource is.
        public var gpuResources: [(name: String, count: Int)] {
            (status?.allocatable ?? [:])
                .filter { $0.key.hasPrefix("nvidia.com/") || $0.key.hasPrefix("amd.com/") }
                .compactMap { key, value in
                    let device = String(key.split(separator: "/").last ?? "")
                    guard !Self.notAGPU.contains(where: { device.hasPrefix($0) }),
                          let count = Int(value), count > 0 else { return nil }
                    return (name: device, count: count)
                }
                .sorted { $0.name < $1.name }
        }

        /// Device names under a GPU vendor's prefix that are not GPUs:
        /// BlueField scalable functions and virtual functions, and the generic
        /// passthrough resource the SR-IOV device plugin uses for NICs.
        static let notAGPU = ["bf_sf", "bf_vf", "hostdev", "mlnx", "sriov"]
    }

    /// Just enough of a Deployment to read what its pods are launched with.
    public struct Deployment: Decodable, Sendable {
        public let metadata: ObjectMeta
        public let spec: Spec?

        public struct Spec: Decodable, Sendable {
            public let replicas: Int?
            public let template: PodTemplate?
        }
        public struct PodTemplate: Decodable, Sendable {
            public let spec: Pod.Spec?
        }

        /// The flags of the first container, which for a single-purpose
        /// operator is the only container.
        public var podArgs: [String] { spec?.template?.spec?.containers.first?.args ?? [] }
    }

    /// `/apis` — which API groups this server serves, and at which version.
    public struct APIGroupList: Decodable, Sendable {
        public let groups: [Group]

        public struct Group: Decodable, Sendable {
            public let name: String
            public let preferredVersion: Version?
        }
        public struct Version: Decodable, Sendable {
            public let groupVersion: String
        }
    }

    /// `/apis/<group>/<version>` — which kinds that group serves.
    public struct APIResourceList: Decodable, Sendable {
        public let resources: [Resource]

        public struct Resource: Decodable, Sendable {
            public let name: String
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

    public func secret(namespace: String, name: String) async throws -> K8s.Secret {
        try await getJSON(K8s.Secret.self, "/api/v1/namespaces/\(namespace)/secrets/\(name)")
    }

    /// Every API group the server serves, mapped to its preferred version —
    /// `"kubevirt.io": "kubevirt.io/v1"`.
    ///
    /// One request that answers "is this thing installed" for every operator at
    /// once, which is why detection asks for it first and passes the result
    /// around rather than probing each group separately. It also removes the
    /// need to guess a version: k0rdent serves `v1beta1` on a management
    /// cluster and `v1alpha1` on a cluster that picked up a stray CRD from a
    /// service template, and a hard-coded path would 404 on one of them.
    public func apiGroups() async throws -> [String: String] {
        Self.preferredVersions(of: try await getJSON(K8s.APIGroupList.self, "/apis"))
    }

    /// The group→preferred-version map, split out so the duplicate case can be
    /// tested without a cluster that misbehaves on demand.
    ///
    /// First one wins rather than `uniqueKeysWithValues`, which *traps* on a
    /// repeated group name. The list is assembled by the apiserver out of
    /// whatever the aggregated APIServices register, so a duplicate is somebody
    /// else's bug — but it would take the app down from inside a call every
    /// caller has wrapped in `try?` and believes is safe.
    static func preferredVersions(of list: K8s.APIGroupList) -> [String: String] {
        Dictionary(list.groups.compactMap { group in
            group.preferredVersion.map { (group.name, $0.groupVersion) }
        }, uniquingKeysWith: { first, _ in first })
    }

    /// The plural resource names one group version serves.
    ///
    /// Distinguishes a group that is fully installed from one represented by a
    /// single stray CRD, and is the cheapest way to see an API that exists but
    /// holds no objects — `licenses` on a k0rdent Enterprise cluster that has
    /// not been given its licence yet.
    public func apiResources(groupVersion: String) async throws -> Set<String> {
        Set(try await getJSON(K8s.APIResourceList.self, "/apis/\(groupVersion)").resources.map(\.name))
    }

    public func deployment(namespace: String, name: String) async throws -> K8s.Deployment {
        try await getJSON(K8s.Deployment.self, "/apis/apps/v1/namespaces/\(namespace)/deployments/\(name)")
    }

    /// Kamaji's tenant control planes, cluster-wide.
    ///
    /// This is the link between the two clusters in the sidebar: infra hosts
    /// tenant1's control plane, and the endpoint here is the one in tenant1's
    /// kubeconfig. Nothing else in the app says they are related.
    public func tenantControlPlanes() async throws -> [K8s.TenantControlPlane] {
        try await getJSON(K8s.List<K8s.TenantControlPlane>.self,
                          "/apis/kamaji.clastix.io/v1alpha1/tenantcontrolplanes").items
    }

    /// Warning events, cluster-wide.
    ///
    /// The server-side filter matters: on a busy cluster the Normal events
    /// outnumber the Warnings by orders of magnitude, and none of them are what
    /// "is anything wrong" is asking about.
    public func warningEvents() async throws -> [K8s.Event] {
        try await getJSON(K8s.List<K8s.Event>.self, "/api/v1/events",
                          query: ["fieldSelector": "type=Warning"]).items
    }

    public func namespaces() async throws -> [String] {
        try await getJSON(K8s.List<K8s.Namespace>.self, "/api/v1/namespaces")
            .items.map(\.metadata.name).sorted()
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
