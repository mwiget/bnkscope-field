import SwiftUI
import BNKKit

struct TelemetryView: View {
    @Binding var columns: NavigationSplitViewVisibility
    @Environment(ClusterStore.self) private var store
    @Environment(TelemetryEngine.self) private var engine

    @State private var busy = false
    @State private var confirmingRemoval = false
    @State private var typed = ""
    @State private var report: Report?

    private struct Report: Identifiable {
        let id = UUID()
        let title: String
        let lines: [String]
        let bad: Bool
    }

    private var pods: [K8s.Pod] { store.current?.tmmPods ?? [] }
    private var installations: [Exporter.Installation] { pods.map { Exporter.installation(in: $0) } }
    private var missing: [K8s.Pod] { pods.filter { Exporter.installation(in: $0) == .absent } }
    private var ephemeral: [K8s.Pod] { pods.filter { Exporter.installation(in: $0) == .ephemeral } }
    private var permanentCount: Int {
        installations.filter { if case .permanent = $0 { return true } else { return false } }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Theme.border)
            ScrollView {
                VStack(spacing: 16) {
                    if store.current == nil {
                        Message(title: "No cluster selected",
                                detail: "Pick a cluster in the sidebar to see what telemetry it is carrying.")
                            .frame(minHeight: 300)
                    } else if pods.isEmpty {
                        Message(title: "No f5-tmm pods here",
                                detail: "This cluster has nothing for the exporter to attach to. TMM Live needs a cluster running BNK.")
                            .frame(minHeight: 300)
                    } else {
                        state
                        actions
                        note
                    }
                }
                .padding(20)
            }
        }
        .background(Theme.bg)
        .toolbar(.hidden, for: .navigationBar)
        .alert("Recreate the TMM pods?", isPresented: $confirmingRemoval) {
            TextField("cluster name", text: $typed)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) { typed = "" }
            Button("Recreate pods and remove", role: .destructive) {
                Task { await remove() }
            }
            .disabled(typed != store.current?.displayName)
        } message: {
            Text("An ephemeral container cannot be taken out of a running pod. Removing the exporter means deleting \(ephemeral.count) f5-tmm pod\(ephemeral.count == 1 ? "" : "s") so the operator rebuilds them without it. Dataplane traffic through those pods stops until they are back.\n\nType \(store.current?.displayName ?? "the cluster name") to confirm.")
        }
        .sheet(item: $report) { r in
            VStack(alignment: .leading, spacing: 14) {
                Text(r.title).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.fg)
                ForEach(r.lines, id: \.self) { line in
                    Text(line).font(Theme.mono(12.5))
                        .foregroundStyle(r.bad ? Theme.warn : Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Done") { report = nil }.buttonStyle(.borderedProminent)
            }
            .padding(22)
            .frame(minWidth: 420, minHeight: 240)
            .background(Theme.bg)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            SidebarToggle(columns: $columns)
            Text("Telemetry").font(.system(size: 19, weight: .semibold)).foregroundStyle(Theme.fg)
                .fixedSize()
            if let cluster = store.current {
                Text(cluster.displayName).font(Theme.mono(11.5)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 8)
            if busy { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 20).frame(height: 58)
    }

    // MARK: - What is there

    private var state: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("Exporter").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.fg)
                Text(Exporter.image).font(Theme.mono(11)).foregroundStyle(Theme.faint).lineLimit(1)
                Spacer(minLength: 8)
                Badge(text: "\(pods.count - missing.count)/\(pods.count) pods", color: missing.isEmpty ? Theme.ok : Theme.warn)
            }
            ForEach(Array(zip(pods, installations)), id: \.0.metadata.name) { pod, installation in
                HStack(spacing: 12) {
                    StatusDot(color: installation == .absent ? Theme.warn : Theme.ok,
                              glow: installation != .absent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(pod.metadata.name).font(Theme.mono(12)).foregroundStyle(Theme.fg)
                            .lineLimit(1).truncationMode(.middle)
                        Text(describe(installation)).font(Theme.mono(10.5)).foregroundStyle(Theme.faint)
                    }
                    Spacer(minLength: 8)
                    switch installation {
                    case .permanent:  Badge(text: "in pod template", color: Theme.muted)
                    case .ephemeral:  Badge(text: "ephemeral", color: Theme.warn)
                    case .absent:     Badge(text: "not installed", color: Theme.warn)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Theme.bg, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
    }

    private func describe(_ installation: Exporter.Installation) -> String {
        switch installation {
        case .permanent: return "part of the workload's pod template — survives a restart"
        case .ephemeral: return "attached to the running pod — goes when the pod is recreated"
        case .absent:    return "no exporter, so nothing to scrape here"
        }
    }

    // MARK: - Doing something about it

    /// An optional tuple of `(String, Bool, () -> Void)` here crashed the Swift
    /// 6.3 type checker outright. A named type is clearer anyway.
    private struct Action {
        let label: String
        var destructive = false
        let run: () -> Void
    }

    private var installBlurb: String {
        missing.isEmpty
            ? "Every f5-tmm pod already carries the exporter."
            : "Attaches the exporter to \(missing.count) pod\(missing.count == 1 ? "" : "s") as an ephemeral container. TMM keeps running — nothing restarts. It reads the tmstat segment read-only and serves /metrics, which Field reads back through the apiserver; it pushes nowhere."
    }

    private var actions: some View {
        HStack(alignment: .top, spacing: 16) {
            card(title: "Install", body: installBlurb,
                 action: missing.isEmpty ? nil
                     : Action(label: "Add the exporter") { Task { await install() } })
            card(title: "Remove", body: removeExplanation,
                 action: ephemeral.isEmpty ? nil
                     : Action(label: "Remove…", destructive: true) { typed = ""; confirmingRemoval = true })
        }
    }

    private var removeExplanation: String {
        if !ephemeral.isEmpty {
            return "Recreates \(ephemeral.count) pod\(ephemeral.count == 1 ? "" : "s") so they come back without it. An ephemeral container cannot be taken out in place, and this drops dataplane traffic while the pods restart."
        }
        if permanentCount > 0 {
            return "The exporter here is part of the pod template, so this app cannot remove it: deleting the pods would drop traffic and the exporter would come straight back with the replacements. It has to be removed where it is defined."
        }
        return "Nothing to remove."
    }

    @ViewBuilder
    private func card(title: String, body text: String, action: Action?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.fg)
            Text(text).font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let action {
                Button(action.label) { action.run() }
                    .buttonStyle(.borderedProminent)
                    .tint(action.destructive ? Theme.bad : Theme.primary)
                    .disabled(busy)
            } else {
                Text("Nothing to do").font(.system(size: 12)).foregroundStyle(Theme.faint)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 190, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
    }

    private var note: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle").foregroundStyle(Theme.muted)
            Text("An ephemeral container is not restarted if it exits and is gone when the pod is recreated. Nothing re-adds it. That is the honest shape for a troubleshooting tool rather than a monitoring one, and it is why adding is a click and removing is not.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
    }

    // MARK: - Wiring

    private func install() async {
        guard let cluster = store.current, let client = try? cluster.client() else { return }
        busy = true
        let outcome = await Exporter.install(into: missing, clusterLabel: cluster.displayName, using: client)
        await cluster.probe()
        busy = false
        report = Report(
            title: outcome.failed.isEmpty ? "Exporter added" : "Exporter partly added",
            lines: summarise(outcome, verb: "added to"),
            bad: !outcome.failed.isEmpty)
    }

    private func remove() async {
        guard let cluster = store.current, let client = try? cluster.client() else { return }
        busy = true
        typed = ""
        engine.stop()
        let outcome = await Exporter.remove(from: ephemeral, using: client)
        await cluster.probe()
        busy = false
        report = Report(
            title: outcome.failed.isEmpty ? "Pods recreated" : "Removal incomplete",
            lines: summarise(outcome, verb: "recreated"),
            bad: !outcome.failed.isEmpty)
    }

    private func summarise(_ outcome: Exporter.Outcome, verb: String) -> [String] {
        var lines: [String] = []
        if !outcome.changed.isEmpty { lines.append("\(verb) \(outcome.changed.count) pod(s):\n  " + outcome.changed.joined(separator: "\n  ")) }
        if !outcome.skipped.isEmpty { lines.append("skipped \(outcome.skipped.count), already as wanted") }
        for (pod, reason) in outcome.failed { lines.append("\(pod): \(reason)") }
        return lines.isEmpty ? ["Nothing changed."] : lines
    }
}
