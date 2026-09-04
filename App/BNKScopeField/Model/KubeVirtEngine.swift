import Foundation
import Observation
import BNKKit

/// The virtual machines on a cluster, and the three things that can be done to
/// them.
@Observable
@MainActor
final class KubeVirtEngine {
    private(set) var machines: [KubeVirt.Machine] = []
    private(set) var loading = false
    private(set) var failure: String?
    /// The machine an action is in flight on, so its row can say so and its
    /// buttons can refuse a second press.
    private(set) var busy: KubeVirt.Machine.ID?
    /// The last action's complaint, kept next to the machine it was about.
    private(set) var actionFailure: (id: KubeVirt.Machine.ID, why: String)?

    /// Which version of `kubevirt.io` this cluster serves. Held because every
    /// request needs it and discovery already answered it during the probe.
    private var groupVersion: String?

    func load(cluster: ManagedCluster) async {
        guard let client = try? cluster.client() else { return }
        guard let version = cluster.apiGroups[KubeVirt.group] else {
            machines = []
            failure = nil
            return
        }
        groupVersion = version
        loading = true
        failure = nil
        do {
            machines = try await client.machines(groupVersion: version)
        } catch {
            machines = []
            failure = TelemetryEngine.brief(error)
        }
        loading = false
    }

    /// Run a lifecycle verb, then re-read.
    ///
    /// The re-read is not optional and it is not immediate. `start` returns as
    /// soon as virt-controller has accepted the change, well before a VMI
    /// exists, so a list refreshed on the same tick shows the machine exactly
    /// as it was and reads as a button that did nothing. A short wait first
    /// costs a second and makes the screen agree with the cluster.
    func perform(_ action: KubeVirt.Action, on machine: KubeVirt.Machine,
                 cluster: ManagedCluster) async {
        guard let client = try? cluster.client(), let groupVersion else { return }
        busy = machine.id
        actionFailure = nil
        do {
            try await client.perform(action, on: machine, groupVersion: groupVersion)
            try? await Task.sleep(for: .seconds(1.5))
            machines = try await client.machines(groupVersion: groupVersion)
        } catch {
            actionFailure = (id: machine.id, why: TelemetryEngine.brief(error))
        }
        busy = nil
    }

    var running: Int { machines.filter(\.isRunning).count }

    /// Machines that have no `VirtualMachine` behind them.
    ///
    /// Worth counting on its own, because it is the difference between a
    /// cluster whose VMs come back after a reboot and one whose VMs do not.
    var standalone: Int { machines.filter { !$0.isManageable }.count }

    var withGPUs: Int { machines.filter { !$0.gpus.isEmpty }.count }

    /// Grouped by namespace, which is how tenancy is usually drawn.
    var byNamespace: [(namespace: String, machines: [KubeVirt.Machine])] {
        Dictionary(grouping: machines, by: \.namespace)
            .map { (namespace: $0.key, machines: $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.namespace < $1.namespace }
    }
}
