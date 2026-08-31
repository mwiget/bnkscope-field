import Foundation
import Observation
import BNKKit

/// One point on one plotted line.
///
/// `v` is optional so a break can be recorded. A chart that joins the sample
/// before a sleep to the sample after it draws a clean ramp across minutes that
/// were never measured — which is worse than a hole, because it looks like data.
struct Point: Identifiable, Sendable {
    let t: Date
    let v: Double?
    var id: Double { t.timeIntervalSince1970 }
}

/// A panel's worth of history: named lines, each a series of points.
struct PanelData: Sendable {
    var lines: [String: [Point]] = [:]

    /// Line order is fixed by name, not by arrival, so a series that drops out
    /// for a scrape and comes back does not change colour.
    var names: [String] { lines.keys.sorted() }

    mutating func append(_ values: [String: Double], at t: Date, limit: Int) {
        for (name, v) in values {
            lines[name, default: []].append(Point(t: t, v: v))
        }
        trim(to: limit)
    }

    /// Put a hole in every line. Called when the scrape stops, so the resumed
    /// series starts a new stroke rather than continuing the old one.
    mutating func breakLines(at t: Date, limit: Int) {
        for name in lines.keys where lines[name]?.last?.v != nil {
            lines[name]!.append(Point(t: t, v: nil))
        }
        trim(to: limit)
    }

    private mutating func trim(to limit: Int) {
        for name in lines.keys where lines[name]!.count > limit {
            lines[name]!.removeFirst(lines[name]!.count - limit)
        }
    }

    /// The newest measured value, ignoring any trailing break.
    func latest(_ name: String) -> Double? {
        lines[name]?.last(where: { $0.v != nil })?.v
    }
}

/// Direct mode: the iPad scrapes the exporters itself and does the arithmetic.
///
/// There is no Prometheus in this path, so the two things Prometheus would do —
/// hold the history and turn counters into rates — happen here. Only the derived
/// panel lines are kept: a scrape is ~2,400 series and retaining all of them for
/// half an hour would cost more memory than the whole app is worth, while the
/// panels need a few dozen.
@Observable
@MainActor
final class TelemetryEngine {
    /// 2s matches the exporter's own push interval. Nothing is gained by asking
    /// faster than tmstat is sampled.
    static let liveInterval: Duration = .seconds(2)

    /// What the exporter is told to do while the app is in the background. It
    /// keeps sampling, so the window has a coarse stretch rather than a hole.
    static let idleInterval: Duration = .seconds(30)

    /// 30 minutes at 2s.
    static let historyLimit = 900

    enum State: Equatable {
        case idle
        case live
        case paused
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var panels: [PanelID: PanelData] = [:]
    private(set) var lastScrape: Date?
    private(set) var lastDuration: TimeInterval = 0
    /// The interval actually being achieved, which is not `liveInterval` when a
    /// scrape takes longer than it. On a real device over wifi it is several
    /// times longer, because every scrape currently opens its own tunnel.
    private(set) var achievedInterval: TimeInterval = 0
    private(set) var bytesPerScrape: Int = 0
    private(set) var targets: [String] = []

    private var client: KubeClient?
    private var namespace = ""
    private var task: Task<Void, Never>?
    /// The previous raw frame per pod, kept only long enough to difference
    /// against. Two views of it: totals per metric name, for the aggregate
    /// panels, and per series, for anything grouped by a label.
    private var previous: [String: Frame] = [:]

    private struct Frame {
        let t: Date
        let byName: [String: Double]
        let bySeries: [String: Double]
    }

    // MARK: - Lifecycle

    func start(client: KubeClient, namespace: String, pods: [String]) {
        stop()
        self.client = client
        self.namespace = namespace
        self.targets = pods
        guard !pods.isEmpty else {
            state = .failed("no f5-tmm pods on this cluster")
            return
        }
        state = .live
        task = Task { [weak self] in await self?.loop() }
    }

    /// Backgrounding stops the scrape entirely. In Direct mode there is nothing
    /// cluster-side to throttle — the iPad simply stops asking, and the history
    /// it already holds is still there when it comes back.
    func pause() {
        guard state == .live else { return }
        task?.cancel()
        task = nil
        state = .paused
        // Record the moment the measurements stop, so the charts show a gap
        // rather than a line drawn through it.
        let now = Date()
        for panel in panels.keys {
            panels[panel]!.breakLines(at: now, limit: Self.historyLimit)
        }
    }

