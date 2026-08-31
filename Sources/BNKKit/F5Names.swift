import Foundation

/// How BNK names the objects it reports counters for.
public enum F5Names {
    /// A virtual server or pool as it is worth plotting.
    ///
    /// The full name carries the address it listens on —
    /// `scn-cwatch-scn-cwatch-gateway-203.0.113.105-http-80-vs` — which is the
    /// least identifying part of it and the widest. Drop the address and the
    /// protocol and port that follow it, and the `-vs` / `-pool` suffix. What is
    /// left is kept whole: trimming further would merge two pools of one gateway
    /// into a single line, which is exactly the comparison a pool panel is for.
    public static func shortObjectName(_ name: String) -> String {
        var parts = name.split(separator: "-").map(String.init)
        if let i = parts.firstIndex(where: looksLikeIPv4) {
            var drop = 1
            if i + drop < parts.count, ["tcp", "udp", "http", "https", "sctp"].contains(parts[i + drop]) { drop += 1 }
            if i + drop < parts.count, Int(parts[i + drop]) != nil { drop += 1 }
            parts.removeSubrange(i ..< min(i + drop, parts.count))
        }
        if let last = parts.last, last == "vs" || last == "pool" { parts.removeLast() }
        let short = parts.joined(separator: "-")
        return short.isEmpty ? name : short
    }

    public static func looksLikeIPv4(_ part: String) -> Bool {
        let octets = part.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        return octets.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) && (Int($0) ?? 256) < 256 }
    }
}
