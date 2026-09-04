import SwiftUI
import UniformTypeIdentifiers

enum Section: String, CaseIterable, Identifiable {
    case overview = "Overview"
    /// The cluster itself: how it is reached, what it is, and the way to forget
    /// it. First under every cluster, because it is where "Open" lands.
    case cluster  = "Cluster"
    case tmmLive  = "TMM Live"
    case resources = "Resources"
    case logs = "Logs"
    case dpu = "DPU Services"
    case nico = "NICo"
    case kubevirt = "KubeVirt"
    case terminal = "Terminal"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .cluster:  return "server.rack"
        case .tmmLive:  return "waveform.path.ecg"
        case .resources: return "list.bullet.rectangle"
        case .logs: return "text.alignleft"
        case .dpu: return "point.3.connected.trianglepath.dotted"
        case .nico: return "network"
        case .kubevirt: return "macwindow.on.rectangle"
        case .terminal: return "apple.terminal"
        }
    }

    /// Whether this screen exists on a given cluster.
    ///
    /// NICo, DPU and KubeVirt appear only on a cluster running them — the same
    /// shape as bnkscope's tab, and better than a screen that is permanently
    /// empty on most clusters. Overview is nobody's: it reads every cluster.
    @MainActor func isAvailable(on cluster: ManagedCluster) -> Bool {
        // A cluster the app cannot talk to has one screen: the one that says
        // why, and offers to forget it.
        guard cluster.isUsable else { return self == .cluster }
        switch self {
        case .overview: return false
        case .nico:     return cluster.roles.contains(.nico)
        case .dpu:      return cluster.roles.contains(.dpu)
        case .kubevirt: return cluster.roles.contains(.kubevirt)
        default:        return true
        }
    }

    /// The screens one cluster offers, in sidebar order.
    @MainActor static func available(on cluster: ManagedCluster) -> [Section] {
        allCases.filter { $0.isAvailable(on: cluster) }
    }
}

struct RootView: View {
    @Environment(ClusterStore.self) private var store
    @Environment(TelemetryEngine.self) private var engine
    @Environment(Navigator.self) private var navigator
    /// `.automatic`, not `.all`.
    ///
    /// Pinning it open keeps a 268 pt sidebar in a window that may be 400 pt
    /// wide, which is what made the app look like it had not adapted: the split
    /// view was never allowed to collapse the sidebar into a slide-over the way
    /// it does at narrow widths. On iPadOS a window is any size the user drags
    /// it to, so the split view has to be trusted to make that call.
    @State private var columns = NavigationSplitViewVisibility.automatic

    /// Below this the sidebar costs more than it gives: 268 pt of chrome plus a
    /// detail column too narrow for two chart panels side by side.
    private static let sidebarWidthThreshold: CGFloat = 900

    var body: some View {
        GeometryReader { geometry in
            split
                // Fires only when the window crosses the threshold, not on every
                // pixel of a drag, so a deliberate toggle survives until the
                // window actually changes shape. `.automatic` alone gets this
                // wrong on a 13-inch in portrait: it hides a sidebar there is
                // ample room for.
                .onChange(of: geometry.size.width >= Self.sidebarWidthThreshold, initial: true) { _, wide in
                    withAnimation(.snappy(duration: 0.25)) {
                        columns = wide ? .all : .detailOnly
                    }
                }
        }
    }

