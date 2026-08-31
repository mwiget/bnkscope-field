import SwiftUI
import BNKKit

struct TerminalView: View {
    @Binding var columns: NavigationSplitViewVisibility
    @Environment(ClusterStore.self) private var store
    @Environment(ExecEngine.self) private var exec

    @State private var pod: K8s.Pod?
    /// Only for a typed command; the quick ones use `toolContainer`.
    @State private var container = "debug"
    @State private var input = ""
    @FocusState private var inputFocused: Bool

    /// The diagnostics this exists for.
    ///
    /// Columns were checked against a live tmm pod rather than guessed — the
    /// first set returned "No such column" — and then trimmed to fit 80
    /// characters. `tmctl` wraps its table into stacked blocks beyond that, and
    /// with no TTY there is nothing to tell it otherwise: it has no width flag
    /// and ignores COLUMNS. Fewer columns that read as one table beat more
    /// columns split across two.
    private static let quick: [(String, [String])] = [
        ("cpu", ["tmctl", "-d", "blade", "tmm_stat", "-s", "pid,cpu,polls,idle_polls"]),
        ("connections", ["tmctl", "-d", "blade", "tmm_stat",
                         "-s", "client_side_traffic.cur_conns,client_side_traffic.tot_conns"]),
        ("virtual servers", ["tmctl", "-d", "blade", "virtual_server_stat",
                             "-s", "name,clientside.tot_conns"]),
        ("interfaces", ["tmctl", "-d", "blade", "interface_stat",
                        "-s", "name,counters.bytes_in,counters.bytes_out"]),
        ("memory", ["tmctl", "-d", "blade", "memory_usage_stat", "-s", "name,allocated,size"]),
        ("ip -s link", ["ip", "-s", "link"]),
    ]

    // Pool members are deliberately absent. `pool_name` pads to 63 characters
    // on this cluster, so nothing fits beside it and tmctl stacks the table into
    // blocks — and the same numbers are already a chart on TMM Live. A button
    // that produces a mangled table is worse than no button.

    private var pods: [K8s.Pod] { store.current?.tmmPods ?? [] }

