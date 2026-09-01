import Foundation

/// Scrapes one pod's exporter, over a tunnel it keeps.
///
/// Field's first version opened a port-forward per scrape and closed it again.
/// That works, and on the simulator it costs about a second — but on an iPad
/// over wifi it took the whole loop to roughly 5.5 s between samples, measured
/// from the apiserver's own `portforward` request counter. Almost none of that
/// was the 14 KB of metrics; it was the WebSocket upgrade through the apiserver
/// and the kubelet dialling into the pod, paid again every two seconds.
///
/// So the tunnel is held. A tunnel that breaks — the pod restarted, the kubelet
/// dropped it, the network moved — is discarded and rebuilt on the next scrape
/// rather than reported as a failure, because from the caller's side a dropped
/// tunnel and a slow one should look the same: a scrape that took longer.
public actor PodScraper {
    public let namespace: String
    public let pod: String
    public let port: Int

    private let client: KubeClient
    private var tunnel: PortForward?
    private(set) public var reconnects = 0

    public init(client: KubeClient, namespace: String, pod: String, port: Int = 9099) {
        self.client = client
        self.namespace = namespace
        self.pod = pod
        self.port = port
    }

    /// One scrape. Reuses the open tunnel, or opens one.
    ///
    /// Retried exactly once on a transport failure: the common case is a tunnel
    /// that went stale between scrapes, where a second attempt on a fresh one
    /// succeeds. A second failure is real and is reported.
    public func scrape(path: String = "/metrics") async throws -> [Sample] {
        do {
            return try await attempt(path)
        } catch let first as PortForward.Failure {
            Log.telemetry.notice("\(self.pod, privacy: .public): \(first.description, privacy: .public); rebuilding the tunnel")
            await discard()
            reconnects += 1
            do {
                return try await attempt(path)
            } catch {
                Log.telemetry.error("\(self.pod, privacy: .public): retry failed: \(String(describing: error), privacy: .public)")
                throw error
            }
        } catch {
            Log.telemetry.error("\(self.pod, privacy: .public): scrape failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    private func attempt(_ path: String) async throws -> [Sample] {
        let pipe = try await open()
        let reply = try await pipe.get(path, headers: [
            "Accept-Encoding": "gzip",
            "Accept": "text/plain",
        ])
        guard reply.status == 200 else {
            throw KubeClient.Failure.http(reply.status, String(decoding: reply.body, as: UTF8.self))
        }
        let body = reply.isGzipped ? try Gzip.inflate(reply.body) : reply.body
        return PromText.parse(body)
    }

    private func open() async throws -> PortForward {
        if let tunnel, await tunnel.isUsable { return tunnel }
        Log.telemetry.notice("\(self.pod, privacy: .public): opening a tunnel to :\(self.port, privacy: .public)")
        let fresh = try client.portForward(namespace: namespace, pod: pod, port: port)
        await fresh.connect()
        tunnel = fresh
        return fresh
    }

    private func discard() async {
        await tunnel?.close()
        tunnel = nil
    }

    /// Let go of the tunnel. Called when the app stops watching, so a pod is not
    /// left holding a kubelet stream for a screen nobody is looking at.
    public func stop() async {
        await discard()
    }
}
