import Foundation
import Observation
import BNKKit

/// Follows several containers at once and merges them into one view.
///
/// Nothing is installed to make this work — the apiserver streams a container's
/// stdout through the kubelet. What is missing without a collector is history:
/// this holds what has arrived since it started following, and no more. The
/// desktop build ships Loki and 24 hours; here the window is the session.
@Observable
@MainActor
final class LogsEngine {
    /// Enough to chase an incident, few enough that the apiserver is not being
    /// asked to hold hundreds of streams open for a tablet.
    static let maxStreams = 24
    static let bufferLimit = 4000

    private(set) var lines: [LogLine] = []
    private(set) var following: [String] = []
    private(set) var dropped = 0
    private(set) var failures: [String] = []
    private(set) var isRunning = false

    var query = ""
    var levels: Set<LogLine.Level> = Set(LogLine.Level.allCases)
    /// Containers the reader has silenced.
    ///
    /// A log view following two dozen containers is only as useful as its
    /// noisiest one allows: on this cluster a single sfc-controller produced
    /// nearly every line in the buffer and nothing else could be seen. Muting is
    /// display-only — the stream stays open and the lines stay in the buffer, so
    /// unmuting shows what was missed rather than starting again.
    var muted: Set<String> = []
    /// Lines held per container, for deciding what to mute.
    private(set) var counts: [String: Int] = [:]

    private var tasks: [Task<Void, Never>] = []
    private var client: KubeClient?
    private var namespace = ""

    /// Newest first. A live tail pinned to the bottom needs scroll management to
    /// stay useful, and gets in the way the moment you scroll up to read
    /// something; newest at the top needs neither and answers "what just
    /// happened" directly.
    var visible: [LogLine] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return lines.filter { line in
            guard !muted.contains(line.container ?? "") else { return false }
            guard levels.contains(line.level) else { return false }
            guard !needle.isEmpty else { return true }
            return line.text.lowercased().contains(needle)
                || line.pod.lowercased().contains(needle)
                || (line.container?.lowercased().contains(needle) ?? false)
        }
    }

    func start(client: KubeClient, namespace: String, pods: [K8s.Pod]) {
        stop()
        self.client = client
        self.namespace = namespace

        var targets: [(pod: String, container: String)] = []
        for pod in pods {
            for container in pod.logSources { targets.append((pod.metadata.name, container)) }
        }
        dropped = max(0, targets.count - Self.maxStreams)
        targets = Array(targets.prefix(Self.maxStreams))
        following = targets.map { "\($0.pod)/\($0.container)" }
        muted.removeAll()
        guard !targets.isEmpty else { return }

        isRunning = true
        for target in targets {
            tasks.append(Task { [weak self] in
                guard let self else { return }
                do {
                    let stream = client.logStream(namespace: namespace, pod: target.pod,
                                                  container: target.container, tailLines: 40)
                    for try await line in stream {
                        if Task.isCancelled { return }
                        self.insert(line)
                    }
                } catch {
                    if !Task.isCancelled {
                        self.note("\(target.pod)/\(target.container): \(TelemetryEngine.brief(error))")
                    }
                }
            })
        }
    }

    func stop() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        isRunning = false
    }

    func clear() {
        lines.removeAll()
        counts.removeAll()
        failures.removeAll()
    }

    func toggleMute(_ container: String) {
        if muted.contains(container) { muted.remove(container) } else { muted.insert(container) }
    }

    /// Containers seen so far, noisiest first — which is the order someone
    /// looking for what to silence wants them in.
    var sources: [(container: String, lines: Int)] {
        counts.map { (container: $0.key, lines: $0.value) }.sorted {
            $0.lines == $1.lines ? $0.container < $1.container : $0.lines > $1.lines
        }
    }

    /// Inserted in time order rather than appended.
    ///
    /// Several streams arrive interleaved and each is only ordered within
    /// itself, so arrival order is not time order. A binary search costs less
    /// than sorting the buffer on every line.
    private func insert(_ line: LogLine) {
        if let container = line.container { counts[container, default: 0] += 1 }
        guard let at = line.at else {
            lines.insert(line, at: 0)
            trim()
            return
        }
        var low = 0, high = lines.count
        while low < high {
            let mid = (low + high) / 2
            if (lines[mid].at ?? .distantPast) > at { low = mid + 1 } else { high = mid }
        }
        lines.insert(line, at: low)
        trim()
    }

    private func trim() {
        if lines.count > Self.bufferLimit { lines.removeLast(lines.count - Self.bufferLimit) }
    }

    private func note(_ message: String) {
        guard !failures.contains(message) else { return }
        failures.append(message)
        if failures.count > 6 { failures.removeFirst() }
    }
}
