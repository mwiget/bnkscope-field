import SwiftUI
import BNKKit

struct ResourcesView: View {
    @Binding var columns: NavigationSplitViewVisibility
    @Environment(ClusterStore.self) private var store
    @Environment(ResourceEngine.self) private var resources
    @Environment(Navigator.self) private var navigator

    @State private var opened: RawObject?

    var body: some View {
        @Bindable var resources = resources
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Theme.border)
            filters
            Divider().overlay(Theme.border)
            content
        }
        .background(Theme.bg)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: "\(store.selected ?? "")#\(store.current?.probeGeneration ?? 0)") { await start() }
        // Another screen may have sent us here to look at one object.
        .task(id: navigator.pending) { await honourRequest() }
        .sheet(item: $opened) { object in
            // A page-sized sheet, not the default card: a pod's event list and
            // its YAML are both things you read, and reading them through a
            // letterbox is worse than not having them.
            ObjectDetail(object: object, kind: resources.kind)
                .presentationSizing(.page)
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.current == nil {
            Message(title: "No cluster selected", detail: "Pick a cluster in the sidebar to browse what is on it.")
        } else if let failure = resources.failure {
            Message(title: "Could not list \(resources.kind.name)", detail: failure, tone: Theme.bad)
        } else if resources.visible.isEmpty {
            Message(title: resources.loading ? "Reading…" : "Nothing here",
                    detail: resources.query.isEmpty
                        ? "No \(resources.kind.name.lowercased()) in this namespace."
                        : "Nothing matches “\(resources.query)”.")
        } else {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(resources.visible) { object in
                        Button { opened = object } label: {
                            ResourceRow(object: object, kind: resources.kind,
                                        showNamespace: resources.namespace == nil)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
            }
        }
    }

    private var toolbar: some View {
        @Bindable var resources = resources
        return HStack(spacing: 12) {
            SidebarToggle(columns: $columns)
            Text("Resources").font(.system(size: 19, weight: .semibold)).foregroundStyle(Theme.fg).fixedSize()
            Text("\(resources.visible.count) of \(resources.objects.count)")
                .font(Theme.mono(11.5)).foregroundStyle(Theme.muted)
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(Theme.muted)
                TextField("Search", text: $resources.query)
                    .textFieldStyle(.plain).font(Theme.mono(12.5)).foregroundStyle(Theme.fg)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    .frame(width: 180)
            }
            .padding(.horizontal, 12).frame(height: 32)
            .background(Theme.secondary, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
            if resources.loading { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 20).frame(height: 58)
    }

    private var filters: some View {
        HStack(spacing: 9) {
            Menu {
                ForEach(ResourceKind.all) { kind in
                    Button(kind.name) {
                        resources.kind = kind
                        Task { await reload() }
                    }
                }
            } label: { chip(resources.kind.name, icon: "chevron.down", active: true) }
            .menuStyle(.button).buttonStyle(.plain)

            if resources.kind.namespaced {
                Menu {
                    Button("All namespaces") { resources.namespace = nil; Task { await reload() } }
                    Divider()
                    ForEach(resources.namespaces, id: \.self) { ns in
                        Button(ns) { resources.namespace = ns; Task { await reload() } }
                    }
                } label: {
                    chip(resources.namespace ?? "all namespaces", icon: "chevron.down",
                         active: resources.namespace != nil)
                }
                .menuStyle(.button).buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            Button("Reload") { Task { await reload() } }
                .buttonStyle(.bordered).controlSize(.small).disabled(resources.loading)
        }
        .padding(.horizontal, 20).padding(.vertical, 11)
    }

    private func chip(_ text: String, icon: String? = nil, active: Bool = false) -> some View {
        HStack(spacing: 6) {
            Text(text).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(active ? Color(hex: 0xA9C4FC) : Theme.muted).lineLimit(1)
            if let icon { Image(systemName: icon).font(.system(size: 10)).foregroundStyle(Theme.faint) }
        }
        .padding(.horizontal, 11).frame(height: 30)
        .background(active ? Theme.primary.opacity(0.12) : Theme.secondary, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .strokeBorder(active ? Theme.primary.opacity(0.35) : Theme.border))
    }

    private func start() async {
        guard let cluster = store.current else { return }
        await resources.loadNamespaces(cluster)
        // A pending request decides what to load; loading the default first
        // would be a wasted round trip and a visible flicker.
        if navigator.pending == nil { await resources.load(cluster) }
    }

    /// Show the object another screen asked for, and open it.
    ///
    /// Without this, Overview could name a broken pod and do nothing about it —
    /// which is the state the screen was in when someone asked how to open one.
    private func honourRequest() async {
        guard let request = navigator.pending, let cluster = store.current else { return }
        if let kind = ResourceKind.all.first(where: { $0.plural == request.kind }) {
            resources.kind = kind
        }
        resources.namespace = request.namespace
        resources.query = ""
        await resources.load(cluster)
        opened = resources.objects.first { $0.name == request.name }
        navigator.clear()
    }

    private func reload() async {
        guard let cluster = store.current else { return }
        await resources.load(cluster)
    }
}

private struct ResourceRow: View {
    let object: RawObject
    let kind: ResourceKind
    let showNamespace: Bool

    var body: some View {
        let summary = ResourceSummary.line(for: object, kind: kind)
        HStack(spacing: 12) {
            StatusDot(color: tone(summary.tone), glow: false, size: 7)
            Text(object.name)
                .font(Theme.mono(12.5)).foregroundStyle(Theme.fg)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 340, alignment: .leading)
            if showNamespace, let namespace = object.namespace {
                Text(namespace).font(Theme.mono(11)).foregroundStyle(Theme.faint)
                    .frame(width: 150, alignment: .leading).lineLimit(1)
            }
            Text(summary.text)
                .font(Theme.mono(11.5))
                .foregroundStyle(summary.tone == .bad ? Theme.warn : Theme.muted)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            if let created = object.created {
                Text(created, format: .relative(presentation: .numeric))
                    .font(Theme.mono(11)).foregroundStyle(Theme.faint).lineLimit(1)
            }
            Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(Theme.faint)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border))
        .contentShape(Rectangle())
    }

    private func tone(_ tone: SummaryTone) -> Color {
        switch tone {
        case .good:    return Theme.ok
        case .bad:     return Theme.warn
        case .neutral: return Theme.muted
        }
    }
}

