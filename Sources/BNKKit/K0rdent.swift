import Foundation

/// Recognising k0rdent — Mirantis' cluster manager — from the inside of a
/// cluster, without being told which cluster it is.
///
/// Two questions that look like one and are not. "Is this a k0rdent management
/// cluster" is answered by the `k0rdent.mirantis.com` API being served here.
/// "Is this cluster managed by k0rdent" is answered somewhere else entirely,
/// because k0rdent leaves a managed cluster almost unmarked: no labels, no
/// annotations, no CRDs of its own. What it does leave is a Sveltos agent, and
/// that agent is launched with the name of the object it belongs to.
public enum K0rdent {

    public static let group = "k0rdent.mirantis.com"

    /// What a cluster is to k0rdent.
    public enum Role: String, Sendable, Comparable {
        /// Runs the controllers, serves the API, holds the ClusterDeployments.
        case management
        /// Provisioned or adopted by a management cluster elsewhere.
        case managed

        public static func < (a: Role, b: Role) -> Bool { a.rawValue < b.rawValue }
    }

    /// Which distribution. The chart names differ and nothing else does.
    public enum Edition: String, Sendable {
        /// Mirantis' commercial build, `k0rdent-enterprise`. Adds a licence
        /// controller and the `licenses` API.
        case enterprise
        /// Upstream k0rdent/KCM.
        case community
    }

    /// The k0rdent object a managed cluster belongs to, read out of the agent
    /// that k0rdent installed on it.
    public struct ManagedBy: Sendable, Equatable {
        /// The namespace of the ClusterDeployment on the management cluster —
        /// `kcm-system` on a default install.
        public let namespace: String
        /// The ClusterDeployment's name.
        public let name: String
        /// `Capi` for a cluster k0rdent provisioned, `Sveltos` for one adopted
        /// through the `adopted-cluster` template. Absent on older agents.
        public let clusterType: String?
    }

    /// Everything the probe managed to learn. All of it optional: a read-only
    /// token, a partially installed cluster and an unreachable apiserver all
    /// produce a partial answer, and a partial answer is worth more than none.
    public struct Fingerprint: Sendable, Equatable {
        public var role: Role?
        public var edition: Edition?
        /// The k0rdent version, from the Release object — `2.1.0-rc1.2`.
        public var version: String?
        /// The Release name, which is also the KCM template name —
        /// `k0rdent-enterprise-2-1-0-rc1-2`.
        public var release: String?
        /// CAPI providers the management cluster reports as available.
        public var providers: [String] = []
        public var managedBy: ManagedBy?

        public init() {}

        public var isK0rdent: Bool { role != nil }

        /// A single line for a badge or a subtitle.
        public var summary: String {
            guard let role else { return "not k0rdent" }
            switch role {
            case .management:
                let edition = edition.map { $0 == .enterprise ? "Enterprise" : "Community" } ?? "k0rdent"
                return [edition, version].compactMap { $0 }.joined(separator: " ")
            case .managed:
                guard let managedBy else { return "managed by k0rdent" }
                return "managed as \(managedBy.namespace)/\(managedBy.name)"
            }
        }
    }

    // MARK: - Objects

    /// The singleton that says a management cluster is a management cluster.
    public struct Management: Decodable, Sendable {
        public let metadata: K8s.ObjectMeta
        public let spec: Spec?
        public let status: Status?

        public struct Spec: Decodable, Sendable {
            public let release: String?
        }
        public struct Status: Decodable, Sendable {
            public let release: String?
            public let availableProviders: [String]?
            public let conditions: [K8s.Condition]?
        }

        public var isReady: Bool { K8s.isReady(status?.conditions) }
    }

    /// What a management cluster is pinned to: one CAPI version, one KCM chart,
    /// one regional chart, and the provider set.
    public struct Release: Decodable, Sendable {
        public let metadata: K8s.ObjectMeta
        public let spec: Spec?

        public struct Spec: Decodable, Sendable {
            public let version: String?
            public let kcm: TemplateRef?
            public let capi: TemplateRef?
            public let regional: TemplateRef?
            public let providers: [TemplateRef]?
        }
        public struct TemplateRef: Decodable, Sendable {
            public let template: String?
        }
    }

    /// One managed cluster, as the management cluster sees it.
    public struct ClusterDeployment: Decodable, Sendable, Identifiable {
        public let metadata: K8s.ObjectMeta
        public let spec: Spec?
        public let status: Status?

        public var id: String { "\(metadata.namespace ?? "")/\(metadata.name)" }

        public struct Spec: Decodable, Sendable {
            public let template: String?
            public let credential: String?
        }
        public struct Status: Decodable, Sendable {
            public let conditions: [K8s.Condition]?
        }

        public var isReady: Bool { K8s.isReady(status?.conditions) }
    }
}

extension KubeClient {