    /// Where the diagnostics live.
    ///
    /// `tmctl` is only in the debug container — running it in `f5-tmm` gives
    /// "executable file not found in $PATH" — so the quick commands go there
    /// whatever the picker says. The picker governs a typed command, which is
    /// the only case where the container is the reader's choice to make.
    private var toolContainer: String {
        let available = pod?.logSources ?? []
        return available.contains("debug") ? "debug" : (available.first ?? "debug")
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Theme.border)
            if store.current == nil {
                Message(title: "No cluster selected",
                        detail: "Pick a cluster in the sidebar to run a diagnostic in one of its TMM pods.")
            } else if pods.isEmpty {
                Message(title: "No f5-tmm pods here",
                        detail: "This screen runs the TMM diagnostics, so it needs a cluster running BNK.")
            } else {
                targetBar
                Divider().overlay(Theme.border)
                output
                Divider().overlay(Theme.border)
                prompt
            }
        }
        .background(Theme.bg)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { if pod == nil { pod = pods.first } }
        .onChange(of: store.selected) { _, _ in pod = pods.first; exec.clear() }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            SidebarToggle(columns: $columns)
            Text("Terminal").font(.system(size: 19, weight: .semibold)).foregroundStyle(Theme.fg).fixedSize()
            Text("exec · v5.channel.k8s.io").font(Theme.mono(11.5)).foregroundStyle(Theme.muted).lineLimit(1)
            Spacer(minLength: 8)
            if exec.running {
                Button("Stop") { exec.cancel() }.buttonStyle(.bordered).controlSize(.small)
            }
            Button("Clear") { exec.clear() }.buttonStyle(.bordered).controlSize(.small)
        }
        .padding(.horizontal, 20).frame(height: 58)
    }

    private var targetBar: some View {
        HStack(spacing: 9) {
            Menu {
                ForEach(pods, id: \.metadata.name) { p in
                    Button(p.metadata.name) { pod = p }
                }
            } label: {
                chip(pod.map { TelemetryEngine.shortPodName($0.metadata.name) } ?? "pod", icon: "chevron.down")
            }
            .menuStyle(.button).buttonStyle(.plain)

            Divider().frame(height: 18).overlay(Theme.border)

            ForEach(Self.quick, id: \.0) { label, command in
                Button { runCommand(command, in: toolContainer) } label: { chip(label) }
                    .buttonStyle(.plain)
                    .disabled(exec.running)
            }
            Text("in \(toolContainer)")
                .font(Theme.mono(10.5)).foregroundStyle(Theme.faint)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20).padding(.vertical, 11)
    }

    private func chip(_ text: String, icon: String? = nil) -> some View {
        HStack(spacing: 6) {
            Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted).lineLimit(1)
            if let icon { Image(systemName: icon).font(.system(size: 10)).foregroundStyle(Theme.faint) }
        }
        .padding(.horizontal, 11).frame(height: 30)
        .background(Theme.secondary, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border))
    }

    private var output: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if exec.runs.isEmpty {
                        Text("Pick a diagnostic above, or type a command.")
                            .font(Theme.mono(12.5)).foregroundStyle(Theme.faint)
                            .padding(.horizontal, 20).padding(.top, 16)
                    }
                    ForEach(exec.runs) { run in
                        RunBlock(run: run).id(run.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(hex: 0x0B0D11))
            .onChange(of: exec.runs.last?.lines.count) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private var prompt: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(pod?.logSources ?? [], id: \.self) { name in
                    Button(name) { container = name }
                }
            } label: {
                chip(container, icon: "chevron.down")
            }
            .menuStyle(.button).buttonStyle(.plain)
            Text("$").font(Theme.mono(13, weight: .semibold)).foregroundStyle(Theme.ok)
            TextField("tmctl -d blade tmm_stat", text: $input)
                .textFieldStyle(.plain)
                .font(Theme.mono(13))
                .foregroundStyle(Theme.fg)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($inputFocused)
                .onSubmit { submit() }
            Button("Run") { submit() }
                .buttonStyle(.borderedProminent)
                .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || exec.running)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(Theme.card)
    }

    private func submit() {
        // Split on whitespace only. There is no shell here to interpret quotes
        // or pipes — the command is handed to the container's exec directly,
        // which is a real limit and better shown than hidden behind a fake one.
        let parts = input.split(separator: " ").map(String.init)
        guard !parts.isEmpty else { return }
        input = ""
        runCommand(parts, in: container)
    }

    private func runCommand(_ command: [String], in container: String) {
        guard let cluster = store.current, let pod,
              let namespace = pod.metadata.namespace,
              let client = try? cluster.client() else { return }
        exec.run(command, container: container, namespace: namespace,
                 pod: pod.metadata.name, client: client)
    }
}

private struct RunBlock: View {
    let run: ExecRun

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text("$").font(Theme.mono(12.5, weight: .semibold)).foregroundStyle(Theme.ok)
                Text(run.command).font(Theme.mono(12.5)).foregroundStyle(Theme.fg)
                Text(run.container).font(Theme.mono(10.5)).foregroundStyle(Theme.faint)
                if !run.finished {
                    ProgressView().controlSize(.mini)
                }
                Spacer(minLength: 0)
            }
            .padding(.bottom, 2)

            ForEach(run.lines) { line in
                Text(line.text.isEmpty ? " " : line.text)
                    .font(Theme.mono(12.5))
                    .foregroundStyle(line.isError ? Theme.warn : Color(hex: 0xB6BCCB))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let failure = run.failure {
                Text(failure)
                    .font(Theme.mono(11.5)).foregroundStyle(Theme.bad)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
    }
}
