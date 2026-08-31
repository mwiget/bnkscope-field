import SwiftUI
import BNKKit

/// The exporter's state, and what can be done about it, on the screen that
/// depends on it.
///
/// This used to be a separate Telemetry item in the menu, which put a thing you
/// configure beside seven things you look at. Worse, it split one subject in
/// two: TMM Live listed which pods carried the exporter and could do nothing,
/// while another screen could act but showed no graphs. The state and the
/// actions belong together, on the screen that is empty without them.
struct ExporterPanel: View {
    enum Style {
        /// The full targets list, shown under a working dashboard.
        case card
        /// The whole screen, when there is nothing to scrape yet.
        case prompt
    }

    let style: Style
    @Environment(ClusterStore.self) private var store
    @Environment(TelemetryEngine.self) private var engine

    @State private var busy = false
    @State private var confirmingRemoval = false
    @State private var typed = ""
    @State private var owners: [String] = []
    @State private var report: Report?

    struct Report: Identifiable {
        let id = UUID()
        let title: String
        let lines: [String]
        let bad: Bool
    }

    private var pods: [K8s.Pod] { store.current?.tmmPods ?? [] }
    private var missing: [K8s.Pod] { pods.filter { Exporter.installation(in: $0) == .absent } }
    private var ephemeral: [K8s.Pod] { pods.filter { Exporter.installation(in: $0) == .ephemeral } }
    private var permanent: [K8s.Pod] {
        pods.filter { if case .permanent = Exporter.installation(in: $0) { return true } else { return false } }
    }

    var body: some View {
        Group {
            switch style {
            case .card:   targetsCard
            case .prompt: installPrompt
            }
        }
        .task(id: "\(store.selected ?? "")#\(store.current?.probeGeneration ?? 0)") { await findOwners() }
        .alert("Recreate the TMM pods?", isPresented: $confirmingRemoval) {
            TextField("cluster name", text: $typed)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Cancel", role: .cancel) { typed = "" }
            Button("Recreate pods and remove", role: .destructive) { Task { await remove() } }
                .disabled(typed != store.current?.displayName)
        } message: {
            Text("An ephemeral container cannot be taken out of a running pod. Removing the exporter means deleting \(ephemeral.count) f5-tmm pod\(ephemeral.count == 1 ? "" : "s") so they are rebuilt without it. Dataplane traffic through those pods stops until they are back.\n\nType \(store.current?.displayName ?? "the cluster name") to confirm.")
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
            .padding(22).frame(minWidth: 420, minHeight: 220).background(Theme.bg)
        }
    }

    // MARK: - The empty case

