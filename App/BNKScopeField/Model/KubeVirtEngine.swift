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
        if shown != cluster.id {
            // Emptied before the first await, not after the read. Until the
            // new cluster's machines arrive the old ones were still on screen
            // under the new cluster's name, and Start — which asks nothing —
            // sent the old cluster's namespace/name to the new cluster.
            machines = []
            busy = nil
        }
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
            guard shown == cluster.id, !Task.isCancelled else { return }
            machines = read
            failure = nil
        } catch {
            // A load the view cancelled — the same cluster re-probed while
            // this one was in flight — has a replacement already running, and
            // its "cancelled" landing after the replacement's reset showed an
            // error over the list the replacement then filled.
            guard shown == cluster.id, !Task.isCancelled else { return }
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
        } catch {
            if shown == cluster.id { actionFailure = (id: machine.id, why: TelemetryEngine.brief(error)) }
            busy = nil
            return
        }
        // The verb was accepted. A re-read that fails is a different fact and
        // is said differently: reporting it under the row as the verb's own
        // error had a machine that had just stopped showing "503" beside Stop
        // and Restart buttons, and a second Stop answered 409.
        try? await Task.sleep(for: .seconds(1.5))
        do {
            let read = try await client.machines(groupVersion: groupVersion)
            if shown == cluster.id { machines = read }
        } catch {
            if shown == cluster.id {
                actionFailure = (id: machine.id,
                                 why: "\(action.rawValue.capitalized) was accepted, but the list could not be "
                                    + "refreshed: \(TelemetryEngine.brief(error)). Refresh to see the result.")
            }
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

    /// Grouped by namespace, which is how tenancy is usually drawn.
    var byNamespace: [(namespace: String, machines: [KubeVirt.Machine])] {
        Dictionary(grouping: machines, by: \.namespace)
            .map { (namespace: $0.key, machines: $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.namespace < $1.namespace }
    }
}
