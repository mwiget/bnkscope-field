import Foundation

/// Whether an address is one the device reaches over its own local network.
///
/// Both iOS and macOS gate the local subnet behind a per-app permission, and a
/// denial arrives as `NSURLErrorNotConnectedToInternet` — the same code a
/// genuinely offline device reports. The two need opposite fixes: one is "join
/// a network", the other is "grant this app Local Network access". Nothing in
/// the error separates them, so the address does.
public enum Net {

    /// RFC 1918, loopback, link-local, and mDNS names.
    public static func isLocal(host: String) -> Bool {
        let name = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if name == "localhost" || name.hasSuffix(".local") { return true }
        if name == "::1" || name.hasPrefix("fe80:") { return true }

        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        var octets: [Int] = []
        for part in parts {
            guard part.count <= 3, let value = Int(part), (0...255).contains(value) else { return false }
            octets.append(value)
        }
        switch (octets[0], octets[1]) {
        case (10, _):        return true          // 10.0.0.0/8
        case (127, _):       return true          // loopback
        case (169, 254):     return true          // link-local
        case (172, 16...31): return true          // 172.16.0.0/12
        case (192, 168):     return true          // 192.168.0.0/16
        default:             return false
        }
    }
}