    private var installPrompt: some View {
        VStack(spacing: 14) {
            Text("Nothing to scrape here")
                .font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.fg)
            Text("\(pods.count) f5-tmm pod\(pods.count == 1 ? "" : "s") on this cluster, none carrying the exporter. Adding it attaches an ephemeral container that reads the tmstat segment read-only and serves /metrics. TMM keeps running — nothing restarts.")
                .font(.system(size: 13)).foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center).frame(maxWidth: 470)
            Button(busy ? "Adding…" : "Add the exporter") { Task { await install() } }
                .buttonStyle(.borderedProminent).disabled(busy)
            Text("It is gone again when a pod is recreated, and nothing re-adds it.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.faint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }

    // MARK: - The working case

    private var targetsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Exporter targets").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.fg)
                Text("tmm-stat-exporter").font(Theme.mono(11)).foregroundStyle(Theme.muted)
                Spacer(minLength: 8)
                actions
            }
            ForEach(pods, id: \.metadata.name) { pod in
                TargetRow(pod: pod, status: engine.podStatus[pod.metadata.name])
            }
            if !permanent.isEmpty {
                Text(owners.isEmpty
                     ? "Defined in the workload's pod template, so this app cannot remove it."
                     : "Defined in \(owners.joined(separator: ", ")) — removing it means editing that, not deleting pods.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
    }

    @ViewBuilder
    private var actions: some View {
        if busy {
            ProgressView().controlSize(.small)
        } else {
            if !missing.isEmpty {
                Button("Add to \(missing.count) pod\(missing.count == 1 ? "" : "s")") { Task { await install() } }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
            if !ephemeral.isEmpty {
                Button("Remove…") { typed = ""; confirmingRemoval = true }
                    .buttonStyle(.bordered).controlSize(.small).tint(Theme.bad)
            }
        }
    }

    // MARK: - Doing it

    private func install() async {
        guard let cluster = store.current, let client = try? cluster.client() else { return }
        busy = true
        let outcome = await Exporter.install(into: missing, clusterLabel: cluster.displayName, using: client)
        await cluster.probe()
        busy = false
        report = Report(title: outcome.failed.isEmpty ? "Exporter added" : "Exporter partly added",
                        lines: summarise(outcome, verb: "added to"), bad: !outcome.failed.isEmpty)
    }

    private func remove() async {
        guard let cluster = store.current, let client = try? cluster.client() else { return }
        busy = true
        typed = ""
        engine.stop()
        let outcome = await Exporter.remove(from: ephemeral, using: client)
        await cluster.probe()
        busy = false
        report = Report(title: outcome.failed.isEmpty ? "Pods recreated" : "Removal incomplete",
                        lines: summarise(outcome, verb: "recreated"), bad: !outcome.failed.isEmpty)
    }

    private func findOwners() async {
        owners = []
        guard let cluster = store.current, let client = try? cluster.client() else { return }
        var found: Set<String> = []
        for pod in permanent {
            if let owner = await Exporter.owner(of: pod, using: client) { found.insert(owner) }
        }
        owners = found.sorted()
    }

    private func summarise(_ outcome: Exporter.Outcome, verb: String) -> [String] {
        var lines: [String] = []
        if !outcome.changed.isEmpty {
            lines.append("\(verb) \(outcome.changed.count) pod(s):\n  " + outcome.changed.joined(separator: "\n  "))
        }
        if !outcome.skipped.isEmpty { lines.append("skipped \(outcome.skipped.count), already as wanted") }
        for (pod, reason) in outcome.failed { lines.append("\(pod): \(reason)") }
        return lines.isEmpty ? ["Nothing changed."] : lines
    }
}

/// One exporter target: whether it is answering, and how it got there.
private struct TargetRow: View {
    let pod: K8s.Pod
    let status: TelemetryEngine.PodStatus?

    var body: some View {
        HStack(spacing: 12) {
            StatusDot(color: dot, glow: { if case .answering = status { true } else { false } }())
            VStack(alignment: .leading, spacing: 3) {
                Text(pod.metadata.name).font(Theme.mono(12)).foregroundStyle(Theme.fg)
                    .lineLimit(1).truncationMode(.middle)
                Text(detail).font(Theme.mono(10.5))
                    .foregroundStyle({ if case .failing = status { Theme.warn } else { Theme.faint } }())
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 8)
            Text(pod.node).font(Theme.mono(11.5)).foregroundStyle(Theme.muted)
                .lineLimit(1).truncationMode(.middle)
            if Exporter.installation(in: pod) == .ephemeral {
                Badge(text: "ephemeral", color: Theme.warn)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border))
    }

    private var dot: Color {
        switch status {
        case .answering: return Theme.ok
        case .failing:   return Theme.bad
        case nil:        return Exporter.installation(in: pod) == .absent ? Theme.warn : Theme.muted
        }
    }

    private var detail: String {
        switch status {
        case .answering(let n):
            return "\(n) samples · \(Exporter.runningImage(in: pod) ?? "exporter")"
        case .failing(let why):
            return why
        case nil:
            return Exporter.installation(in: pod) == .absent
                ? "no exporter in this pod"
                : (Exporter.runningImage(in: pod) ?? "exporter present, not scraped yet")
        }
    }
}