    func resume() {
        guard state == .paused, let client else { return }
        state = .live
        // The gap is real and the next rate must not be computed across it: a
        // counter differenced over a ten-minute sleep would draw one enormous
        // spike. Dropping the previous frame makes the first scrape back a
        // baseline instead.
        previous.removeAll()
        lastScrape = nil
        task = Task { [weak self] in await self?.loop() }
        _ = client
    }

    func stop() {
        task?.cancel()
        task = nil
        state = .idle
        panels.removeAll()
        previous.removeAll()
        lastScrape = nil
        achievedInterval = 0
    }

    // MARK: - The loop

    private func loop() async {
        while !Task.isCancelled {
            let started = Date()
            await scrapeOnce()
            lastDuration = Date().timeIntervalSince(started)
            let spent = Duration.seconds(lastDuration)
            if spent < Self.liveInterval {
                try? await Task.sleep(for: Self.liveInterval - spent)
            }
        }
    }

    private func scrapeOnce() async {
        guard let client else { return }
        let ns = namespace
        let pods = targets

        var frames: [String: [Sample]] = [:]
        var failures: [String] = []
        // Pods are scraped concurrently: two tunnels opened in sequence would
        // put the samples a round-trip apart and skew every per-pod comparison.
        await withTaskGroup(of: (String, Result<[Sample], Error>).self) { group in
            for pod in pods {
                group.addTask {
                    do { return (pod, .success(try await client.scrape(namespace: ns, pod: pod, port: 9099))) }
                    catch { return (pod, .failure(error)) }
                }
            }
            for await (pod, result) in group {
                switch result {
                case .success(let s): frames[pod] = s
                case .failure(let e): failures.append("\(pod): \(e)")
                }
            }
        }

        guard !frames.isEmpty else {
            state = .failed(failures.first ?? "every scrape failed")
            return
        }
        if state != .live { state = .live }
        let now = Date()
        if let previousScrape = lastScrape {
            let gap = now.timeIntervalSince(previousScrape)
            // Smoothed, so one slow scrape does not make the readout jump.
            achievedInterval = achievedInterval == 0 ? gap : achievedInterval * 0.7 + gap * 0.3
        }
        lastScrape = now
        ingest(frames, at: now)
    }

    // MARK: - Deriving the panels

    private func ingest(_ frames: [String: [Sample]], at now: Date) {
        var derived: [PanelID: [String: Double]] = [:]

        for (pod, samples) in frames {
            let short = Self.shortPodName(pod)
            // /metrics carries no pod label — the exporter only adds those on the
            // remote_write path — so the scrape is tagged here with the pod it
            // came from. Without this every pod's series would collide.
            let frame = Frame(t: now,
                              byName: Self.total(samples, by: \.name),
                              bySeries: Self.total(samples, by: \.seriesKey))
            let prev = previous[pod]
            previous[pod] = frame

            // Gauges read straight off the frame.
            derived[.connections, default: [:]][short] =
                Self.sum(samples, named: "f5tmm_tmm_client_side_traffic_cur_conns")

            guard let prev, now.timeIntervalSince(prev.t) > 0.1 else { continue }
            let dt = now.timeIntervalSince(prev.t)
            /// A counter that went backwards means tmm restarted and reset it.
            /// There is no rate to report across that, so the series skips a
            /// point rather than drawing a negative one or a false spike.
            func rate(_ key: String, _ side: KeyPath<Frame, [String: Double]>) -> Double? {
                guard let a = prev[keyPath: side][key], let b = frame[keyPath: side][key], b >= a else { return nil }
                return (b - a) / dt
            }
            func rateByName(_ key: String) -> Double? { rate(key, \.byName) }

            // CPU is derived from the cycle counters, not from cpu_usage: tmstat
            // marks constants and gauges alike as counters, and cpu_usage_1sec
            // reads ~2992 under load rather than a percentage.
            if let idle = rateByName("f5tmm_tmm_tm_idle_cycles"),
               let total = rateByName("f5tmm_tmm_tm_total_cycles"), total > 0 {
                derived[.cpu, default: [:]][short] = (1 - idle / total) * 100
            }
            if let b = rateByName("f5tmm_tmm_client_side_traffic_bytes_in") {
                derived[.throughput, default: [:]]["\(short) in"] = b * 8
            }
            if let b = rateByName("f5tmm_tmm_client_side_traffic_bytes_out") {
                derived[.throughput, default: [:]]["\(short) out"] = b * 8
            }

            // Per-tenant connection rate, from the virtual-server names — the
            // same shape the Grafana dashboard gets with label_replace.
            for (tenant, keys) in Self.tenantKeys(samples, metric: "f5tmm_virtual_server_clientside_tot_conns") {
                let r = keys.compactMap { rate($0, \.bySeries) }.reduce(0, +)
                derived[.tenantConnRate, default: [:]][tenant, default: 0] += r
            }
        }

        for (panel, values) in derived {
            panels[panel, default: PanelData()].append(values, at: now, limit: Self.historyLimit)
        }
        bytesPerScrape = frames.values.reduce(0) { $0 + $1.count }
    }