/// One object, close up: what is wrong with it, then what it says it is.
private struct ObjectDetail: View {
    let object: RawObject
    let kind: ResourceKind

    @Environment(\.dismiss) private var dismiss
    @Environment(ClusterStore.self) private var store
    @Environment(ResourceEngine.self) private var resources
    @State private var tab = Tab.events

    enum Tab: String, CaseIterable { case events = "Events", yaml = "YAML" }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(object.name).font(Theme.mono(14, weight: .semibold)).foregroundStyle(Theme.fg)
                        .lineLimit(1).truncationMode(.middle)
                    Text([kind.name, object.namespace].compactMap { $0 }.joined(separator: " · "))
                        .font(Theme.mono(11)).foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 8)
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).frame(width: 190)
                Button("Done") { dismiss() }.buttonStyle(.bordered)
            }
            .padding(.horizontal, 20).frame(height: 60)
            Divider().overlay(Theme.border)

            switch tab {
            case .events: events
            case .yaml:   yaml
            }
        }
        .background(Theme.bg)
        .task { await loadEvents() }
    }

    private var events: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                if resources.events.isEmpty {
                    Text(resources.loadingEvents ? "Reading…" : "Nothing has been said about this object.")
                        .font(.system(size: 13)).foregroundStyle(Theme.muted).padding(.top, 40)
                }
                ForEach(resources.events, id: \.metadata.name) { event in
                    HStack(alignment: .top, spacing: 11) {
                        Image(systemName: event.type == "Warning" ? "exclamationmark.triangle" : "info.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(event.type == "Warning" ? Theme.warn : Theme.muted)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Text(event.reason ?? "—").font(Theme.mono(12)).foregroundStyle(Theme.fg)
                                if let count = event.count, count > 1 {
                                    Badge(text: "×\(count)", color: Theme.muted)
                                }
                                Spacer(minLength: 0)
                                if let at = event.at {
                                    Text(at, format: .relative(presentation: .numeric))
                                        .font(Theme.mono(10.5)).foregroundStyle(Theme.faint)
                                }
                            }
                            Text(OverviewEngine.tidy(event.message ?? ""))
                                .font(.system(size: 12)).foregroundStyle(Theme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(13)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border))
                }
            }
            .padding(20)
        }
    }

    private var yaml: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(object.yaml)
                .font(Theme.mono(11.5))
                .foregroundStyle(Color(hex: 0xB6BCCB))
                .textSelection(.enabled)
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(hex: 0x0B0D11))
    }

    private func loadEvents() async {
        guard let cluster = store.current else { return }
        await resources.loadEvents(for: object, cluster: cluster)
    }
}
