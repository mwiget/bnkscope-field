import SwiftUI
import BNKKit

struct NICoView: View {
    @Binding var columns: NavigationSplitViewVisibility
    @Environment(ClusterStore.self) private var store
    @Environment(NICoEngine.self) private var nico

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Theme.border)
            if store.current?.roles.contains(.nico) != true {
                Message(title: "No NVIDIA Infra Controller here",
                        detail: "This screen appears on a cluster running NICo. Field detects it from the nico-api pod's labels.")
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        ForEach(nico.snapshot.problems, id: \.self) { Banner(text: $0, tone: Theme.warn) }
                        HStack(alignment: .top, spacing: 16) {
                            controlPlane
                            adminCertificate
                        }
                        tenants
                        metrics
                        forgeNote
                    }
                    .padding(20)
                }
            }
        }
        .background(Theme.bg)
        .noNavigationBar()
        // Keyed on the probe as well as the selection: the first render lands
        // before probing has said what this cluster is, and reselecting the same
        // cluster afterwards is not a change on its own.
        .task(id: "\(store.selected ?? "")#\(store.current?.probeGeneration ?? 0)") { await reload() }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            SidebarToggle(columns: $columns)
            Text("NICo").font(.system(size: 19, weight: .semibold)).foregroundStyle(Theme.fg).fixedSize()
            if let cluster = store.current {
                Text(cluster.displayName).font(Theme.mono(11.5)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 8)
            if nico.loading { ProgressView().controlSize(.small) }
            Button("Refresh") { Task { await reload() } }
                .buttonStyle(.bordered).controlSize(.small).disabled(nico.loading)
        }
        .padding(.horizontal, 20).frame(height: 58)
    }

    // MARK: - Cards

    private var controlPlane: some View {
        card("Control plane") {
            let pods = nico.snapshot.apiPods + nico.snapshot.providerPods
            if pods.isEmpty {
                Text("No nico pods found in nico-system.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.muted)
            }
            ForEach(pods, id: \.metadata.name) { pod in
                HStack(spacing: 10) {
                    StatusDot(color: pod.status?.phase == "Running" ? Theme.ok : Theme.warn,
                              glow: pod.status?.phase == "Running")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pod.metadata.name).font(Theme.mono(12)).foregroundStyle(Theme.fg)
                            .lineLimit(1).truncationMode(.middle)
                        Text(pod.spec?.containers.first?.image ?? "—")
                            .font(Theme.mono(10.5)).foregroundStyle(Theme.faint)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    let restarts = pod.status?.containerStatuses?.first?.restartCount ?? 0
                    if restarts > 0 { Badge(text: "\(restarts) restarts", color: Theme.warn) }
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
            }
        }
    }

    private var adminCertificate: some View {
        card("Admin certificate") {
            if let cert = nico.snapshot.adminCert {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(cert.daysRemaining)")
                            .font(Theme.mono(30, weight: .semibold))
                            .foregroundStyle(expiryColour(cert))
                            .monospacedDigit()
                        Text("days left").font(Theme.mono(12)).foregroundStyle(Theme.muted)
                    }
                    field("SUBJECT", cert.subject ?? "—")
                    field("ISSUER", cert.issuer ?? "—")
                    field("EXPIRES", cert.notAfter.formatted(date: .abbreviated, time: .shortened))
                    field("SECRET", nico.snapshot.adminCertSecret ?? "—")
                }
            } else {
                Text("Not read. Forge is reached with this client certificate, so its expiry is worth knowing before it stops working.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.muted)
            }
        }
    }

    private func expiryColour(_ cert: Certificate) -> Color {
        if cert.isExpired { return Theme.bad }
        if cert.daysRemaining < 30 { return Theme.warn }
        return Theme.ok
    }

    private var tenants: some View {
        card("Tenant control planes") {
            if nico.snapshot.tenants.isEmpty {
                Text("None. Kamaji hosts the tenant clusters' control planes; on this cluster there are none registered.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.muted)
            }
            ForEach(nico.snapshot.tenants) { tenant in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        StatusDot(color: tenant.ready ? Theme.ok : Theme.warn, glow: tenant.ready)
                        Text(tenant.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.fg)
                        Badge(text: tenant.version ?? "?", color: Theme.muted)
                        Badge(text: tenant.ready ? "Ready" : "not ready", color: tenant.ready ? Theme.ok : Theme.warn)
                        Spacer(minLength: 8)
                        if let known = tenant.knownCluster {
                            HStack(spacing: 6) {
                                Image(systemName: "link").font(.system(size: 11)).foregroundStyle(Theme.primary)
                                Text("this is \(known)").font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(Theme.primary)
                            }
                        }
                    }
                    HStack(spacing: 28) {
                        field("ENDPOINT", tenant.endpoint ?? "—")
                        field("NAMESPACE", tenant.namespace)
                        if let ca = tenant.ca {
                            field("CLUSTER CA", "\(ca.daysRemaining) days left")
                        }
                    }
                }
                .padding(13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.bg, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border))
            }
        }
    }

    private var metrics: some View {
        card("nico-api") {
            if nico.snapshot.metrics.isEmpty {
                Text("No metrics read. nico-api publishes them on its own port, reached the same way TMM's exporter is — a tunnel to the pod, nothing installed.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.muted)
            } else {
                HStack(spacing: 14) {
                    ForEach(nico.snapshot.metrics.sorted(by: { $0.key < $1.key }), id: \.key) { name, value in
                        Tile(label: Self.label(for: name),
                             value: value.formatted(.number.notation(.compactName)),
                             unit: "", sub: name)
                    }
                }
            }
        }
    }

    private static func label(for metric: String) -> String {
        switch metric {
        case "nico_api_db_queries_total": return "DB QUERIES"
        case "nico_api_grpc_server_duration_milliseconds_count": return "GRPC CALLS"
        case "nico_active_host_firmware_update_count": return "FIRMWARE UPDATES"
        default: return metric.uppercased()
        }
    }

    private var forgeNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle").foregroundStyle(Theme.muted)
            Text("Tenants, VPCs and load-balancer services live behind Forge's gRPC API, which needs server reflection and a dynamic protobuf stack. That belongs in the in-cluster collector, not on the iPad — everything on this screen is a plain Kubernetes read or a scrape of nico-api's metrics port.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
    }

    // MARK: - Pieces

    @ViewBuilder
    private func card(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.fg)
            content()
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
    }

    private func field(_ key: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(key).font(.system(size: 10, weight: .semibold)).kerning(0.6).foregroundStyle(Theme.faint)
            Text(value).font(Theme.mono(12)).foregroundStyle(Theme.fg).lineLimit(1)
        }
    }

    private func reload() async {
        guard let cluster = store.current, cluster.isUsable else { return }
        // Probe on demand rather than assuming someone else already has.
        if case .unprobed = cluster.reach { await cluster.probe() }
        guard cluster.roles.contains(.nico) else { return }
        await nico.load(cluster: cluster, known: store.clusters)
    }
}
