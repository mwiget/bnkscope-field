import Foundation
import Observation
import BNKKit

/// The DPU service wiring, read straight off the cluster.
@Observable
@MainActor
final class DPUEngine {
    private(set) var chains: [DPU.ServiceChain] = []
    private(set) var interfaces: [DPU.ServiceInterface] = []
    private(set) var loading = false
    private(set) var failure: String?

    func load(cluster: ManagedCluster) async {
        guard let client = try? cluster.client() else { return }
        loading = true
        failure = nil
        do {
            chains = try await client.serviceChains()
            interfaces = try await client.serviceInterfaces()
        } catch {
            chains = []
            interfaces = []
            failure = TelemetryEngine.brief(error)
        }
        loading = false
    }

    /// Chains sit on one node each, and the pair of nodes carry the same wiring —
    /// so grouping by node is how you see whether they actually match.
    var chainsByNode: [(node: String, chains: [DPU.ServiceChain])] {
        Dictionary(grouping: chains) { $0.spec.node ?? "unassigned" }
            .map { (node: $0.key, chains: $0.value) }
            .sorted { $0.node < $1.node }
    }

    /// Interfaces by kind, in the order traffic meets them: the wire first, then
    /// the host PFs, then the service ends inside.
    var interfacesByType: [(type: String, interfaces: [DPU.ServiceInterface])] {
        let order = ["physical": 0, "pf": 1, "service": 2]
        return Dictionary(grouping: interfaces) { $0.spec.interfaceType ?? "other" }
            .map { (type: $0.key, interfaces: $0.value.sorted { $0.interfaceName < $1.interfaceName }) }
            .sorted { (order[$0.type] ?? 9, $0.type) < (order[$1.type] ?? 9, $1.type) }
    }

    var readyChains: Int { chains.filter(\.isReady).count }
    var readyInterfaces: Int { interfaces.filter(\.isReady).count }
}
