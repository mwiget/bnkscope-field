import Foundation

/// One line out of one container.
public struct LogLine: Identifiable, Sendable, Hashable {
    public let id = UUID()
    public let at: Date?
    public let pod: String
    public let container: String?
    public let text: String
    public let level: Level

    public enum Level: String, Sendable, CaseIterable {
        case error, warning, info

        /// Guessed from the shapes that actually turn up in these clusters,
        /// which is more than one convention: klog's `E0831 09:00:43`, logfmt's
        /// `level=warn`, JSON's `"level":"error"`, and F5's CWC logger, which
        /// spells it `"l"="error"` — a single letter, and the reason the first
        /// version of this rendered a rabbitmq connection failure and a Redis
        /// retry storm in the same colour as a routine status line.
        ///
        /// It is a guess and will sometimes be wrong. The bias is deliberate:
        /// a missed error is invisible, while a line wrongly painted amber is
        /// still readable.
        public static func guessed(from line: String) -> Level {
            if let klog = klogLevel(line) { return klog }
            let head = line.prefix(400).lowercased()
            for marker in ["\"l\"=\"error\"", "\"l\"=\"critical\"", "\"l\"=\"fatal\"",
                           "level=error", "level=fatal", "level=critical",
                           "\"level\":\"error\"", "\"level\":\"fatal\"", "[error]", "[fatal]"]
            where head.contains(marker) { return .error }
            for marker in ["\"l\"=\"warn\"", "level=warn", "\"level\":\"warn\"", "[warn]"]
            where head.contains(marker) { return .warning }
            if contains(word: "panic", in: head) || contains(word: "fatal", in: head) { return .error }
            if contains(word: "error", in: head) || contains(word: "errors", in: head) { return .error }
            for word in ["failed", "failure", "refused", "unreachable", "timeout", "warning"]
            where contains(word: word, in: head) { return .warning }
            return .info
        }

        /// `E0831 09:00:43.931896` — severity letter, then a four-digit date.
        private static func klogLevel(_ line: String) -> Level? {
            guard line.count > 5, let first = line.first,
                  line.dropFirst().prefix(4).allSatisfy(\.isNumber) else { return nil }
            switch first {
            case "E", "F": return .error
            case "W":      return .warning
            case "I":      return .info
            default:       return nil
            }
        }

        /// Whole word only, so `errorless` does not count — and neither does a
        /// path component, which is why `/`, `-` and `_` are treated as part of
        /// a word rather than as boundaries: `/var/log/failed/` is a directory,
        /// not a fault. Nor does "0 errors", the reassuring case that a naive
        /// substring search turns into an alarm.
        private static func contains(word: String, in haystack: some StringProtocol) -> Bool {
            var index = haystack.startIndex
            while let range = haystack.range(of: word, range: index..<haystack.endIndex) {
                let beforeIndex = range.lowerBound
                let before: Character? = beforeIndex == haystack.startIndex
                    ? nil : haystack[haystack.index(before: beforeIndex)]
                let after: Character? = range.upperBound == haystack.endIndex
                    ? nil : haystack[range.upperBound]
                func isPartOfAWord(_ c: Character) -> Bool {
                    c.isLetter || c.isNumber || c == "/" || c == "-" || c == "_"
                }
                let boundedBefore = before.map { !isPartOfAWord($0) } ?? true
                let boundedAfter = after.map { !isPartOfAWord($0) } ?? true
                if boundedBefore, boundedAfter, !negated(before: beforeIndex, in: haystack) { return true }
                index = range.upperBound
            }
            return false
        }

        /// "no errors" and "0 errors" are the opposite of an error.
        private static func negated(before index: some Comparable, in haystack: some StringProtocol) -> Bool {
            guard let i = index as? String.Index else { return false }
            let prefix = haystack[haystack.startIndex..<i].suffix(6).lowercased()
            return prefix.hasSuffix("no ") || prefix.hasSuffix("0 ") || prefix.hasSuffix("zero ")
        }
    }
}

extension KubeClient {
    /// Follow one container's log.
    ///
    /// Nothing is installed to make this work: a container's stdout is captured
    /// by the runtime on the node, and the apiserver will stream it back through
    /// the kubelet. That is the same door everything else here goes through, and
    /// it is why logs need no collector in the cluster — only history does.
    ///
    /// `timestamps=true` because merging several pods into one view needs
    /// something to sort by, and the arrival order of concurrent streams is not
    /// it.
    public func logStream(namespace: String, pod: String, container: String? = nil,
                          tailLines: Int = 80, follow: Bool = true)
    -> AsyncThrowingStream<LogLine, Error> {
        AsyncThrowingStream { continuation in
            let work = Task {
                do {
                    var query = [
                        "follow": follow ? "true" : "false",
                        "tailLines": String(tailLines),
                        "timestamps": "true",
                    ]
                    if let container { query["container"] = container }
                    let request = try self.request(
                        "GET", "/api/v1/namespaces/\(namespace)/pods/\(pod)/log", query: query)
                    let (bytes, response) = try await self.streamingSession.bytes(for: request)
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(code) else {
                        throw Failure.http(code, "could not read logs for \(pod)")
                    }
                    for try await raw in bytes.lines {
                        if Task.isCancelled { break }
                        continuation.yield(Self.parse(raw, pod: pod, container: container))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    /// `2026-08-31T09:24:18.442Z the rest of the line`
    static func parse(_ raw: String, pod: String, container: String?) -> LogLine {
        var at: Date?
        var text = raw
        if let space = raw.firstIndex(of: " ") {
            let stamp = String(raw[raw.startIndex..<space])
            if let date = rfc3339.date(from: stamp) ?? rfc3339Fractional.date(from: stamp) {
                at = date
                text = String(raw[raw.index(after: space)...])
            }
        }
        return LogLine(at: at, pod: pod, container: container,
                       text: text, level: .guessed(from: text))
    }

    /// `nonisolated(unsafe)` because `ISO8601DateFormatter` is not `Sendable`,
    /// although Foundation's date formatters have been documented as safe to use
    /// from several threads for a long time. Both are configured once here and
    /// never mutated afterwards, only asked to parse.
    nonisolated(unsafe) static let rfc3339: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    nonisolated(unsafe) static let rfc3339Fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
