import SwiftUI

enum Section: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case tmmLive  = "TMM Live"
    case clusters = "Clusters"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .tmmLive:  return "waveform.path.ecg"
        case .clusters: return "square.stack.3d.up"
        }
    }
}

struct RootView: View {
    @Environment(ClusterStore.self) private var store
    @Environment(TelemetryEngine.self) private var engine
    @State private var section: Section = .tmmLive
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            Sidebar(section: $section)
                .navigationSplitViewColumnWidth(min: 260, ideal: 268, max: 320)
        } detail: {
            Group {
                switch section {
                case .tmmLive:            TMMLiveView()
                case .clusters, .overview: ClustersView()
                }
            }
            .background(Theme.bg)
        }
        .navigationSplitViewStyle(.balanced)
    }
}

private struct Sidebar: View {
    @Environment(ClusterStore.self) private var store
    @Binding var section: Section

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
            .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 14)

            VStack(spacing: 2) {
                ForEach(Section.allCases) { item in
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

            HStack {
                Text("CLUSTERS")
                    .font(.system(size: 10.5, weight: .bold)).kerning(0.9)
                    .foregroundStyle(Theme.muted)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 15).padding(.bottom, 8)

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
        .toolbar(.hidden, for: .navigationBar)
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