    private var split: some View {
        NavigationSplitView(columnVisibility: $columns) {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 260, ideal: 268, max: 320)
        } detail: {
            Group {
                switch navigator.section {
                case .tmmLive:             TMMLiveView(columns: $columns)
                case .logs:                LogsView(columns: $columns)
                case .dpu:                 DPUView(columns: $columns)
                case .nico:                NICoView(columns: $columns)
                case .kubevirt:            KubeVirtView(columns: $columns)
                case .terminal:            TerminalView(columns: $columns)
                case .overview:            OverviewView(columns: $columns)
                case .cluster:             ClusterView(columns: $columns)
                case .resources:           ResourcesView(columns: $columns)
                }
            }
            .background(Theme.bg)
            // The screen is checked against the cluster here, where every way
            // the pair can change passes, and not only in the sidebar's own
            // tap. Probe-all and remove move the selection without it, and a
            // re-probe can take away the role a screen depends on; either
            // left the detail showing a screen the cluster does not have.
            .onChange(of: "\(store.selected ?? "")#\(store.current?.probeGeneration ?? 0)", initial: true) { _, _ in
                if let cluster = store.current, navigator.section != .overview,
                   !navigator.section.isAvailable(on: cluster) {
                    navigator.section = .cluster
                }
            }
            // Here rather than on the sidebar, which is what offers the import:
            // below 900 pt the sidebar is collapsed away and an alert on a view
            // that is not in the hierarchy never shows. The detail column is
            // always there.
            .alert("Could not import that file",
                   isPresented: Binding(get: { store.importError != nil },
                                        set: { if !$0 { store.importError = nil } }),
                   presenting: store.importError) { _ in
                Button("OK", role: .cancel) { }
            } message: { why in
                Text(why)
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
}

private struct Sidebar: View {

    #if os(macOS)
    static let wordmarkAlignment: Alignment = .leading
    #else
    static let wordmarkAlignment: Alignment = .trailing
    #endif

    @Environment(ClusterStore.self) private var store
    @Environment(Navigator.self) private var navigator
    @State private var importing = false
    @State private var probing = false
    /// The selected cluster, when its sections have been folded away.
    ///
    /// Only the selected cluster is ever open — one list of screens at a time,
    /// under the cluster they belong to — so this is a single id rather than a
    /// set, and it forgets itself the moment the selection moves.
    @State private var folded: ManagedCluster.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                BNKMark(size: 28)
                Text("bnkscope")
                    .font(.system(size: 16.5, weight: .semibold))
                    .foregroundStyle(Theme.fg)
                Text("FIELD")
                    .font(Theme.mono(9.5, weight: .bold))
                    .kerning(0.9)
                    .foregroundStyle(Theme.ember)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Theme.ember.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.ember.opacity(0.25)))
            }
            // Trailing on iPadOS, leading on macOS, and the difference is not
            // taste. In a window rather than full screen, iPadOS draws its
            // close/minimise/resize controls over the top-left corner and does
            // not inset the content to make room. Centring was tried and is not
            // enough: the row is about 180 pt wide in a 268 pt column, so the
            // mark still lands under the controls. The trailing edge is the one
            // position that clears them whatever their width.
            //
            // A Mac puts its controls in a real title bar, above the content
            // rather than on top of it, so there is nothing to dodge and the
            // wordmark belongs where the eye looks for it.
            .frame(maxWidth: .infinity, alignment: Self.wordmarkAlignment)
            .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 14)

            // One outline. Overview stands alone at the top because it is the
            // only screen that reads every cluster; everything else is a screen
            // *of* a cluster, and sits under the cluster it is of. That is what
            // lets a cluster's screens differ — KubeVirt under one, NICo under
            // another — without the list above the cluster rewriting itself
            // every time the selection below it changed.
            ScrollView {
                VStack(spacing: 2) {
                    SectionRow(section: .overview, active: navigator.section == .overview) {
                        navigator.section = .overview
                    }

                    Divider().overlay(Theme.border).padding(.horizontal, 6).padding(.vertical, 10)

                    ForEach(store.clusters) { cluster in
                        ClusterGroup(cluster: cluster,
                                     selected: store.selected == cluster.id,
                                     expanded: store.selected == cluster.id && folded != cluster.id,
                                     active: navigator.section,
                                     header: { headerTapped(cluster) },
                                     open: { select(cluster, section: $0) })
                    }
                }
                .padding(.horizontal, 10)
            }
            .scrollBounceBehavior(.basedOnSize)

            Spacer(minLength: 0)

            Divider().overlay(Theme.border)
            HStack(spacing: 8) {
                Button { importing = true } label: {
                    ViewThatFits(in: .horizontal) {
                        Label("Import kubeconfig", systemImage: "plus")
                        Label("Import", systemImage: "plus")
                    }
                    .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .accessibilityLabel("Import kubeconfig")

                Button {
                    probing = true
                    Task { await store.probeAll(); probing = false }
                } label: {
                    Label(probing ? "Probing…" : "Probe all", systemImage: "wifi")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(probing || store.clusters.isEmpty)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card)
        .noNavigationBar()
        // Whatever moved the selection — this sidebar, Overview's Open, a
        // probe-all's second guess — the new cluster opens. A fold belongs to
        // the cluster it was made on, not to whichever comes next.
        .onChange(of: store.selected) { _, _ in folded = nil }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.yaml, .text, .data],
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls { store.importKubeconfig(from: url) }
            Task { await store.probeAll() }
        }
    }

    /// A tap on the cluster's own row.
    ///
    /// The first tap takes you there; a second folds it. Except from Overview,
    /// where the cluster is selected but nothing of it is on screen — there a
    /// tap on the selected cluster should still open it, not hide its screens.
    private func headerTapped(_ cluster: ManagedCluster) {
        guard store.selected == cluster.id else { return select(cluster) }
        if navigator.section == .overview {
            folded = nil
            navigator.section = .cluster
        } else {
            folded = folded == cluster.id ? nil : cluster.id
        }
    }

    /// Make this the cluster the screens are about.
    ///
    /// The screen stays put when it can: switching from one cluster's Logs to
    /// another's is one tap, which is the thing a per-cluster sidebar would
    /// otherwise cost. It moves only when it has to — off Overview, which is
    /// not a screen of any cluster, or off a screen this cluster does not have.
    private func select(_ cluster: ManagedCluster, section: Section? = nil) {
        store.selected = cluster.id
        folded = nil
        if let section {
            navigator.section = section
        } else if !navigator.section.isAvailable(on: cluster) {
            navigator.section = .cluster
        }
    }
}

