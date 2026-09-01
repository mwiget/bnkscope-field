import SwiftUI
import BNKKit

struct TerminalView: View {
    @Binding var columns: NavigationSplitViewVisibility
    @Environment(ClusterStore.self) private var store
    @Environment(ExecEngine.self) private var exec

    @State private var pod: K8s.Pod?
    @State private var container: String?
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
    private static let debugTools: [(String, [String])] = [
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

    /// The same idea for the routing container, where ZebOS lives.
    ///
    /// `imish` is an interactive shell, and exec here has no TTY: run bare it
    /// would sit waiting for input that can never arrive. `-e` runs one command
    /// and exits, and repeats to build a session — `en` first, because the show
    /// commands worth having need enable.
    private static let routingTools: [(String, [String])] = [
        ("bgp summary", ["imish", "-e", "en", "-e", "show ip bgp summary"]),
        ("bgp neighbors", ["imish", "-e", "en", "-e", "show ip bgp neighbors"]),
        ("routes", ["imish", "-e", "en", "-e", "show ip route bgp"]),
        ("bfd", ["imish", "-e", "en", "-e", "show bfd interface"]),
        ("running-config", ["imish", "-e", "en", "-e", "show running-config bgp"]),
    ]

    /// ZebOS ships as `f5-tmm-routing` on BNK, but the name is matched loosely
    /// rather than pinned: the same container is called zebos or ocnos in other
    /// builds, and a wrong guess here only costs the shortcuts, not the shell.
    private static func isRouting(_ container: String) -> Bool {
        let name = container.lowercased()
        return name.contains("routing") || name.contains("zebos") || name.contains("ocnos")
    }

    private var quick: [(String, [String])] {
        Self.isRouting(toolContainer) ? Self.routingTools : Self.debugTools
    }

    // Pool members are deliberately absent. `pool_name` pads to 63 characters
    // on this cluster, so nothing fits beside it and tmctl stacks the table into
    // blocks — and the same numbers are already a chart on TMM Live. A button
    // that produces a mangled table is worse than no button.

    private var pods: [K8s.Pod] { store.current?.tmmPods ?? [] }

    private var containers: [String] { pod?.logSources ?? [] }

    /// Which container the commands run in.
    ///
    /// This screen used to hard-wire `debug`, on the grounds that `tmctl` lives
    /// only there and a picker would be clutter pretending to be a control.
    /// That held right up until the routing container: `imish` is the ZebOS
    /// shell and exists only in `f5-tmm-routing`, so there is now something
    /// real to choose between and the picker earns its place.
    private var toolContainer: String {
        if let container, containers.contains(container) { return container }
        return containers.contains("debug") ? "debug" : (containers.first ?? "debug")
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
        .noNavigationBar()
        .onAppear { if pod == nil { pod = pods.first } }
        .onChange(of: store.selected) { _, _ in pod = pods.first; container = nil; exec.clear() }
        .onChange(of: pod?.metadata.name) { _, _ in container = nil }
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

            Menu {
                ForEach(containers, id: \.self) { name in
                    Button(name) { container = name }
                }
            } label: {
                chip(toolContainer, icon: containers.count > 1 ? "chevron.down" : nil)
            }
            .menuStyle(.button).buttonStyle(.plain)
            .disabled(containers.count < 2)

            Divider().frame(height: 18).overlay(Theme.border)

            ForEach(quick, id: \.0) { label, command in
                Button { runCommand(command, in: toolContainer) } label: { chip(label) }
                    .buttonStyle(.plain)
                    .disabled(exec.running)
            }
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
            Text(toolContainer)
                .font(Theme.mono(11.5)).foregroundStyle(Theme.faint)
            Text("$").font(Theme.mono(13, weight: .semibold)).foregroundStyle(Theme.ok)
            ZStack(alignment: .leading) {
                // The suggestion is drawn behind the field, with the part
                // already typed rendered clear so its tail begins exactly at
                // the caret rather than near it.
                if let completion {
                    (Text(input).foregroundStyle(.clear) + Text(completion).foregroundStyle(Theme.faint))
                        .font(Theme.mono(13))
                        .lineLimit(1)
                        .allowsHitTesting(false)
                }
                TextField("", text: $input)
                    .textFieldStyle(.plain)
                    .font(Theme.mono(13))
                    .foregroundStyle(Theme.fg)
                    .autocorrectionDisabled()
                    .noAutocaps()
                    .focused($inputFocused)
                    .onSubmit { submit() }
                    .onKeyPress(.tab) {
                        guard completion != nil else { return .ignored }
                        accept()
                        return .handled
                    }
            }

            if completion != nil {
                // Tab is the habit this borrows from, but an iPad without a
                // keyboard has no Tab key, so the hint is also the button.
                Button { accept() } label: {
                    Text("tab ⇥")
                        .font(Theme.mono(10.5, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                        .padding(.horizontal, 7).frame(height: 22)
                        .background(Theme.secondary, in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.border))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Accept the suggested command")
            }

            Button("Run") { submit() }
                .buttonStyle(.borderedProminent)
                .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || exec.running)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(Theme.card)
    }

    /// What Tab would add: the tail of the first suggestion that extends what
    /// has been typed.
    ///
    /// An empty line suggests this container's first diagnostic, which is what
    /// the placeholder used to do — badly. A placeholder cannot be accepted and
    /// disappears at the first keystroke, so it showed a command and then took
    /// it away at the moment the reader tried to use it.
    private var completion: String? {
        if input.isEmpty { return example }
        guard let match = suggestions.first(where: { $0.hasPrefix(input) && $0.count > input.count })
        else { return nil }
        return String(match.dropFirst(input.count))
    }

    /// Commands already run, most recent first, then this container's own
    /// diagnostics. Re-running what was just run is the common case.
    private var suggestions: [String] {
        var seen = Set<String>()
        return (exec.runs.reversed().map(\.command) + quick.map { Argv.join($0.1) })
            .filter { seen.insert($0).inserted }
    }

    private var example: String { Argv.join(quick.first?.1 ?? []) }

    private func accept() {
        guard let completion else { return }
        input += completion
        inputFocused = true
    }

    private func submit() {
        // Quotes are honoured, because imish takes a whole ZebOS command as one
        // argument. Pipes and redirection still are not: there is no shell on
        // the far side of exec, and that is a real limit better shown than
        // hidden behind a fake one.
        let parts = Argv.split(input)
        guard !parts.isEmpty else { return }
        input = ""
        runCommand(parts, in: toolContainer)
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
