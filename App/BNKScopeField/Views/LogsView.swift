import SwiftUI
import BNKKit

struct LogsView: View {
    @Binding var columns: NavigationSplitViewVisibility
    @Environment(ClusterStore.self) private var store
    @Environment(LogsEngine.self) private var logs

    @State private var namespace: String?
    @State private var namespaces: [String] = []
    @State private var loading = false

    var body: some View {
        @Bindable var logs = logs
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Theme.border)
            filters
            Divider().overlay(Theme.border)
            body(for: logs)
        }
        .background(Theme.bg)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: store.selected) { await discoverNamespaces() }
    }

    @ViewBuilder
    private func body(for logs: LogsEngine) -> some View {
        if store.current == nil {
            Message(title: "No cluster selected",
                    detail: "Pick a cluster in the sidebar to follow its logs.")
        } else if namespace == nil {
            Message(title: loading ? "Reading namespaces…" : "Pick a namespace",
                    detail: "Field follows every container in one namespace at a time, straight off the apiserver. Nothing is installed to make that work.")
        } else if logs.visible.isEmpty {
            Message(title: logs.isRunning ? "Waiting for output" : "Not following",
                    detail: logs.lines.isEmpty
                        ? "Following \(logs.following.count) container\(logs.following.count == 1 ? "" : "s"). Nothing has been logged yet."
                        : "\(logs.lines.count) lines held, none match the filter.")
        } else {
            lineList(logs)
        }
    }

    private func lineList(_ logs: LogsEngine) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(logs.visible) { line in
                    LogRow(line: line) { container in logs.toggleMute(container) }
                }
            }
        }
    }

    // MARK: - Chrome

    private var toolbar: some View {
        @Bindable var logs = logs
        return HStack(spacing: 12) {
            SidebarToggle(columns: $columns)
            Text("Logs").font(.system(size: 19, weight: .semibold)).foregroundStyle(Theme.fg).fixedSize()
            if !logs.following.isEmpty {
                Text("\(logs.following.count) containers")
                    .font(Theme.mono(11.5)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 8)
            searchField
            if logs.isRunning {
                Pill(text: "TAILING", tone: .live)
            }
        }
        .padding(.horizontal, 20).frame(height: 58)
    }

    private var searchField: some View {
        @Bindable var logs = logs
        return HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(Theme.muted)
            TextField("Search", text: $logs.query)
                .textFieldStyle(.plain)
                .font(Theme.mono(12.5))
                .foregroundStyle(Theme.fg)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .frame(width: 200)
            if !logs.query.isEmpty {
                Button { logs.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(Theme.faint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).frame(height: 32)
        .background(Theme.secondary, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
    }

    private var filters: some View {
        @Bindable var logs = logs
        return HStack(spacing: 9) {
            Menu {
                ForEach(namespaces, id: \.self) { ns in
                    Button(ns) { namespace = ns; Task { await follow(ns) } }
                }
            } label: {
                chip(namespace ?? "namespace", icon: "chevron.down", active: namespace != nil)
            }
            .menuStyle(.button).buttonStyle(.plain)

            ForEach(LogLine.Level.allCases, id: \.self) { level in
                Button {
                    if logs.levels.contains(level) { logs.levels.remove(level) } else { logs.levels.insert(level) }
                } label: {
                    chip(level.rawValue, tint: colour(level), active: logs.levels.contains(level))
                }
                .buttonStyle(.plain)
            }

            Menu {
                if !logs.muted.isEmpty {
                    Button("Unmute all") { logs.muted.removeAll() }
                    Divider()
                }
                ForEach(logs.sources, id: \.container) { source in
                    Button {
                        logs.toggleMute(source.container)
                    } label: {
                        Label("\(source.container) — \(source.lines)",
                              systemImage: logs.muted.contains(source.container) ? "speaker.slash" : "checkmark")
                    }
                }
            } label: {
                chip(logs.muted.isEmpty ? "sources" : "\(logs.muted.count) muted",
                     icon: "chevron.down", active: !logs.muted.isEmpty)
            }
            .menuStyle(.button).buttonStyle(.plain)

            if logs.dropped > 0 {
                Text("\(logs.dropped) more containers not followed")
                    .font(Theme.mono(11)).foregroundStyle(Theme.warn)
            }
            Spacer(minLength: 8)
            Text("\(logs.visible.count) of \(logs.lines.count)")
                .font(Theme.mono(11)).foregroundStyle(Theme.faint)
            Button("Clear") { logs.clear() }
                .buttonStyle(.bordered).controlSize(.small)
        }
        .padding(.horizontal, 20).padding(.vertical, 11)
    }

    private func chip(_ text: String, icon: String? = nil, tint: Color? = nil, active: Bool = false) -> some View {
        HStack(spacing: 6) {
            if let tint { Circle().fill(tint).frame(width: 6, height: 6) }
            Text(text).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(active ? Color(hex: 0xA9C4FC) : Theme.muted)
            if let icon { Image(systemName: icon).font(.system(size: 10)).foregroundStyle(Theme.muted) }
        }
        .padding(.horizontal, 11).frame(height: 30)
        .background(active ? Theme.primary.opacity(0.12) : Theme.secondary, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .strokeBorder(active ? Theme.primary.opacity(0.35) : Theme.border))
    }

    private func colour(_ level: LogLine.Level) -> Color {
        switch level {
        case .error:   return Theme.bad
        case .warning: return Theme.warn
        case .info:    return Theme.muted
        }
    }

    // MARK: - Wiring

    private func discoverNamespaces() async {
        logs.stop()
        logs.clear()
        namespace = nil
        namespaces = []
        guard let cluster = store.current, let client = try? cluster.client() else { return }
        loading = true
        namespaces = (try? await client.namespaces()) ?? []
        loading = false
        // Start where the interesting pods are rather than at whatever sorts
        // first alphabetically.
        if let tmmNamespace = cluster.tmmPods.first?.metadata.namespace,
           namespaces.contains(tmmNamespace) {
            namespace = tmmNamespace
            await follow(tmmNamespace)
        }
    }

    private func follow(_ ns: String) async {
        guard let cluster = store.current, let client = try? cluster.client() else { return }
        logs.clear()
        let pods = (try? await client.pods(namespace: ns)) ?? []
        logs.start(client: client, namespace: ns, pods: pods)
    }
}

private struct LogRow: View {
    let line: LogLine
    var onMuteContainer: (String) -> Void = { _ in }
    @State private var expanded = false

    private var colour: Color {
        switch line.level {
        case .error:   return Theme.bad
        case .warning: return Theme.warn
        case .info:    return Theme.fg
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(line.at.map { $0.formatted(.dateTime.hour().minute().second()) } ?? "—")
                .font(Theme.mono(11.5)).foregroundStyle(Theme.faint)
                .frame(width: 68, alignment: .leading)
            Button {
                if let c = line.container { onMuteContainer(c) }
            } label: {
                Text(line.container ?? "—")
                    .font(Theme.mono(11)).foregroundStyle(Theme.muted)
                    .frame(width: 120, alignment: .leading).lineLimit(1).truncationMode(.middle)
            }
            .buttonStyle(.plain)
            .help("Mute this container")
            Text(line.pod)
                .font(Theme.mono(11)).foregroundStyle(Theme.faint)
                .frame(width: 150, alignment: .leading).lineLimit(1).truncationMode(.middle)
            // Capped, because a single openflow dump runs to twenty lines and
            // pushes everything around it off the screen. Tap to see all of it.
            Text(line.text)
                .font(Theme.mono(11.5)).foregroundStyle(colour)
                .textSelection(.enabled)
                .lineLimit(expanded ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.snappy(duration: 0.18)) { expanded.toggle() } }
        }
        .padding(.horizontal, 20).padding(.vertical, 5)
        .background(line.level == .error ? Theme.bad.opacity(0.05) : .clear)
    }
}