/// One screen in the outline: Overview at the top, or a cluster's screen under it.
private struct SectionRow: View {
    let section: Section
    let active: Bool
    var indented = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: section.symbol)
                    .font(.system(size: indented ? 13 : 15, weight: .medium))
                    .frame(width: 18)
                Text(section.rawValue)
                    .font(.system(size: indented ? 13 : 14, weight: active ? .semibold : .medium))
                Spacer()
            }
            .foregroundStyle(active ? Color(hex: 0xDFE7F7) : Theme.fg)
            .padding(.leading, indented ? 26 : 11).padding(.trailing, 11)
            .frame(height: indented ? 32 : 38)
            .background(active ? Theme.primary.opacity(0.12) : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

/// A cluster and, when it is the selected one, the screens it has.
private struct ClusterGroup: View {
    let cluster: ManagedCluster
    let selected: Bool
    let expanded: Bool
    let active: Section
    let header: () -> Void
    let open: (Section) -> Void

    var body: some View {
        VStack(spacing: 2) {
            // Selectable even when unusable: the row cannot open a cluster the
            // app cannot talk to, but it can open the screen that says why and
            // has the Remove button — which was otherwise reachable only from
            // Overview.
            Button(action: header) {
                ClusterRow(cluster: cluster, selected: selected, expanded: expanded)
            }
            .buttonStyle(.plain)

            if expanded {
                ForEach(Section.available(on: cluster)) { item in
                    SectionRow(section: item, active: active == item, indented: true) { open(item) }
                }
            }
        }
    }
}

private struct ClusterRow: View {
    let cluster: ManagedCluster
    let selected: Bool
    let expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                // The disclosure is drawn, not pressed: the whole row is the
                // button, and a second tap on the selected row is what folds it.
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.faint)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 10)
                    // The demo driver finds a cluster row by the prefix of its
                    // label, which is the row's text run together. A symbol
                    // at the front would put its own name there first.
                    .accessibilityHidden(true)
                StatusDot(color: dotColor, glow: reachable)
                Text(cluster.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(reachable ? Theme.fg : Theme.muted)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            Text(subtitle)
                .font(Theme.mono(10.5))
                .foregroundStyle(reachable ? Theme.muted : Theme.faint)
                .lineLimit(1)
                .padding(.leading, 33)
            if !cluster.roles.isEmpty {
                TagFlow(spacing: 5) {
                    ForEach(cluster.roles.sorted(), id: \.self) { role in
                        tag(role.rawValue)
                    }
                    // Which k0rdent, alongside the fact of it. The distinction
                    // costs a badge and decides whether half the catalog — and
                    // the licence the cluster wants — is even available.
                    if let edition = cluster.k0rdent.edition, cluster.k0rdent.role == .management {
                        tag(edition == .enterprise ? "Enterprise" : "Community",
                            tone: edition == .enterprise ? Theme.ember : Theme.muted)
                    }
                }
                .padding(.leading, 33)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Theme.secondary : .clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Theme.border : .clear))
        .contentShape(Rectangle())
    }

    private func tag(_ text: String, tone: Color = Theme.muted) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold)).kerning(0.4)
            .lineLimit(1).fixedSize()
            .foregroundStyle(tone)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(tone == Theme.muted ? Theme.mutedBg : tone.opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4)
                .strokeBorder(tone == Theme.muted ? Theme.border : tone.opacity(0.25)))
    }

    private var reachable: Bool {
        if case .reachable = cluster.reach { return true }
        return false
    }

    private var dotColor: Color {
        switch cluster.reach {
        case .reachable:   return Theme.ok
        case .unprobed:    return Theme.muted
        case .unreachable, .unusable: return Color(hex: 0x4B515E)
        }
    }

    /// One line, and a short one: the sentence that says why lives on the
    /// Cluster screen, where there is room to read it.
    private var subtitle: String {
        switch cluster.reach {
        case .reachable(let v, _, _): return "\(cluster.context.server.host() ?? "") · \(v)"
        case .unprobed:               return cluster.context.server.host() ?? ""
        case .unreachable:            return "no route"
        case .unusable:               return "credentials this app cannot use"
        }
    }
}

