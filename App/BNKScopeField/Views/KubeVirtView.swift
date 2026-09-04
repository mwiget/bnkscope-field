import SwiftUI
import BNKKit

/// Virtual machines on a cluster running KubeVirt.
struct KubeVirtView: View {
    @Binding var columns: NavigationSplitViewVisibility
    @Environment(ClusterStore.self) private var store
    @Environment(KubeVirtEngine.self) private var kubevirt

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Theme.border)
            if store.current?.roles.contains(.kubevirt) != true {
                Message(title: "KubeVirt is not installed here",
                        detail: "This screen appears on a cluster whose apiserver serves kubevirt.io.")
            } else if let why = unreachable {
                Message(title: "Cannot reach \(store.current?.displayName ?? "this cluster")",
                        detail: why, tone: Theme.bad)
            } else if let failure = kubevirt.failure {
                Message(title: "Could not read the KubeVirt API", detail: failure, tone: Theme.bad)
            } else if kubevirt.machines.isEmpty && !kubevirt.loading {
                Message(title: "No virtual machines",
                        detail: "KubeVirt is installed and serving, but no VirtualMachine or "
                              + "VirtualMachineInstance exists on this cluster.")
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        if kubevirt.standalone > 0 { standaloneNote }
                        if kubevirt.ephemeral > 0 { ephemeralNote }
                        ForEach(kubevirt.byNamespace, id: \.namespace) { group in
                            card(group.namespace, badge: "\(group.machines.count)") {
                                ForEach(group.machines) { machine in
                                    MachineRow(machine: machine)
                                }
                            }
                        }
                    }
                    .padding(20)
                }
            }
        }
        .background(Theme.bg)
        .noNavigationBar()
        .task(id: "\(store.selected ?? "")#\(store.current?.probeGeneration ?? 0)") { await reload() }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            SidebarToggle(columns: $columns)
            Text("KubeVirt").font(.system(size: 19, weight: .semibold)).foregroundStyle(Theme.fg).fixedSize()
            if !kubevirt.machines.isEmpty {
                Text("\(kubevirt.running)/\(kubevirt.machines.count) running"
                     + (kubevirt.withGPUs > 0 ? " · \(kubevirt.withGPUs) with a GPU" : ""))
                    .font(Theme.mono(11.5)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 8)
            if kubevirt.loading { ProgressView().controlSize(.small) }
            Button("Refresh") { Task { await reload() } }
                .buttonStyle(.bordered).controlSize(.small).disabled(kubevirt.loading)
        }
        .padding(.horizontal, 20).frame(height: 58)
    }

    /// Said once at the top rather than on every row it applies to.
    ///
    /// A standalone VMI is not a fault and the screen should not shout, but it
    /// is the reason those rows have no buttons, and someone who does not know
    /// that reads the missing buttons as the app failing to offer them.
    private var standaloneNote: some View {
        Banner(text: "\(kubevirt.standalone) of these are VirtualMachineInstances with no VirtualMachine. "
                   + "They run, but they have no run state to start or stop and they do not come back "
                   + "after the node reboots — re-apply the manifest to recreate them.",
               tone: Theme.muted)
    }

    /// The other way a machine fails to come back. A standalone VMI is lost to
    /// a reboot; a machine booting from a containerDisk is lost to a stop, and
    /// nothing on the row says so until this does.
    private var ephemeralNote: some View {
        Banner(text: "\(kubevirt.ephemeral) of these boot from a containerDisk. That is an image, not a "
                   + "disk: whatever the machine writes to its root filesystem is discarded when it stops, "
                   + "and Start brings back the image.",
               tone: Theme.muted)
    }

    private func card(_ title: String, badge: String,
                      @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.fg)
                Spacer(minLength: 8)
                Badge(text: badge)
            }
            content()
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
    }

    /// Why the cluster cannot be read at all, when that is the situation.
    ///
    /// A failed probe clears `apiGroups` but leaves `roles` behind, so this tab
    /// stays on screen and `load` takes its "kubevirt.io is not served here"
    /// exit — which empties the list. Without this the screen then reports no
    /// virtual machines on a cluster nobody has heard from, which is a claim
    /// about the cluster rather than about the connection. The reach is the one
    /// fact that separates the two.
    private var unreachable: String? {
        switch store.current?.reach {
        case .unreachable(let why), .unusable(let why): return why
        default: return nil
        }
    }

    private func reload() async {
        guard let cluster = store.current, cluster.roles.contains(.kubevirt) else { return }
        await kubevirt.load(cluster: cluster)
    }
}

