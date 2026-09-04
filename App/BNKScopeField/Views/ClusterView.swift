import SwiftUI
import UniformTypeIdentifiers
import BNKKit

/// One cluster: how it is reached, what probing found there, and the way to
/// forget it. Import and probe-all live in the sidebar, next to the list they
/// act on; this screen is about the one cluster that is selected.
struct ClusterView: View {
    @Binding var columns: NavigationSplitViewVisibility
    @Environment(ClusterStore.self) private var store
    @State private var probing = false
    @State private var importing = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Theme.border)
            if let cluster = store.current {
                ScrollView {
                    ClusterCard(cluster: cluster)
                        .padding(20)
                }
            } else if store.clusters.isEmpty {
                // The button is here as well as in the sidebar, because below
                // 900 pt the sidebar is folded away and a sentence pointing at
                // it points at nothing on screen.
                Message(title: "No kubeconfigs yet",
                        detail: "Import one \(ManagedCluster.importSource). Field needs a context with a client certificate or a bearer token — anything that shells out to aws, gcloud or kubelogin cannot be used here.") {
                    Button("Import kubeconfig") { importing = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                Message(title: "No cluster selected", detail: "Pick one in the sidebar.")
            }
        }
        .background(Theme.bg)
        .noNavigationBar()
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
            Text(store.current?.displayName ?? "Cluster")
                .font(.system(size: 19, weight: .semibold)).foregroundStyle(Theme.fg)
                .lineLimit(1).truncationMode(.middle)
            if let cluster = store.current {
                Text(cluster.context.server.absoluteString)
                    .font(Theme.mono(11.5)).foregroundStyle(Theme.muted)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let cluster = store.current, cluster.isUsable {
                Button {
                    probing = true
                    Task { await cluster.probe(); probing = false }
                } label: {
                    Label(probing ? "Probing…" : "Probe", systemImage: "wifi")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .disabled(probing)
            }
        }
        .padding(.horizontal, 20).frame(height: 58)
    }
}

private struct ClusterCard: View {
    let cluster: ManagedCluster
    @Environment(ClusterStore.self) private var store
    @State private var confirmingRemoval = false

    /// Other clusters from the same file. They are unaffected.
    private var siblings: [String] { store.siblings(of: cluster) }

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

            HStack(alignment: .bottom, spacing: 16) {
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
                Spacer(minLength: 8)
                // The action sits with the fact it acts on: this cluster came
                // out of that file, and removing the file is what takes it away.
                VStack(alignment: .trailing, spacing: 4) {
                    Text("from \(cluster.sourceFile)")
                        .font(Theme.mono(10.5)).foregroundStyle(Theme.faint).lineLimit(1)
                    Button("Remove") { confirmingRemoval = true }
                        .buttonStyle(.bordered).controlSize(.small).tint(Theme.bad)
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
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
        .alert("Remove \(cluster.displayName)?", isPresented: $confirmingRemoval) {
            Button("Cancel", role: .cancel) { }
            Button("Remove", role: .destructive) { store.remove(cluster) }
        } message: {
            Text(removalWarning)
        }
    }

    private var removalWarning: String {
        let base = "Nothing on the cluster is touched. Import \(cluster.sourceFile) again to bring it back."
        guard !siblings.isEmpty else {
            return "Removes this cluster and the certificate it put in the keychain, and deletes \(cluster.sourceFile) — it holds nothing else.\n\n" + base
        }
        return "Removes this cluster only. \(siblings.joined(separator: ", ")) came from the same file and stay.\n\n" + base
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
            let base = tmm > 0
                ? "Kubernetes \(v). \(tmm) f5-tmm pod\(tmm == 1 ? "" : "s") found by label, of which \(cluster.tmmPods.filter { $0.has(container: "tmm-stat-exporter") }.count) carry the exporter."
                : "Kubernetes \(v). No f5-tmm pods here, so there is nothing for TMM Live to scrape."
            return ([base] + Self.k0rdentNotes(cluster)).joined(separator: " ")
        case .unprobed: return nil
        }
    }

    /// What the k0rdent, GPU and KubeVirt probes found, as sentences.
    ///
    /// Written out rather than left to the badges because the badges say a
    /// cluster is managed and cannot say by what: the ClusterDeployment's
    /// namespace and name are the thread back to the management cluster, and
    /// they are the first thing anyone asks for.
    private static func k0rdentNotes(_ cluster: ManagedCluster) -> [String] {
        var notes: [String] = []
        switch cluster.k0rdent.role {
        case .management:
            let edition = cluster.k0rdent.edition == .enterprise ? "Enterprise" : "Community"
            let version = cluster.k0rdent.version.map { " \($0)" } ?? ""
            let providers = cluster.k0rdent.providers
                .filter { $0.hasPrefix("infrastructure-") }
                .map { String($0.dropFirst("infrastructure-".count)) }
            notes.append("k0rdent \(edition)\(version) management cluster"
                + (providers.isEmpty ? "." : ", providing \(providers.joined(separator: ", "))."))
        case .managed:
            if let by = cluster.k0rdent.managedBy {
                notes.append("Managed by k0rdent as \(by.namespace)/\(by.name)"
                    + (by.clusterType == "Capi" ? ", provisioned by it." : ", adopted."))
            } else {
                notes.append("Managed by k0rdent.")
            }
        case nil:
            break
        }
        if !cluster.gpuDevices.isEmpty {
            notes.append("GPUs: \(cluster.gpuDevices.joined(separator: ", ")).")
        }
        if cluster.roles.contains(.kubevirt) {
            notes.append("KubeVirt is installed — see the KubeVirt tab.")
        }
        return notes
    }

    private func roleColor(_ role: ManagedCluster.Role) -> Color {
        switch role {
        case .bnk:      return Theme.series[0]
        case .dpu:      return Theme.series[1]
        case .nico:     return Theme.series[2]
        case .k0rdent:  return Theme.series[3]
        // The same hue as k0rdent, because it is the same fact seen from the
        // other end: this cluster belongs to one of those.
        case .managed:  return Theme.series[3]
        case .kubevirt: return Theme.series[4]
        case .gpu:      return Theme.ember
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


