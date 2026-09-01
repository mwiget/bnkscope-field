import SwiftUI
import BNKKit

struct DPUView: View {
    @Binding var columns: NavigationSplitViewVisibility
    @Environment(ClusterStore.self) private var store
    @Environment(DPUEngine.self) private var dpu

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Theme.border)
            if store.current?.roles.contains(.dpu) != true {
                Message(title: "No DPU services here",
                        detail: "This screen appears on a cluster whose workloads carry svc.dpu.nvidia.com labels.")
            } else if let failure = dpu.failure {
                Message(title: "Could not read the DPU service API", detail: failure, tone: Theme.bad)
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        chains
                        interfaces
                        note
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
            Text("DPU Services").font(.system(size: 19, weight: .semibold)).foregroundStyle(Theme.fg).fixedSize()
            Text("svc.dpu.nvidia.com").font(Theme.mono(11.5)).foregroundStyle(Theme.muted).lineLimit(1)
            Spacer(minLength: 8)
            if dpu.loading { ProgressView().controlSize(.small) }
            Button("Refresh") { Task { await reload() } }
                .buttonStyle(.bordered).controlSize(.small).disabled(dpu.loading)
        }
        .padding(.horizontal, 20).frame(height: 58)
    }

    // MARK: - Chains

    private var chains: some View {
        card("Service chains", badge: "\(dpu.readyChains)/\(dpu.chains.count) ready",
             tone: dpu.readyChains == dpu.chains.count ? Theme.ok : Theme.warn) {
            if dpu.chains.isEmpty {
                Text("None. Nothing is steering traffic through this DPU.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.muted)
            }
            ForEach(dpu.chainsByNode, id: \.node) { group in
                VStack(alignment: .leading, spacing: 9) {
                    Text(group.node).font(Theme.mono(11.5)).foregroundStyle(Theme.muted)
                    ForEach(group.chains) { chain in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 9) {
                                StatusDot(color: chain.isReady ? Theme.ok : Theme.warn, glow: chain.isReady)
                                Text(chain.metadata.name)
                                    .font(Theme.mono(12)).foregroundStyle(Theme.fg)
                                Spacer(minLength: 0)
                            }
                            ForEach(Array((chain.spec.switches ?? []).enumerated()), id: \.offset) { _, hop in
                                HopRow(hop: hop)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border))
                    }
                }
            }
        }
    }

    // MARK: - Interfaces

    private var interfaces: some View {
        card("Service interfaces", badge: "\(dpu.readyInterfaces)/\(dpu.interfaces.count) ready",
             tone: dpu.readyInterfaces == dpu.interfaces.count ? Theme.ok : Theme.warn) {
            ForEach(dpu.interfacesByType, id: \.type) { group in
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Text(group.type).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.fg)
                        Text(Self.explain(group.type)).font(.system(size: 11.5)).foregroundStyle(Theme.faint)
                        Spacer(minLength: 0)
                        Text("\(group.interfaces.count)").font(Theme.mono(11.5)).foregroundStyle(Theme.muted)
                    }
                    ForEach(group.interfaces) { interface in
                        HStack(spacing: 10) {
                            StatusDot(color: interface.isReady ? Theme.ok : Theme.warn,
                                      glow: false, size: 6)
                            Text(interface.interfaceName)
                                .font(Theme.mono(11.5)).foregroundStyle(Theme.fg)
                                .frame(width: 120, alignment: .leading)
                            Text(interface.detail ?? "—")
                                .font(Theme.mono(11)).foregroundStyle(Theme.muted)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(TelemetryEngine.shortPodName(interface.spec.node ?? "—"))
                                .font(Theme.mono(11)).foregroundStyle(Theme.faint)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
                    }
                }
            }
        }
    }

    private static func explain(_ type: String) -> String {
        switch type {
        case "physical": return "the wire — uplinks out of the DPU"
        case "pf":       return "host-facing functions, the ports TMM's dataplane counters name"
        case "service":  return "ends belonging to a service running on the DPU"
        default:         return ""
        }
    }

    private var note: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle").foregroundStyle(Theme.muted)
            Text("This is the DPU service API, not the DPF operator — a different API group, and not installed on this cluster. Chains are read-only here: changing how traffic is steered is not something to do from a tablet by accident.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
    }

    @ViewBuilder
    private func card(_ title: String, badge: String, tone: Color,
                      @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.fg)
                Spacer(minLength: 8)
                Badge(text: badge, color: tone)
            }
            content()
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
    }

    private func reload() async {
        guard let cluster = store.current, cluster.roles.contains(.dpu) else { return }
        await dpu.load(cluster: cluster)
    }
}

/// One hop of a chain: the ports it joins, drawn as joined rather than listed.
private struct HopRow: View {
    let hop: DPU.ServiceChain.Switch

    var body: some View {
        let ends = (hop.ports ?? []).map { $0.serviceInterface?.described ?? "—" }
        HStack(spacing: 8) {
            ForEach(Array(ends.enumerated()), id: \.offset) { index, end in
                if index > 0 {
                    Image(systemName: "arrow.left.and.right")
                        .font(.system(size: 9)).foregroundStyle(Theme.faint)
                }
                Text(end)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.fg)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Theme.secondary, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let mtu = hop.serviceMTU {
                Text("mtu \(mtu)").font(Theme.mono(10)).foregroundStyle(Theme.faint)
            }
        }
    }
}