/// One machine: what it is, where it is, and what can be done to it.
private struct MachineRow: View {
    let machine: KubeVirt.Machine
    @Environment(ClusterStore.self) private var store
    @Environment(KubeVirtEngine.self) private var kubevirt
    @Environment(Navigator.self) private var navigator
    /// Set by Stop and Restart, which interrupt a running machine. Start is
    /// additive and asks nothing.
    ///
    /// This screen is the second thing in the app that writes to a cluster —
    /// the exporter was the first, and it takes a typed confirmation because
    /// removing it recreates pods. Stopping a tenant VM is at least that
    /// disruptive and the machine cannot be asked whether it minded, so the
    /// verb does not fire straight off a tap.
    @State private var confirming: KubeVirt.Action?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                StatusDot(color: tone, glow: machine.isRunning)
                Text(machine.name).font(Theme.mono(12)).foregroundStyle(Theme.fg)
                Badge(text: machine.state, color: tone)
                if !machine.gpus.isEmpty {
                    Badge(text: machine.gpus.count == 1 ? "GPU" : "\(machine.gpus.count)× GPU",
                          color: Theme.ember)
                }
                // Said only when it is running and the cluster has said no. A
                // passed-through card pins a machine to its node, and that is
                // the fact that matters the day the node has to be drained.
                if machine.isRunning, machine.isLiveMigratable == false {
                    Badge(text: "not migratable", color: Theme.warn)
                }
                Spacer(minLength: 8)
                actions
            }

            // The first line is where and how big, because in a list of
            // machines the comparison is horizontal: which one is on which
            // node, which one got the card. The second is what it is built as.
            Text(facts).font(Theme.mono(11)).foregroundStyle(Theme.muted)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            if !platform.isEmpty {
                Text(platform).font(Theme.mono(11)).foregroundStyle(Theme.faint)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }

            // One line per interface: the binding is the part that says how
            // the packet leaves — a bridge onto a host segment, a masqueraded
            // pod network, a VF the card handed over.
            ForEach(machine.interfaces) { iface in
                HStack(spacing: 8) {
                    Text(iface.name).font(Theme.mono(11)).foregroundStyle(Theme.fg)
                    Badge(text: iface.describedBinding,
                          color: iface.binding == .sriov ? Theme.ember : Theme.muted)
                    Text(iface.network).font(Theme.mono(11)).foregroundStyle(Theme.muted)
                    if !iface.addresses.isEmpty {
                        Text(iface.addresses.joined(separator: ", "))
                            .font(Theme.mono(11)).foregroundStyle(Theme.fg)
                    }
                    if let mac = iface.mac {
                        Text(mac).font(Theme.mono(11)).foregroundStyle(Theme.faint)
                    }
                    if let link = iface.linkState {
                        StatusDot(color: link == "up" ? Theme.ok : Theme.bad, size: 6)
                    }
                    Spacer(minLength: 0)
                }
                .lineLimit(1)
            }

            // One line per disk, and the word "ephemeral" on the ones that
            // keep nothing. The image name is the backing, because on a
            // containerDisk it is the whole of the story.
            ForEach(machine.disks) { disk in
                HStack(spacing: 8) {
                    Text(disk.target ?? disk.kind).font(Theme.mono(11)).foregroundStyle(Theme.fg)
                        .frame(width: 32, alignment: .leading)
                    Text(disk.name).font(Theme.mono(11)).foregroundStyle(Theme.muted)
                    if let bus = disk.bus {
                        Text(bus).font(Theme.mono(11)).foregroundStyle(Theme.faint)
                    }
                    Text(disk.backing).font(Theme.mono(11)).foregroundStyle(Theme.muted)
                        .truncationMode(.middle)
                    if let bytes = disk.bytes {
                        Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary))
                            .font(Theme.mono(11)).foregroundStyle(Theme.faint)
                    }
                    if disk.isEphemeral {
                        Text("ephemeral").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.warn)
                    }
                    Spacer(minLength: 0)
                }
                .lineLimit(1)
            }

            if machine.vmi != nil {
                Button("launcher pod") { revealLauncher() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.primary)
            }

            if let failure = kubevirt.actionFailure, failure.id == machine.id {
                Text(failure.why).font(.system(size: 11.5)).foregroundStyle(Theme.bad)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border))
        // `presenting:` hands the verb to the closures below rather than
        // leaving them to read it back out of `confirming`. Dismissing an alert
        // writes `false` through its own `isPresented` binding, and the setter
        // here clears the verb — so a button action that re-read the state
        // would find nil and send nothing, making Stop and Restart look like
        // buttons that do nothing while Start, which skips the alert, works.
        .alert("\(confirming?.rawValue.capitalized ?? "") \(machine.name)?",
               isPresented: Binding(get: { confirming != nil },
                                    set: { if !$0 { confirming = nil } }),
               presenting: confirming) { action in
            Button("Cancel", role: .cancel) { }
            Button(action.rawValue.capitalized, role: .destructive) { run(action) }
        } message: { action in
            Text(action == .stop
                 ? "The machine is powered off. Anything running on it stops now, and its disks are "
                 + "kept — Start brings it back."
                 : "The machine is powered off and started again. Anything running on it stops now.")
        }
    }

    @ViewBuilder
    private var actions: some View {
        if kubevirt.busy == machine.id {
            ProgressView().controlSize(.small)
        } else if machine.isManageable {
            HStack(spacing: 6) {
                // Declared state, not the instance phase. A machine whose VMI
                // is stuck at `Scheduling` because no node has a free card is
                // declared running and is not running: keying on the phase
                // offers it Start, which the subresource API answers 409, and
                // withholds Stop, which is the verb that unsticks it.
                if machine.isDeclaredRunning {
                    button("Restart", .restart)
                    button("Stop", .stop)
                } else {
                    button("Start", .start)
                }
            }
        } else {
            // Not a disabled button. A greyed-out Start invites a press and
            // then explains nothing; the word says why there is no button.
            Text("standalone VMI").font(.system(size: 11)).foregroundStyle(Theme.faint)
        }
    }

    private func button(_ label: String, _ action: KubeVirt.Action) -> some View {
        Button(label) {
            if action == .start { run(action) } else { confirming = action }
        }
        .buttonStyle(.bordered).controlSize(.small)
        .disabled(kubevirt.busy != nil)
    }

    private func run(_ action: KubeVirt.Action) {
        guard let cluster = store.current else { return }
        Task { await kubevirt.perform(action, on: machine, cluster: cluster) }
    }

    /// The pod that is this machine, opened in Resources — where its logs
    /// and a shell are one tap further.
    private func revealLauncher() {
        guard let cluster = store.current else { return }
        Task {
            if let pod = await kubevirt.launcherPod(of: machine, cluster: cluster) {
                navigator.reveal(pod: pod, namespace: machine.namespace)
            }
        }
    }

    /// `q35 · host-model · 4Gi of 16Gi · up 6h`, or as much of it as is known.
    private var platform: String {
        var parts: [String] = []
        if let type = machine.machineType { parts.append(type) }
        if let model = machine.cpuModel { parts.append(model) }
        if let memory = machine.memory { parts.append(memory) }
        if let since = machine.runningSince, machine.isRunning {
            parts.append("up " + since.formatted(.relative(presentation: .numeric)).replacingOccurrences(of: " ago", with: ""))
        }
        return parts.joined(separator: "  ·  ")
    }

    private var facts: String {
        var parts = [machine.size]
        if let node = machine.node, node != "—" { parts.append("on \(node)") }
        let networks = machine.networks.map(\.described)
        if !networks.isEmpty { parts.append(networks.joined(separator: ", ")) }
        // The device name, not the alias in the manifest: `a4000` is what the
        // author called it, `GA104GL_RTX_A4000` is what they actually got.
        let gpus = machine.gpus.compactMap { $0.deviceName?.split(separator: "/").last.map(String.init) }
        if !gpus.isEmpty { parts.append(gpus.joined(separator: ", ")) }
        return parts.joined(separator: "  ·  ")
    }

    private var tone: Color {
        switch machine.state {
        case "Running":                      return Theme.ok
        case "Failed", "Unknown":            return Theme.bad
        case "Stopped", "Succeeded":         return Theme.muted
        default:                             return Theme.warn
        }
    }
}
