import SwiftUI
import UniformTypeIdentifiers
import BNKKit

struct ClustersView: View {
    @Binding var columns: NavigationSplitViewVisibility
    @Environment(ClusterStore.self) private var store
    @State private var importing = false
    @State private var probing = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Theme.border)
            ScrollView {
                VStack(spacing: 12) {
                    if let error = store.importError {
                        Banner(text: error, tone: Theme.bad)
                    }
                    ForEach(store.clusters) { cluster in
                        ClusterCard(cluster: cluster, selected: store.selected == cluster.id)
                            .onTapGesture { if cluster.isUsable { store.selected = cluster.id } }
                    }
                    if !store.files.isEmpty {
                        KubeconfigList()
                    }
                    if store.clusters.isEmpty {
                        Message(title: "No kubeconfigs yet",
                                detail: "Import one from Files. Field needs a context with a client certificate or a bearer token — anything that shells out to aws, gcloud or kubelogin cannot be used on iOS.") {
                            Button("Import kubeconfig") { importing = true }
                                .buttonStyle(.borderedProminent)
                        }
                        .frame(minHeight: 320)
                    }
                }
                .padding(20)
            }
        }
        .background(Theme.bg)
        .toolbar(.hidden, for: .navigationBar)
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.yaml, .text, .data],
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls { store.importKubeconfig(from: url) }
            Task { await store.probeAll() }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            SidebarToggle(columns: $columns)
            Text("Clusters").font(.system(size: 19, weight: .semibold)).foregroundStyle(Theme.fg)
                .fixedSize()
            Text("\(store.clusters.count) contexts · \(reachableCount) reachable")
                .font(Theme.mono(11.5)).foregroundStyle(Theme.muted)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button {
                probing = true
                Task { await store.probeAll(); probing = false }
            } label: {
                Label(probing ? "Probing…" : "Probe all", systemImage: "wifi")
                    .font(.system(size: 12.5, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .disabled(probing)

            Button { importing = true } label: {
                ViewThatFits(in: .horizontal) {
                    Label("Import kubeconfig", systemImage: "plus")
                        .font(.system(size: 12.5, weight: .semibold))
                    Image(systemName: "plus").font(.system(size: 13, weight: .semibold))
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 20).frame(height: 58)
    }

    private var reachableCount: Int {
        store.clusters.filter { if case .reachable = $0.reach { return true } else { return false } }.count
    }
}

private struct ClusterCard: View {
    let cluster: ManagedCluster
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 10) {
                StatusDot(color: dot, glow: reachable, size: 8)
                Text(cluster.displayName)
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(reachable ? Theme.fg : Theme.muted)
                statusBadge
                ForEach(cluster.roles.sorted(), id: \.self) { role in
                    Badge(text: role.rawValue, color: roleColor(role))
                }
                Spacer()
                if cluster.tmmPods.contains(where: { $0.has(container: "tmm-stat-exporter") }) {
                    HStack(spacing: 6) {
                        StatusDot(color: Theme.ok, glow: true, size: 6)
                        Text("streaming").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.ok)
                    }
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 32) {
                    Field(key: "SERVER", value: cluster.context.server.absoluteString)
                    Field(key: "AUTH", value: authLabel)
                    Field(key: "CONTEXT", value: cluster.context.name)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Field(key: "SERVER", value: cluster.context.server.absoluteString)
                    Field(key: "AUTH", value: authLabel)
                    Field(key: "CONTEXT", value: cluster.context.name)
                }
            }

            if let note {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: reachable ? "checkmark.circle" : "exclamationmark.triangle")
                        .font(.system(size: 13)).foregroundStyle(reachable ? Theme.ok : Theme.warn)
                    Text(note).font(.system(size: 12)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 11).padding(.vertical, 9)
                .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(selected ? Theme.primary.opacity(0.4) : Theme.border))
        .contentShape(Rectangle())
    }

    private var reachable: Bool { if case .reachable = cluster.reach { return true } else { return false } }

    private var dot: Color {
        switch cluster.reach {
        case .reachable: return Theme.ok
        case .unprobed:  return Theme.muted
        default:         return Color(hex: 0x4B515E)
        }
    }

    @ViewBuilder private var statusBadge: some View {
        switch cluster.reach {
        case .reachable(_, let nodes, let ready):
            Badge(text: "\(ready)/\(nodes) nodes ready", color: ready == nodes ? Theme.ok : Theme.warn)
        case .unprobed:    Badge(text: "not probed", color: Theme.muted)
        case .unreachable: Badge(text: "no route", color: Color(hex: 0x8B94A6))
        case .unusable:    Badge(text: "unusable", color: Theme.warn)
        }
    }

    private var authLabel: String {
        switch cluster.context.auth {
        case .clientCertificate: return "client certificate"
        case .bearerToken:       return "bearer token"
        case .unsupported:       return "unsupported"
        }
    }

    private var note: String? {
        switch cluster.reach {
        case .unusable(let why), .unreachable(let why): return why
        case .reachable(let v, _, _):
            let tmm = cluster.tmmPods.count
            return tmm > 0
                ? "Kubernetes \(v). \(tmm) f5-tmm pod\(tmm == 1 ? "" : "s") found by label, of which \(cluster.tmmPods.filter { $0.has(container: "tmm-stat-exporter") }.count) carry the exporter."
                : "Kubernetes \(v). No f5-tmm pods here, so there is nothing for TMM Live to scrape."
        case .unprobed: return nil
        }
    }

    private func roleColor(_ role: ManagedCluster.Role) -> Color {
        switch role {
        case .bnk:  return Theme.series[0]
        case .dpu:  return Theme.series[1]
        case .nico: return Theme.series[2]
        }
    }
}

