import Foundation

/// One sample from an exposition-format scrape.
public struct Sample: Sendable, Equatable {
    public let name: String
    public let labels: [String: String]
    public let value: Double

    /// The series key: the name plus its labels, sorted. Two scrapes of the same
    /// series produce the same key, which is what makes a rate computable.
    public var seriesKey: String {
        let l = labels.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        return l.isEmpty ? name : "\(name){\(l)}"
    }
}

/// A parser for the Prometheus text exposition format, 0.0.4.
///
/// Field parses scrapes itself because there is no Prometheus in the Direct
/// path: it holds the last two scrapes and derives rates from them, the same
/// arithmetic `rate()` would do server-side. Only what the exporter emits is
/// handled — gauges, no histograms or summaries, no exemplars — because that is
/// the whole of what it produces, and a parser that pretends to more than it was
/// tested against is a liability.
public enum PromText {
    public static func parse(_ text: String) -> [Sample] {
        var out: [Sample] = []
        out.reserveCapacity(2048)
        text.enumerateLines { line, _ in
            guard let s = parseLine(line) else { return }
            out.append(s)
        }
        return out
    }

    public static func parse(_ data: Data) -> [Sample] {
        parse(String(decoding: data, as: UTF8.self))
    }

    static func parseLine(_ line: String) -> Sample? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }

        let name: Substring
        var labels: [String: String] = [:]
        var rest: Substring

        if let open = trimmed.firstIndex(of: "{") {
            guard let close = trimmed[open...].firstIndex(of: "}") else { return nil }
            name = trimmed[trimmed.startIndex..<open]
            labels = parseLabels(trimmed[trimmed.index(after: open)..<close])
            rest = trimmed[trimmed.index(after: close)...]
        } else {
            guard let sp = trimmed.firstIndex(of: " ") else { return nil }
            name = trimmed[trimmed.startIndex..<sp]
            rest = trimmed[sp...]
        }

        // value, then an optional timestamp the exporter never sets.
        let fields = rest.split(separator: " ", omittingEmptySubsequences: true)
        guard let first = fields.first, let value = parseValue(first) else { return nil }
        return Sample(name: String(name), labels: labels, value: value)
    }

    static func parseValue(_ s: Substring) -> Double? {
        switch s {
        case "NaN":  return .nan
        case "+Inf": return .infinity
        case "-Inf": return -.infinity
        default:     return Double(s)
        }
    }

    /// `a="1",b="2"` — values are quoted and may contain escaped quotes and
    /// commas, so this walks the string rather than splitting on separators.
    static func parseLabels(_ s: Substring) -> [String: String] {
        var out: [String: String] = [:]
        var i = s.startIndex
        while i < s.endIndex {
            while i < s.endIndex, s[i] == " " || s[i] == "," { i = s.index(after: i) }
            guard let eq = s[i...].firstIndex(of: "=") else { break }
            let key = String(s[i..<eq]).trimmingCharacters(in: .whitespaces)
            var j = s.index(after: eq)
            guard j < s.endIndex, s[j] == "\"" else { break }
            j = s.index(after: j)
            var value = ""
            while j < s.endIndex, s[j] != "\"" {
                if s[j] == "\\", s.index(after: j) < s.endIndex {
                    j = s.index(after: j)
                    switch s[j] {
                    case "n": value.append("\n")
                    case "t": value.append("\t")
                    default:  value.append(s[j])
                    }
                } else {
                    value.append(s[j])
                }
                j = s.index(after: j)
            }
            out[key] = value
            i = j < s.endIndex ? s.index(after: j) : s.endIndex
        }
        return out
    }
}