/// Badges laid out left to right, and onto a new line when the row is full.
///
/// An `HStack` in a 268 pt column breaks the third badge in the middle of its
/// word — `k0rdent-` over `managed` — which reads as two badges. Wrapping the
/// whole badge is what a row of tags is expected to do.
private struct TagFlow: Layout {
    var spacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(in: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0,
                      height: rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(in: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(in width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (index, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].width + (rows[rows.count - 1].indices.isEmpty ? 0 : spacing) + size.width
            if needed > width, !rows[rows.count - 1].indices.isEmpty { rows.append(Row()) }
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].width += (rows[rows.count - 1].indices.count == 1 ? 0 : spacing) + size.width
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}

struct StatusDot: View {
    var color: Color
    var glow = false
    var size: CGFloat = 7

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay { if glow { Circle().stroke(color.opacity(0.18), lineWidth: 3) } }
    }
}


/// Shows and hides the sidebar.
///
/// Needed because this app draws its own header rows and hides the navigation
/// bar, which takes the split view's built-in toggle with it. In a window narrow
/// enough for the sidebar to collapse — and on iPadOS a window is whatever width
/// it is dragged to — that left no way back to the cluster list.
struct SidebarToggle: View {

    /// Room for the system's own window controls, which only iPadOS draws over
    /// the app's content.
    #if os(macOS)
    static let windowControlInset: CGFloat = 0
    #else
    static let windowControlInset: CGFloat = 72
    #endif

    @Binding var columns: NavigationSplitViewVisibility

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) {
                columns = columns == .detailOnly ? .all : .detailOnly
            }
        } label: {
            Image(systemName: "sidebar.leading")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.muted)
                .frame(width: 32, height: 32)
                .background(Theme.secondary, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
        }
        .buttonStyle(.plain)
        // With the sidebar collapsed this button is the leftmost thing on the
        // screen, which on iPadOS in a window is exactly where the system's own
        // controls sit — and a button under them cannot be pressed, so the
        // sidebar could not be reopened. Only the collapsed state needs the
        // room, and only on iPadOS: a Mac's controls are in the title bar.
        .padding(.leading, columns == .detailOnly ? Self.windowControlInset : 0)
        .accessibilityLabel(columns == .detailOnly ? "Show clusters" : "Hide clusters")
    }
}
