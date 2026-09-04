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
                Spacer(minLength: 8)
                actions
            }

            // Everything below the title is one line of facts, because in a
            // list of machines the comparison is horizontal: which one is on
            // which node, which one got the card.
            Text(facts).font(Theme.mono(11)).foregroundStyle(Theme.muted)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)

            if !machine.addresses.isEmpty {
                HStack(spacing: 10) {
                    ForEach(machine.addresses, id: \.ip) { address in
                        Text("\(address.interface) \(address.ip)")
                            .font(Theme.mono(11)).foregroundStyle(Theme.faint)
                    }
                }
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
        .alert("\(confirming?.rawValue.capitalized ?? "") \(machine.name)?",
               isPresented: Binding(get: { confirming != nil },
                                    set: { if !$0 { confirming = nil } })) {
            Button("Cancel", role: .cancel) { confirming = nil }
            Button(confirming?.rawValue.capitalized ?? "", role: .destructive) {
                if let action = confirming { run(action) }
                confirming = nil
            }
        } message: {
            Text(confirming == .stop
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
                if machine.isRunning {
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