    /// Total the samples under whichever key the caller needs — the metric name
    /// to aggregate a family, or the series key to keep its labels apart.
    static func total(_ samples: [Sample], by key: KeyPath<Sample, String>) -> [String: Double] {
        var out: [String: Double] = [:]
        for s in samples { out[s[keyPath: key], default: 0] += s.value }
        return out
    }

    static func sum(_ samples: [Sample], named name: String) -> Double {
        samples.reduce(0) { $0 + ($1.name == name ? $1.value : 0) }
    }

    /// Virtual servers are named `tenant-<tenant>-...`, which is where the
    /// per-tenant view comes from. A name that does not match is not a tenant's
    /// and is left out rather than bucketed under something invented.
    static func tenantKeys(_ samples: [Sample], metric: String) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for s in samples where s.name == metric {
            guard let name = s.labels["name"], name.hasPrefix("tenant-") else { continue }
            let parts = name.dropFirst("tenant-".count).split(separator: "-")
            guard let tenant = parts.first else { continue }
            out[String(tenant), default: []].append(s.seriesKey)
        }
        return out
    }

    /// `dpu-cplane-tenant1-tmm-g6lx4-f5-tmm-dhm72` → `dhm72`. The prefix is the
    /// same on every pod in a cluster and only costs legend width.
    static func shortPodName(_ pod: String) -> String {
        String(pod.split(separator: "-").last ?? Substring(pod))
    }
}

enum PanelID: String, CaseIterable, Hashable, Sendable {
    case cpu, throughput, connections, tenantConnRate

    var title: String {
        switch self {
        case .cpu:            return "TMM CPU utilisation"
        case .throughput:     return "TMM client throughput"
        case .connections:    return "TMM current connections"
        case .tenantConnRate: return "Per-tenant connection rate"
        }
    }

    var unit: String {
        switch self {
        case .cpu:            return "% · cycles-based, per pod"
        case .throughput:     return "bit/s · software path only"
        case .connections:    return "client-side · instantaneous"
        case .tenantConnRate: return "new conns/s · from virtual-server names"
        }
    }

    /// A fixed axis where the quantity has natural bounds. CPU running to 200%
    /// because the auto-scale padded a 97% reading makes the panel read as if
    /// there were headroom that does not exist.
    var yDomain: ClosedRange<Double>? {
        switch self {
        case .cpu: return 0...100
        default:   return nil
        }
    }

    var format: ValueFormat {
        switch self {
        case .cpu:            return .percent
        case .throughput:     return .bitsPerSecond
        case .connections:    return .count
        case .tenantConnRate: return .perSecond
        }
    }
}

enum ValueFormat: Sendable {
    case percent, bitsPerSecond, count, perSecond

    func callAsFunction(_ v: Double) -> String {
        switch self {
        case .percent: return String(format: "%.1f%%", v)
        case .count:   return String(format: "%.0f", v)
        case .perSecond: return v >= 100 ? String(format: "%.0f/s", v) : String(format: "%.1f/s", v)
        case .bitsPerSecond:
            let units = ["b/s", "kb/s", "Mb/s", "Gb/s", "Tb/s"]
            var v = v, i = 0
            while v >= 1000, i < units.count - 1 { v /= 1000; i += 1 }
            return String(format: i == 0 ? "%.0f %@" : "%.2f %@", v, units[i])
        }
    }
}
