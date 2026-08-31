import Foundation
import Observation
import BNKKit

/// What Field can learn about NICo without speaking to Forge.
///
/// The tenant and load-balancer inventory lives behind Forge's gRPC API, which
/// needs server reflection and a dynamic protobuf stack — that is the Edge
/// collector's job, and it is not here. Everything on this screen is either a
/// plain Kubernetes read or a scrape of nico-api's own metrics port, which
/// turns out to be most of what the desktop build shows.
@Observable
@MainActor
final class NICoEngine {
    struct Snapshot: Sendable {
        var apiPods: [K8s.Pod] = []
        var providerPods: [K8s.Pod] = []
        var adminCert: Certificate?
        var adminCertSecret: String?
        var endpoint: String?
        var tenants: [Tenant] = []
        var metrics: [String: Double] = [:]
        var problems: [String] = []
    }

    struct Tenant: Identifiable, Sendable {
        var id: String { name }
        let name: String
        let namespace: String
        let version: String?
        let ready: Bool
        let endpoint: String?
        var ca: Certificate?
        /// Whether a cluster Field already holds points at this endpoint. The
        /// two clusters in the sidebar are related and nothing else says so.
        var knownCluster: String?
    }

    private(set) var snapshot = Snapshot()
    private(set) var loading = false

    /// The admin identity the desktop build surfaces; its expiry is the single
    /// most useful fact here, and lab CAs do lapse.
    static let adminCertSecret = "tmm-lb-admin-cert"
    static let namespace = "nico-system"

    func load(cluster: ManagedCluster, known: [ManagedCluster]) async {
        guard let client = try? cluster.client() else { return }
        loading = true
        var snap = Snapshot()

        let pods = (try? await client.pods(namespace: Self.namespace)) ?? []
        snap.apiPods = pods.filter { ($0.metadata.labels?["app.kubernetes.io/name"]) == "nico-api" }
        snap.providerPods = pods.filter { ($0.metadata.labels?["app"] ?? "").hasPrefix("nico-lb-provider") }

        if let secret = try? await client.secret(namespace: Self.namespace, name: Self.adminCertSecret) {
            snap.adminCertSecret = Self.adminCertSecret
            if let pem = secret.pem("tls.crt") { snap.adminCert = try? Certificate.first(inPEM: pem) }
        } else {
            snap.problems.append("Could not read \(Self.adminCertSecret) — this kubeconfig may not be allowed to read secrets in \(Self.namespace).")
        }

        for tcp in (try? await client.tenantControlPlanes()) ?? [] {
            let endpoint = tcp.status?.controlPlaneEndpoint
            var tenant = Tenant(
                name: tcp.metadata.name,
                namespace: tcp.metadata.namespace ?? "—",
                version: tcp.status?.kubernetesResources?.version?.version,
                ready: tcp.isReady,
                endpoint: endpoint,
                ca: nil,
                knownCluster: endpoint.flatMap { Self.match(endpoint: $0, in: known) })
            if let caSecret = tcp.status?.certificates?["ca"]?.secretName,
               let namespace = tcp.metadata.namespace,
               let secret = try? await client.secret(namespace: namespace, name: caSecret),
               let pem = secret.pem("ca.crt") {
                tenant.ca = try? Certificate.first(inPEM: pem)
            }
            snap.tenants.append(tenant)
        }

        // nico-api publishes its own Prometheus metrics on a second port. Reached
        // the same way TMM's exporter is: a tunnel to the pod, no ingress.
        if let pod = snap.apiPods.first(where: { $0.status?.phase == "Running" }) {
            let scraper = PodScraper(client: client, namespace: Self.namespace,
                                     pod: pod.metadata.name, port: 1080)
            if let samples = try? await scraper.scrape() {
                snap.metrics = Self.headline(from: samples)
                snap.endpoint = "\(pod.metadata.name):1080"
            } else {
                snap.problems.append("nico-api is running but its metrics port did not answer.")
            }
            await scraper.stop()
        }

        snapshot = snap
        loading = false
    }

    /// A tenant control plane's endpoint against the servers Field already holds,
    /// by host and port rather than by name — the names differ.
    static func match(endpoint: String, in clusters: [ManagedCluster]) -> String? {
        clusters.first {
            guard let host = $0.context.server.host(), let port = $0.context.server.port else { return false }
            return endpoint == "\(host):\(port)"
        }?.displayName
    }

    /// Totals worth a tile. Only those actually present are returned, because
    /// a metric name that has been renamed upstream should show as absent
    /// rather than as zero.
    static func headline(from samples: [Sample]) -> [String: Double] {
        let wanted = [
            "nico_api_db_queries_total",
            "nico_api_grpc_server_duration_milliseconds_count",
            "nico_active_host_firmware_update_count",
        ]
        var out: [String: Double] = [:]
        for name in wanted {
            let total = samples.filter { $0.name == name }.reduce(0) { $0 + $1.value }
            if samples.contains(where: { $0.name == name }) { out[name] = total }
        }
        return out
    }
}
