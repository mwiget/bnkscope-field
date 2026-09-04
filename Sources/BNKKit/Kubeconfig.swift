import Foundation
import Yams

/// A kubeconfig, reduced to the parts Field can actually act on.
///
/// Deliberately not a faithful model of the format. bnkscope's own normalizer
/// exists because kubeconfigs in the wild carry auth shapes that need a binary
/// on PATH; on iOS there is no PATH, so those contexts are recorded with the
/// reason they cannot be used rather than half-loaded and failed later.
public struct Kubeconfig: Sendable {
    public let contexts: [Context]

    public struct Context: Sendable {
        public let name: String
        public let clusterName: String
        public let server: URL
        public let caPEM: Data?
        /// The name the server's certificate is checked against, when that is
        /// not the address dialled.
        ///
        /// A cluster reached through a forward — a lab apiserver bound to
        /// loopback, published on another address — presents a certificate for
        /// the name it knows itself by, not the one you connected to. Ignoring
        /// this field means such a cluster can only be used by turning
        /// verification off altogether, which is a much bigger hammer.
        public let tlsServerName: String?
        public let insecureSkipTLSVerify: Bool
        public let namespace: String?
        public let auth: Auth
    }

    /// What Field can present to an apiserver. `.unsupported` is a first-class
    /// case, not an error: the context is listed with its reason.
    public enum Auth: Sendable, Equatable {
        case clientCertificate(certPEM: Data, keyPEM: Data)
        case bearerToken(String)
        case unsupported(reason: String)
    }

    public enum ParseError: Error, CustomStringConvertible {
        case notAMapping
        case noContexts
        case missingCluster(String)
        case badServer(String)

        public var description: String {
            switch self {
            case .notAMapping:        return "kubeconfig is not a YAML mapping"
            case .noContexts:         return "kubeconfig lists no contexts"
            case .missingCluster(let n): return "context references cluster \"\(n)\", which is not defined"
            case .badServer(let s):   return "cluster server \"\(s)\" is not a URL"
            }
        }
    }

    public init(yaml: String) throws {
        guard let root = try Yams.load(yaml: yaml) as? [String: Any] else {
            throw ParseError.notAMapping
        }
        let clusters = Self.byName(root["clusters"], key: "cluster")
        let users    = Self.byName(root["users"], key: "user")
        let raw      = root["contexts"] as? [[String: Any]] ?? []
        guard !raw.isEmpty else { throw ParseError.noContexts }

        var out: [Context] = []
        for entry in raw {
            guard let name = entry["name"] as? String,
                  let ctx  = entry["context"] as? [String: Any],
                  let clusterName = ctx["cluster"] as? String else { continue }
            guard let cluster = clusters[clusterName] else {
                throw ParseError.missingCluster(clusterName)
            }
            guard let serverString = cluster["server"] as? String,
                  let server = URL(string: serverString) else {
                throw ParseError.badServer((cluster["server"] as? String) ?? "")
            }
            let user = (ctx["user"] as? String).flatMap { users[$0] } ?? [:]
            out.append(Context(
                name: name,
                clusterName: clusterName,
                server: server,
                caPEM: Self.pemOrFile(cluster, dataKey: "certificate-authority-data", fileKey: "certificate-authority"),
                tlsServerName: cluster["tls-server-name"] as? String,
                insecureSkipTLSVerify: (cluster["insecure-skip-tls-verify"] as? Bool) ?? false,
                namespace: ctx["namespace"] as? String,
                auth: Self.auth(from: user)))
        }
        self.contexts = out
    }

    public init(contentsOf url: URL) throws {
        try self.init(yaml: String(contentsOf: url, encoding: .utf8))
    }

    public func context(named name: String) -> Context? {
        contexts.first { $0.name == name }
    }

    /// One self-contained kubeconfig per context.
    ///
    /// A file with three contexts in it is three clusters, and after import it
    /// should be three independent things — removing one has no business
    /// touching the others. Splitting on the way in makes that true by
    /// construction, rather than by remembering which contexts were removed and
    /// filtering them out on every load.
    public static func split(yaml: String) throws -> [(name: String, yaml: String)] {
        guard let root = try Yams.load(yaml: yaml) as? [String: Any] else {
            throw ParseError.notAMapping
        }
        let clusters = byName(root["clusters"], key: "cluster")
        let users = byName(root["users"], key: "user")
        var out: [(String, String)] = []

        for entry in root["contexts"] as? [[String: Any]] ?? [] {
            guard let name = entry["name"] as? String,
                  let ctx = entry["context"] as? [String: Any],
                  let clusterName = ctx["cluster"] as? String,
                  let cluster = clusters[clusterName] else { continue }
            let userName = ctx["user"] as? String
            var document: [String: Any] = [
                "apiVersion": "v1",
                "kind": "Config",
                "clusters": [["name": clusterName, "cluster": cluster]],
                "contexts": [["name": name, "context": ctx]],
                "current-context": name,
            ]
            if let userName, let user = users[userName] {
                document["users"] = [["name": userName, "user": user]]
            }
            guard let text = try? Yams.dump(object: document) else { continue }
            out.append((name, text))
        }
        return out
    }

    // MARK: - Auth

    static func auth(from user: [String: Any]) -> Auth {
        // exec: and auth-provider: both mean "run this program", which this app
        // does not do — on any platform. The rule is the app's, not the OS's,
        // and the wording says so: this file is shared with the Mac build and
        // the Linux CLI, and "iOS runs no binaries" was being shown on a Mac.
        // Name the binary in the reason — the user has to replace it with a
        // certificate or a token, and needs to know which one is in the way.
        if let exec = user["exec"] as? [String: Any] {
            let cmd = (exec["command"] as? String) ?? "an external command"
            return .unsupported(reason: "needs `\(cmd)`, and this app runs no binaries — supply a client certificate or a bearer token instead")
        }
        if let provider = user["auth-provider"] as? [String: Any] {
            let name = (provider["name"] as? String) ?? "an auth provider"
            return .unsupported(reason: "uses the `\(name)` auth provider, which needs a helper binary — supply a client certificate or a bearer token instead")
        }
        if let token = user["token"] as? String, !token.isEmpty {
            return .bearerToken(token)
        }
        if let cert = pemOrFile(user, dataKey: "client-certificate-data", fileKey: "client-certificate"),
           let key  = pemOrFile(user, dataKey: "client-key-data",         fileKey: "client-key") {
            return .clientCertificate(certPEM: cert, keyPEM: key)
        }
        if user["username"] != nil {
            return .unsupported(reason: "uses HTTP basic auth, which Kubernetes removed in 1.19")
        }
        return .unsupported(reason: "carries no credentials Field can present")
    }

    // MARK: - Helpers

    /// `*-data` is base64 inline; the plain key is a path on the machine that
    /// wrote the file. On iOS that path does not exist, so a file reference is
    /// read when it happens to resolve (macOS, tests) and otherwise dropped —
    /// the caller reports the context as unusable rather than guessing.
    static func pemOrFile(_ m: [String: Any], dataKey: String, fileKey: String) -> Data? {
        if let b64 = m[dataKey] as? String, let d = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) {
            return d
        }
        if let path = m[fileKey] as? String {
            return try? Data(contentsOf: URL(fileURLWithPath: path))
        }
        return nil
    }

    static func byName(_ any: Any?, key: String) -> [String: [String: Any]] {
        guard let list = any as? [[String: Any]] else { return [:] }
        var out: [String: [String: Any]] = [:]
        for e in list {
            guard let name = e["name"] as? String else { continue }
            out[name] = (e[key] as? [String: Any]) ?? [:]
        }
        return out
    }
}
