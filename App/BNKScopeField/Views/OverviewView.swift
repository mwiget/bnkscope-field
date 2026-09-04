import SwiftUI
import UniformTypeIdentifiers
import BNKKit

struct OverviewView: View {
    @Binding var columns: NavigationSplitViewVisibility
    @Environment(ClusterStore.self) private var store
    @Environment(OverviewEngine.self) private var overview
    @Environment(Navigator.self) private var navigator
    @State private var importing = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Theme.border)
            if store.clusters.isEmpty {
                // The button is here rather than a sentence pointing at another
                // screen. A screen that is empty should offer the thing that
                // fills it, the same way TMM Live offers the exporter.
                Message(title: "No clusters yet",
                        detail: "Import a kubeconfig and this will tell you whether anything is wrong. It reads every context in the file.") {
                    Button("Import kubeconfig") { importing = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                ScrollView {
                    VStack(spacing: 14) {
                        ForEach(overview.reports) { report in
                            ReportCard(report: report,
                                       // Both halves. Selecting alone changed a
                                       // highlight in the sidebar and left this
                                       // screen where it was — which in a
                                       // window narrow enough to hide the
                                       // sidebar looked like a button that did
                                       // nothing.
                                       select: { store.selected = report.id
                                                 navigator.section = .cluster },
                                       open: { finding in
                                           store.selected = report.id
                                           navigator.reveal(pod: finding.pod ?? "",
                                                            namespace: finding.namespace)
                                       })
                        }
                        if overview.reports.isEmpty && !overview.scanning {
                            Text("Nothing scanned yet.")
                                .font(.system(size: 13)).foregroundStyle(Theme.muted)
                                .padding(.top, 40)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .background(Theme.bg)
        .noNavigationBar()
        .task(id: generation) { await overview.scan(store.clusters) }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.yaml, .text, .data],
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls { store.importKubeconfig(from: url) }
            Task { await store.probeAll() }
        }
    }

    /// Rescans when any cluster's probe answers, not only when the list changes.
    private var generation: String {
        store.clusters.map { "\($0.id)#\($0.probeGeneration)" }.joined(separator: ",")
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            SidebarToggle(columns: $columns)
            Text("Overview").font(.system(size: 19, weight: .semibold)).foregroundStyle(Theme.fg).fixedSize()
            if let at = overview.scannedAt {
                Text("scanned \(at.formatted(date: .omitted, time: .standard))")
                    .font(Theme.mono(11.5)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 8)
            if overview.scanning { ProgressView().controlSize(.small) }
            Button("Rescan") { Task { await store.probeAll(); await overview.scan(store.clusters) } }
                .buttonStyle(.bordered).controlSize(.small).disabled(overview.scanning)
        }
        .padding(.horizontal, 20).frame(height: 58)
    }
}

private struct ReportCard: View {
    let report: OverviewEngine.Report
    let select: () -> Void
    let open: (OverviewEngine.Finding) -> Void

    private var tone: Color {
        switch report.severity {
        case .healthy:  return Theme.ok
        case .warning:  return Theme.warn
        case .critical: return Theme.bad
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 11) {
                StatusDot(color: tone, glow: report.severity == .healthy, size: 9)
                Text(report.cluster)
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.fg)
                Badge(text: report.headline, color: tone)
                Spacer(minLength: 8)
                if !report.nodes.isEmpty {
                    Text(report.nodes).font(Theme.mono(11.5)).foregroundStyle(Theme.muted)
                }
                Button("Open", action: select)
                    .buttonStyle(.bordered).controlSize(.small)
            }

            if report.findings.isEmpty {
                HStack(spacing: 9) {
                    Image(systemName: "checkmark.circle").foregroundStyle(Theme.ok)
                    Text("Every pod is running and ready, and nothing has warned in the last half hour.")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                }
                .padding(.horizontal, 13).padding(.vertical, 10)
                .background(Theme.bg, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border))
            } else {
                ForEach(report.findings) { finding in
                    if finding.pod != nil {
                        Button { open(finding) } label: { FindingRow(finding: finding, openable: true) }
                            .buttonStyle(.plain)
                    } else {
                        FindingRow(finding: finding, openable: false)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(report.severity == .critical ? Theme.bad.opacity(0.3) : Theme.border))
    }
}

private struct FindingRow: View {
    let finding: OverviewEngine.Finding
    /// Whether this row leads anywhere. A chevron on a row that goes nowhere is
    /// a promise the screen cannot keep.
    var openable = false

    private var tone: Color {
        switch finding.severity {
        case .critical: return Theme.bad
        case .warning:  return Theme.warn
        case .healthy:  return Theme.ok
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: finding.severity == .critical ? "exclamationmark.octagon" : "exclamationmark.triangle")
                .font(.system(size: 13)).foregroundStyle(tone)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(finding.title)
                    .font(Theme.mono(12.5)).foregroundStyle(Theme.fg)
                    .lineLimit(1).truncationMode(.middle)
                Text(finding.detail)
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let namespace = finding.namespace {
                Text(namespace).font(Theme.mono(11)).foregroundStyle(Theme.faint).lineLimit(1)
            }
            if openable {
                Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(Theme.faint)
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(finding.severity == .critical ? Theme.bad.opacity(0.05) : Theme.bg,
                    in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border))
    }
}