    /// Ask the cluster what it is, in as few round trips as it can be done.
    ///
    /// `groups` is the discovery map from ``apiGroups()``. It is passed in
    /// rather than fetched because the caller is already probing several things
    /// and `/apis` answers all of them at once.
    public func k0rdentFingerprint(groups: [String: String]) async -> K0rdent.Fingerprint {
        var found = K0rdent.Fingerprint()

        // The management cluster is checked FIRST, and its answer wins, because
        // the managed-cluster test below fires on it too. k0rdent registers the
        // management cluster with Sveltos as a cluster it manages — `mgmt/mgmt`
        // on a default install — so the agent there is launched with exactly the
        // flag that otherwise means "I am somebody's child". Testing in the
        // other order labels every management cluster as managed.
        if let groupVersion = groups[K0rdent.group] {
            // The group is served, so the answer is here; if its resource list
            // cannot be read the answer is unknown, not "managed". Falling
            // through to the Sveltos test on a read failure is the same
            // inversion as falling through on a failed Management read.
            guard let resources = try? await apiResources(groupVersion: groupVersion) else { return found }
            let servesManagements = resources.contains("managements")
            if servesManagements, let management = try? await k0rdentManagement(groupVersion) {
                found.role = .management
                found.release = management.status?.release ?? management.spec?.release

                // Two independent reads of the edition, because either can be
                // missing. The Release object carries the chart name, and the
                // enterprise chart is called `k0rdent-enterprise` where upstream
                // is `kcm`. If no Release is readable, the `licenses` API is
                // the fallback: it ships only with enterprise, and — unlike a
                // License object, which a working install may simply not have
                // yet — the API is there from the moment the chart is applied.
                if let release = try? await k0rdentRelease(groupVersion, named: found.release) {
                    found.version = release.spec?.version
                    let template = release.spec?.kcm?.template ?? release.metadata.name
                    found.edition = template.hasPrefix("k0rdent-enterprise") ? .enterprise : .community
                }
                if found.edition == nil {
                    found.edition = resources.contains("licenses") ? .enterprise : .community
                }
                found.providers = management.status?.availableProviders ?? []
                return found
            }

            // The group serves `managements` and the object did not come back:
            // RBAC that forbids the read, or the aggregated API answering 500.
            // Both arrive here as a silently swallowed `try?`, and falling
            // through would run the managed test on a management cluster — the
            // one thing the ordering above exists to prevent. Say what is known
            // instead of guessing: this is a management cluster whose
            // Management object could not be read.
            if servesManagements {
                found.role = .management
                return found
            }
        }

        // Nothing k0rdent installs on a managed cluster names k0rdent. The
        // Sveltos agent is the exception, and only in its arguments: it is told
        // which object on which management cluster it reports for, and those
        // three flags are the whole of the evidence.
        if let agent = try? await deployment(namespace: "projectsveltos", name: "sveltos-agent-manager") {
            let args = agent.podArgs
            if args.contains("--current-cluster=managed-cluster"),
               let namespace = Self.flag("--cluster-namespace", in: args),
               let name = Self.flag("--cluster-name", in: args) {
                found.role = .managed
                found.managedBy = K0rdent.ManagedBy(namespace: namespace, name: name,
                                                    clusterType: Self.flag("--cluster-type", in: args))
            }
        }
        return found
    }

    /// `--name=value` out of a container's argument list.
    static func flag(_ name: String, in args: [String]) -> String? {
        for arg in args where arg.hasPrefix(name + "=") {
            return String(arg.dropFirst(name.count + 1))
        }
        return nil
    }

    /// The Management singleton, whatever the served version happens to be.
    ///
    /// The version is not fixed: a management cluster serves `v1beta1` while a
    /// managed cluster that picked up one stray k0rdent CRD from a service
    /// template serves `v1alpha1`. Hard-coding either one makes the probe fail
    /// on half the estate, so discovery decides.
    func k0rdentManagement(_ groupVersion: String) async throws -> K0rdent.Management? {
        try await getJSON(K8s.List<K0rdent.Management>.self, "/apis/\(groupVersion)/managements")
            .items.first
    }

    func k0rdentRelease(_ groupVersion: String, named: String?) async throws -> K0rdent.Release? {
        let releases = try await getJSON(K8s.List<K0rdent.Release>.self,
                                        "/apis/\(groupVersion)/releases").items
        // Prefer the one the Management is actually on. A cluster keeps every
        // Release it has ever been offered, so "the first one" is frequently a
        // version this cluster is not running.
        return releases.first { $0.metadata.name == named } ?? releases.first
    }

    /// Every managed cluster this management cluster owns.
    public func clusterDeployments(groupVersion: String) async throws -> [K0rdent.ClusterDeployment] {
        try await getJSON(K8s.List<K0rdent.ClusterDeployment>.self,
                          "/apis/\(groupVersion)/clusterdeployments").items
    }
}
