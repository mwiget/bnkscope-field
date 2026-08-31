import Foundation
import Security

/// One authenticated connection to one apiserver.
///
/// Everything Field does to a cluster goes through here, because the apiserver is
/// the only address it is guaranteed to be able to reach: on the clusters this
/// was built against, the control plane has no route to the pod network, so
/// `services/proxy` and `pods/proxy` both time out. What does work is anything
/// the apiserver forwards to the kubelet — logs, exec, port-forward — so those
/// are the transport, and a pod's own port is reached by tunnelling rather than
/// by dialling it.
public final class KubeClient: NSObject, Sendable {
    public let context: Kubeconfig.Context
    private let session: URLSession
    private let auth: Authenticator

    public init(context: Kubeconfig.Context, tag: String? = nil) throws {
        self.context = context
        let identity: SecIdentity?
        switch context.auth {
        case .clientCertificate(let cert, let key):
            identity = try Identity.makeIdentity(certPEM: cert, keyPEM: key,
                                                 tag: tag ?? "bnkscope.field.\(context.name)")
        case .bearerToken, .unsupported:
            identity = nil
        }
        let anchors = try context.caPEM.map { try Identity.certificates(fromPEM: $0) } ?? []
        self.auth = Authenticator(identity: identity, anchors: anchors,
                                  insecure: context.insecureSkipTLSVerify)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpAdditionalHeaders = ["User-Agent": "bnkscope-field/0.1"]
        cfg.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: cfg, delegate: auth, delegateQueue: nil)
        super.init()
    }

    public enum Failure: Error, CustomStringConvertible {
        case unusable(String)
        case http(Int, String)

        public var description: String {
            switch self {
            case .unusable(let why):     return why
            case .http(let code, let b): return "apiserver returned \(code): \(b.prefix(400))"
            }
        }
    }

    // MARK: - REST

    public func request(_ method: String, _ path: String, query: [String: String] = [:],
                        body: Data? = nil, contentType: String? = nil) throws -> URLRequest {
        var comps = URLComponents(url: context.server.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }.sorted { $0.name < $1.name }
        }
        var r = URLRequest(url: comps.url!)
        r.httpMethod = method
        r.httpBody = body
        if let contentType { r.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if case .bearerToken(let t) = context.auth { r.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        if case .unsupported(let why) = context.auth { throw Failure.unusable(why) }
        return r
    }

    @discardableResult
    public func get(_ path: String, query: [String: String] = [:]) async throws -> Data {
        let (data, response) = try await session.data(for: try request("GET", path, query: query))
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw Failure.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    public func getJSON<T: Decodable>(_ type: T.Type, _ path: String, query: [String: String] = [:]) async throws -> T {
        try Self.decoder.decode(T.self, from: try await get(path, query: query))
    }

    /// Kubernetes writes RFC 3339, usually to the second but with fractional
    /// seconds on some resources, and `.iso8601` rejects the fractional form.
    /// A timestamp that cannot be read should not fail the whole list.
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            if let date = plain.date(from: s) ?? fractional.date(from: s) { return date }
            throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(),
                                                   debugDescription: "not an RFC 3339 timestamp: \(s)")
        }
        return d
    }()

    // MARK: - Upgraded channels

    /// A WebSocket onto a pod subresource. `v5.channel.k8s.io` for exec,
    /// `v4.channel.k8s.io` for port-forward — both answer 101 on 1.30+.
    public func webSocket(_ path: String, query: [String: String], protocols: [String]) throws -> URLSessionWebSocketTask {
        var comps = URLComponents(url: context.server.appending(path: path), resolvingAgainstBaseURL: false)!
        comps.scheme = context.server.scheme == "https" ? "wss" : "ws"
        comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }.sorted { $0.name < $1.name }
        var r = URLRequest(url: comps.url!)
        if case .bearerToken(let t) = context.auth { r.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        if case .unsupported(let why) = context.auth { throw Failure.unusable(why) }
        r.setValue(protocols.joined(separator: ", "), forHTTPHeaderField: "Sec-WebSocket-Protocol")
        return session.webSocketTask(with: r)
    }

    public func portForward(namespace: String, pod: String, port: Int) throws -> PortForward {
        let task = try webSocket("/api/v1/namespaces/\(namespace)/pods/\(pod)/portforward",
                                 query: ["ports": String(port)],
                                 protocols: [PortForward.subprotocol])
        return PortForward(task: task, port: port)
    }
}

/// The URLSession delegate that answers both TLS challenges.
///
/// A kubeconfig names its own CA, and that CA is the only one that should be
/// trusted for this server — not the system roots, which would let anything
/// with a public certificate impersonate a lab apiserver.
/// `@unchecked` because `SecIdentity` and `SecCertificate` are CoreFoundation
/// types that Swift 6 cannot see as `Sendable`. They are immutable once created
/// and the Security framework documents them as thread-safe; these three fields
/// are `let` and never mutated after init, so the guarantee holds by
/// construction rather than by convention.
private final class Authenticator: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    let identity: SecIdentity?
    let anchors: [SecCertificate]
    let insecure: Bool

    init(identity: SecIdentity?, anchors: [SecCertificate], insecure: Bool) {
        self.identity = identity
        self.anchors = anchors
        self.insecure = insecure
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler)
    }

    private func handle(_ challenge: URLAuthenticationChallenge,
                        _ done: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if ProcessInfo.processInfo.environment["BNKFIELD_DEBUG"] != nil {
            FileHandle.standardError.write(Data("challenge: \(challenge.protectionSpace.authenticationMethod) identity=\(identity != nil)\n".utf8))
        }
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodClientCertificate:
            guard let identity else { return done(.performDefaultHandling, nil) }
            done(.useCredential, URLCredential(identity: identity, certificates: nil, persistence: .forSession))

        case NSURLAuthenticationMethodServerTrust:
            guard let trust = challenge.protectionSpace.serverTrust else {
                return done(.cancelAuthenticationChallenge, nil)
            }
            if insecure { return done(.useCredential, URLCredential(trust: trust)) }
            guard !anchors.isEmpty else { return done(.performDefaultHandling, nil) }
            SecTrustSetAnchorCertificates(trust, anchors as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
            var err: CFError?
            if SecTrustEvaluateWithError(trust, &err) {
                done(.useCredential, URLCredential(trust: trust))
            } else {
                done(.cancelAuthenticationChallenge, nil)
            }

        default:
            done(.performDefaultHandling, nil)
        }
    }
}
