import Foundation
import Observation
import BNKKit

/// Is anything wrong right now, and where.
///
/// The ranking deliberately does not lead on restart counts. On a cluster that
/// has been up for sixty days, argo-cd's repo-server has restarted 39 times and
/// is perfectly healthy, while f5-dssm-sentinel-0 has restarted 157 times and is
/// genuinely broken — the difference is not the number, it is that one of them
/// is not ready now and has warnings arriving. So readiness and recent warnings
/// carry the weight, and restarts are context shown beside them rather than a
/// signal on their own.
@Observable
@MainActor
final class OverviewEngine {
    enum Severity: Int, Comparable, Sendable {
        case healthy = 0, warning = 1, critical = 2
        static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }

    struct Finding: Identifiable, Sendable {
        let id = UUID()
        let severity: Severity
        let title: String
        let detail: String
        /// Where to look next, when there is somewhere.
        let pod: String?
        let namespace: String?
    }

    struct Report: Identifiable, Sendable {
        let id: String
        let cluster: String
        var severity: Severity = .healthy
        var headline: String = "Nothing wrong"
        var findings: [Finding] = []
        var nodes: String = ""
    }

    private(set) var reports: [Report] = []
    private(set) var scanning = false
    private(set) var scannedAt: Date?

    /// A warning older than this is history, not a live fault. Kubernetes
    /// expires events after an hour by default, so anything still present and
    /// recent is genuinely current.
    static let recentWarning: TimeInterval = 30 * 60

    func scan(_ clusters: [ManagedCluster]) async {
        scanning = true
        var out: [Report] = []
        for cluster in clusters {
            out.append(await report(for: cluster))
        }
        // Sorted by trouble, not by name.
        reports = out.sorted {
            $0.severity == $1.severity ? $0.cluster < $1.cluster : $0.severity > $1.severity
        }
        scannedAt = Date()
        scanning = false
    }

    private func report(for cluster: ManagedCluster) async -> Report {
        var report = Report(id: cluster.id, cluster: cluster.displayName)

        if case .unusable(let why) = cluster.reach {
            report.severity = .critical
            report.headline = "Cannot be used"
            report.findings = [Finding(severity: .critical, title: "Credentials iOS cannot present",
                                       detail: why, pod: nil, namespace: nil)]
            return report
        }
        if case .unreachable(let why) = cluster.reach {
            report.severity = .critical
            report.headline = "Unreachable"
            report.findings = [Finding(severity: .critical, title: "No answer from the apiserver",
                                       detail: why, pod: nil, namespace: nil)]
            return report
        }
        guard let client = try? cluster.client() else { return report }

        var findings: [Finding] = []

        let nodes = (try? await client.nodes()) ?? []
        report.nodes = "\(nodes.filter(\.isReady).count)/\(nodes.count) nodes ready"
        for node in nodes where !node.isReady {
            findings.append(Finding(severity: .critical, title: "Node not ready",
                                    detail: node.metadata.name, pod: nil, namespace: nil))
        }

        let pods = (try? await client.pods()) ?? []
        for pod in pods {
            let statuses = pod.status?.containerStatuses ?? []
            let phase = pod.status?.phase ?? "?"
            let restarts = statuses.map { $0.restartCount ?? 0 }.max() ?? 0

            if phase != "Running" && phase != "Succeeded" {
                findings.append(Finding(severity: .critical, title: pod.metadata.name,
                                        detail: "\(phase) in \(pod.metadata.namespace ?? "?")",
                                        pod: pod.metadata.name, namespace: pod.metadata.namespace))
                continue
            }
            let notReady = statuses.filter { $0.ready != true }
            if !notReady.isEmpty && phase == "Running" {
                let restartNote = restarts > 0 ? " · \(restarts) restarts" : ""
                findings.append(Finding(
                    severity: .critical, title: pod.metadata.name,
                    detail: "running but \(notReady.count) of \(statuses.count) containers not ready\(restartNote)",
                    pod: pod.metadata.name, namespace: pod.metadata.namespace))
            }
        }

        let cutoff = Date().addingTimeInterval(-Self.recentWarning)
        let warnings = ((try? await client.warningEvents()) ?? [])
            .filter { ($0.at ?? .distantPast) > cutoff }
        for event in warnings.sorted(by: { ($0.at ?? .distantPast) > ($1.at ?? .distantPast) }).prefix(6) {
            let name = event.involvedObject?.name ?? "cluster"
            // A pod already reported as not-ready does not need a second row
            // saying the same thing in different words.
            guard !findings.contains(where: { $0.pod == name }) else { continue }
            findings.append(Finding(
                severity: .warning,
                title: "\(event.reason ?? "Warning"): \(name)",
                detail: Self.tidy(event.message ?? "") + (event.count.map { $0 > 1 ? " · ×\($0)" : "" } ?? ""),
                pod: event.involvedObject?.kind == "Pod" ? name : nil,
                namespace: event.involvedObject?.namespace))
        }

        // Telemetry that is installed but silent is worth saying on this screen,
        // because TMM Live will otherwise just look empty.
        if cluster.roles.contains(.bnk) {
            let missing = cluster.tmmPods.filter { !$0.has(container: "tmm-stat-exporter") }
            if !missing.isEmpty {
                findings.append(Finding(
                    severity: .warning, title: "No exporter on \(missing.count) TMM pod\(missing.count == 1 ? "" : "s")",
                    detail: "TMM Live has nothing to scrape there. Telemetry can add it.",
                    pod: nil, namespace: nil))
            }
        }

        report.findings = findings.sorted { $0.severity > $1.severity }
        report.severity = findings.map(\.severity).max() ?? .healthy
        report.headline = Self.headline(for: report.severity, count: findings.count)
        return report
    }

    static func headline(for severity: Severity, count: Int) -> String {
        switch severity {
        case .healthy:  return "Nothing wrong"
        case .warning:  return "\(count) thing\(count == 1 ? "" : "s") worth a look"
        case .critical: return "\(count) thing\(count == 1 ? "" : "s") wrong"
        }
    }

    /// Kubernetes wraps repeated events in a preamble that says nothing.
    static func tidy(_ message: String) -> String {
        var text = message
        if let range = text.range(of: "(combined from similar events): ") {
            text = String(text[range.upperBound...])
        }
        return text.count > 160 ? String(text.prefix(160)) + "…" : text
    }
}
