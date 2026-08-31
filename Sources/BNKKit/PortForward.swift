import Foundation

/// A TCP tunnel into a pod, over `pods/portforward`.
///
/// This is what lets Field scrape a port nothing outside the pod can dial. TMM
/// hooks inbound TCP on its dataplane interfaces, so the exporter's :9099 is
/// unreachable from off the pod — but port-forward is served by the kubelet,
/// which enters the pod's network namespace and connects to loopback inside it.
/// The hooking never sees it. Verified against a live f5-tmm pod: 200, 2435
/// samples.
///
/// The framing is `v4.channel.k8s.io`: every binary message is one channel byte
/// followed by payload. Port *n* of the request owns channels 2n (data) and
/// 2n+1 (error), and the first message on each carries that port as a
/// little-endian uint16 so a client forwarding several ports can tell them apart.
/// One port is forwarded here, so channel 0 is the connection and channel 1 is
/// how the kubelet reports that it could not open it.
public actor PortForward {
    public static let subprotocol = "v4.channel.k8s.io"

    public enum Failure: Error, CustomStringConvertible {
        case remote(String)
        case closed
        case notText

        public var description: String {
            switch self {
            case .remote(let m): return "port-forward refused: \(m)"
            case .closed:        return "the tunnel closed before the reply was complete"
            case .notText:       return "the reply was not valid UTF-8"
            }
        }
    }

    private let task: URLSessionWebSocketTask
    private let port: Int
    private var started = false
    private var pendingError = Data()

    init(task: URLSessionWebSocketTask, port: Int) {
        self.task = task
        self.port = port
    }

    public func connect() {
        guard !started else { return }
        started = true
        task.resume()
    }

    public func close() {
        task.cancel(with: .goingAway, reason: nil)
    }

    /// Write bytes to the pod's socket.
    public func send(_ data: Data) async throws {
        var framed = Data([0])            // channel 0 — data for the first port
        framed.append(data)
        try await task.send(.data(framed))
    }

    /// One inbound frame's payload, or nil once the data channel has closed.
    ///
    /// The port acknowledgement each channel opens with is consumed here rather
    /// than surfaced: it repeats what the caller already asked for.
    private func receiveFrame() async throws -> Data? {
        while true {
            let message: URLSessionWebSocketTask.Message
            do { message = try await task.receive() } catch { return nil }
            guard case .data(let frame) = message, let channel = frame.first else { continue }
            let payload = frame.dropFirst()
            switch channel {
            case 0:
                // The channel opens with its port number; everything after is the stream.
                if payload.count == 2, UInt16(payload[payload.startIndex]) |
                                       (UInt16(payload[payload.index(after: payload.startIndex)]) << 8) == UInt16(port) {
                    continue
                }
                return Data(payload)
            case 1:
                if payload.count == 2 { continue }        // the same acknowledgement on the error channel
                pendingError.append(contentsOf: payload)
            default:
                continue
            }
        }
    }

    /// A minimal HTTP/1.1 GET over the tunnel.
    ///
    /// URLSession cannot be pointed at a WebSocket-framed socket, so the request
    /// is written by hand. `Connection: close` is deliberate: it makes the end of
    /// the body the end of the stream, which is a great deal less to get wrong
    /// than chunked framing, and every request here is a one-shot scrape anyway.
    public func httpGet(_ path: String, headers: [String: String] = [:]) async throws -> HTTPReply {
        connect()
        var head = "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\n"
        for (k, v) in headers.sorted(by: { $0.key < $1.key }) { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        try await send(Data(head.utf8))

        var raw = Data()
        while let chunk = try await receiveFrame() { raw.append(chunk) }
        if raw.isEmpty {
            let why = String(data: pendingError, encoding: .utf8) ?? ""
            throw why.isEmpty ? Failure.closed : Failure.remote(why)
        }
        return try HTTPReply(raw: raw)
    }
}

/// The pieces of an HTTP/1.1 response Field needs, parsed off the wire.
public struct HTTPReply: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data

    /// `true` when the peer said the body is gzipped. It is up to the caller to
    /// inflate — this type does not guess at content.
    public var isGzipped: Bool {
        headers["content-encoding"]?.lowercased().contains("gzip") ?? false
    }

    init(raw: Data) throws {
        let sep = Data("\r\n\r\n".utf8)
        guard let r = raw.range(of: sep) else { throw PortForward.Failure.closed }
        guard let head = String(data: raw[raw.startIndex..<r.lowerBound], encoding: .utf8) else {
            throw PortForward.Failure.notText
        }
        var lines = head.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst().split(separator: " ", maxSplits: 2).map(String.init)
        self.status = statusLine.count > 1 ? Int(statusLine[1]) ?? 0 : 0
        var h: [String: String] = [:]
        for line in lines {
            guard let c = line.firstIndex(of: ":") else { continue }
            h[String(line[line.startIndex..<c]).lowercased()] =
                String(line[line.index(after: c)...]).trimmingCharacters(in: .whitespaces)
        }
        self.headers = h
        self.body = Data(raw[r.upperBound...])
    }
}
