import SwiftUI

enum Section: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case tmmLive  = "TMM Live"
    case clusters = "Clusters"
    case resources = "Resources"
    case logs = "Logs"
    case dpu = "DPU Services"
    case nico = "NICo"
    case terminal = "Terminal"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .tmmLive:  return "waveform.path.ecg"
        case .clusters: return "square.stack.3d.up"
        case .resources: return "list.bullet.rectangle"
        case .logs: return "text.alignleft"
        case .dpu: return "point.3.connected.trianglepath.dotted"
        case .nico: return "network"
        case .terminal: return "apple.terminal"
        }
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
        @Bindable var navigator = navigator
        return NavigationSplitView(columnVisibility: $columns) {
            Sidebar(section: $navigator.section)
                .navigationSplitViewColumnWidth(min: 260, ideal: 268, max: 320)
        } detail: {
            Group {
                switch navigator.section {
                case .tmmLive:             TMMLiveView(columns: $columns)
                case .logs:                LogsView(columns: $columns)
                case .dpu:                 DPUView(columns: $columns)
                case .nico:                NICoView(columns: $columns)
                case .terminal:            TerminalView(columns: $columns)
                case .overview:            OverviewView(columns: $columns)
                case .clusters:            ClustersView(columns: $columns)
                case .resources:           ResourcesView(columns: $columns)
                }
            }
            .background(Theme.bg)
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
    @Binding var section: Section

    /// NICo appears only on a cluster running it — the same shape as bnkscope's
    /// tab, and better than a screen that is permanently empty on most clusters.
    private var visibleSections: [Section] {
        Section.allCases.filter { section in
            switch section {
            case .nico: store.current?.roles.contains(.nico) == true
            case .dpu:  store.current?.roles.contains(.dpu) == true
            default:    true
            }
        }
    }

    var body: some View {
        @Bindable var store = store
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

            VStack(spacing: 2) {
                ForEach(visibleSections) { item in
                    Button { section = item } label: {
                        HStack(spacing: 11) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 15, weight: .medium))
                                .frame(width: 18)
                            Text(item.rawValue).font(.system(size: 14, weight: section == item ? .semibold : .medium))
                            Spacer()
                        }
                        .foregroundStyle(section == item ? Color(hex: 0xDFE7F7) : Theme.fg)
                        .padding(.horizontal, 11).frame(height: 38)
                        .background(section == item ? Theme.primary.opacity(0.12) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)

            Divider().overlay(Theme.border).padding(.horizontal, 16).padding(.top, 14)

            // No "CLUSTERS" heading. There is already a Clusters entry in the
            // navigation above, and one word doing two jobs — a screen you open
            // and a list you pick from — read as the same thing listed twice.
            // The rows sit under a divider and are self-evidently clusters.
            Spacer().frame(height: 12)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(store.clusters) { cluster in
                        Button { store.selected = cluster.id } label: {
                            ClusterRow(cluster: cluster, selected: store.selected == cluster.id)
                        }
                        .buttonStyle(.plain)
                        .disabled(!cluster.isUsable)
                    }
                }
                .padding(.horizontal, 10)
            }
            .scrollBounceBehavior(.basedOnSize)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card)
        .noNavigationBar()
    }
}

private struct ClusterRow: View {
    let cluster: ManagedCluster
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
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
                .padding(.leading, 15)
            if !cluster.roles.isEmpty {
                HStack(spacing: 5) {
                    ForEach(cluster.roles.sorted(), id: \.self) { role in
                        Text(role.rawValue)
                            .font(.system(size: 10, weight: .semibold)).kerning(0.4)
                            .foregroundStyle(Theme.muted)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Theme.mutedBg, in: RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.border))
                    }
                }
                .padding(.leading, 15)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Theme.secondary : .clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Theme.border : .clear))
        .contentShape(Rectangle())
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

    private var subtitle: String {
        switch cluster.reach {
        case .reachable(let v, _, _): return "\(cluster.context.server.host() ?? "") · \(v)"
        case .unprobed:               return cluster.context.server.host() ?? ""
        case .unreachable:            return "no route from this iPad"
        case .unusable:               return "credentials iOS cannot use"
        }
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