private struct Field: View {
    let key: String, value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(key).font(.system(size: 10, weight: .semibold)).kerning(0.6).foregroundStyle(Theme.faint)
            Text(value).font(Theme.mono(12)).foregroundStyle(Theme.fg).lineLimit(1)
        }
    }
}

struct Badge: View {
    let text: String
    var color: Color = Theme.muted
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 9).padding(.vertical, 2)
            .background(color.opacity(0.1), in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(0.2)))
    }
}

struct Banner: View {
    let text: String
    var tone: Color = Theme.warn
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(tone)
            Text(text).font(.system(size: 12.5)).foregroundStyle(Theme.fg)
            Spacer()
        }
        .padding(14)
        .background(tone.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tone.opacity(0.25)))
    }
}


/// The kubeconfigs that were imported, and the way to take one back out.
private struct KubeconfigList: View {
    @Environment(ClusterStore.self) private var store
    @State private var removing: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Kubeconfigs").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.fg)
            ForEach(store.files, id: \.self) { file in
                HStack(spacing: 12) {
                    Image(systemName: "doc.text").font(.system(size: 14)).foregroundStyle(Theme.muted)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file).font(Theme.mono(12)).foregroundStyle(Theme.fg)
                        Text(contexts(file)).font(.system(size: 11)).foregroundStyle(Theme.faint)
                    }
                    Spacer(minLength: 8)
                    Button("Remove") { removing = file }
                        .buttonStyle(.bordered).controlSize(.small).tint(Theme.bad)
                }
                .padding(.horizontal, 13).padding(.vertical, 10)
                .background(Theme.bg, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border))
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
        .alert("Remove \(removing ?? "")?", isPresented: .constant(removing != nil)) {
            Button("Cancel", role: .cancel) { removing = nil }
            Button("Remove", role: .destructive) {
                if let file = removing { store.removeKubeconfig(named: file) }
                removing = nil
            }
        } message: {
            Text("Deletes the file and the certificates it put in the keychain. Nothing on the cluster is touched — import it again to come back.")
        }
    }

    private func contexts(_ file: String) -> String {
        let names = store.contexts(from: file)
        return names.isEmpty ? "no usable contexts" : names.joined(separator: ", ")
    }
}
