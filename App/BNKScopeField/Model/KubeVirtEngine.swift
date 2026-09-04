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

    /// The cluster the contents above belong to.
    ///
    /// Every write below lands after an await, and the selection can change
    /// while one is in flight. Without this an action's re-read repopulates the
    /// list from the cluster it ran on while the screen is showing another —
    /// and the next verb is then addressed by a name that came from the wrong
    /// cluster, which on template-deployed clusters resolves to a real machine.
    private var shown: ManagedCluster.ID?

    func load(cluster: ManagedCluster) async {
        shown = cluster.id
        // Keyed on `namespace/name`, which repeats across clusters deployed
        // from one template, so it cannot be allowed to outlive its cluster.
        actionFailure = nil
        guard let version = cluster.apiGroups[KubeVirt.group], let client = try? cluster.client() else {
            machines = []
            failure = nil
            // A load that never started still owns the spinner, because an
            // older one may be about to return early and leave it running.
            loading = false
            return
        }
        loading = true
        failure = nil
        do {
            let read = try await client.machines(groupVersion: version)
            guard shown == cluster.id else { return }
            machines = read
        } catch {
            guard shown == cluster.id else { return }
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
        // Taken from the cluster being acted on rather than from a version this
        // engine cached, which belongs to whichever cluster loaded last.
        guard let groupVersion = cluster.apiGroups[KubeVirt.group],
              let client = try? cluster.client() else { return }
        busy = machine.id
        actionFailure = nil
        do {
            try await client.perform(action, on: machine, groupVersion: groupVersion)
            try? await Task.sleep(for: .seconds(1.5))
            let read = try await client.machines(groupVersion: groupVersion)
            if shown == cluster.id { machines = read }
        } catch {
            if shown == cluster.id { actionFailure = (id: machine.id, why: TelemetryEngine.brief(error)) }
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

    /// Machines whose root disk is an image. The other thing that separates a
    /// VM that comes back from one that does not — after a stop, this time,
    /// rather than a reboot.
    var ephemeral: Int { machines.filter(\.bootsFromEphemeralDisk).count }

    /// The virt-launcher pod running this machine, found on demand.
    ///
    /// Not in the VMI: `status.activePods` maps pod UIDs to nodes and never
    /// names the pod. The launcher carries the machine's name in an
    /// annotation, so it is one label-selected list in the namespace and a
    /// match on that.
    func launcherPod(of machine: KubeVirt.Machine, cluster: ManagedCluster) async -> String? {
        guard let client = try? cluster.client() else { return nil }
        let pods = (try? await client.pods(namespace: machine.namespace,
                                           labelSelector: "kubevirt.io=virt-launcher")) ?? []
        return pods.first { $0.metadata.annotations?["kubevirt.io/domain"] == machine.name }?.metadata.name
    }

    /// Grouped by namespace, which is how tenancy is usually drawn.
    var byNamespace: [(namespace: String, machines: [KubeVirt.Machine])] {
        Dictionary(grouping: machines, by: \.namespace)
            .map { (namespace: $0.key, machines: $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.namespace < $1.namespace }
    }
}
