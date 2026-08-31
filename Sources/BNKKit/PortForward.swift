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
        case malformed(String)

        public var description: String {
            switch self {
            case .remote(let m):    return "port-forward refused: \(m)"
            case .closed:           return "the tunnel closed before the reply was complete"
            case .malformed(let m): return "the reply could not be read: \(m)"
            }
        }
    }

    private let task: URLSessionWebSocketTask
    private let port: Int
    private var started = false
    private var atEnd = false
    private var buffer = Data()
    private var remoteError = ""

    init(task: URLSessionWebSocketTask, port: Int) {
        self.task = task
        self.port = port
    }

    public var isUsable: Bool { started && !atEnd }

    public func connect() {
        guard !started else { return }
        started = true
        task.resume()
    }

    public func close() {
        atEnd = true
        task.cancel(with: .goingAway, reason: nil)
    }

    // MARK: - Reading

    /// Pull one more frame's payload into the buffer. False once the data
    /// channel has ended.
    private func fill() async -> Bool {
        while true {
            if atEnd { return false }
            let message: URLSessionWebSocketTask.Message
            do { message = try await task.receive() } catch { atEnd = true; return false }
            guard case .data(let frame) = message, let channel = frame.first else { continue }
            let payload = frame.dropFirst()
            switch channel {
            case 0:
                // Each channel opens with its port number; that is not payload.
                if payload.count == 2, isPortAck(payload) { continue }
                guard !payload.isEmpty else { continue }
                buffer.append(payload)
                return true
            case 1:
                if payload.count == 2, isPortAck(payload) { continue }
                remoteError += String(decoding: payload, as: UTF8.self)
            default:
                continue
            }
        }
    }

    private func isPortAck(_ payload: Data.SubSequence) -> Bool {
        let lo = UInt16(payload[payload.startIndex])
        let hi = UInt16(payload[payload.index(after: payload.startIndex)])
        return lo | (hi << 8) == UInt16(port)
    }

    private func take(_ n: Int) async throws -> Data {
        while buffer.count < n {
            if await !fill() { throw failure() }
        }
        let out = buffer.prefix(n)
        buffer.removeFirst(n)
        return Data(out)
    }

    /// One CRLF-terminated line, without the terminator.
    private func takeLine() async throws -> String {
        let crlf = Data([13, 10])
        while true {
            if let r = buffer.range(of: crlf) {
                let line = buffer[buffer.startIndex..<r.lowerBound]
                let text = String(decoding: line, as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex..<r.upperBound)
                return text
            }
            if await !fill() { throw failure() }
        }
    }

    private func failure() -> Failure {
        remoteError.isEmpty ? .closed : .remote(remoteError)
    }

    // MARK: - HTTP

    /// A GET over the tunnel, leaving the connection open for the next one.
    ///
    /// Keeping it open is the whole point: a fresh port-forward per scrape means
    /// a WebSocket upgrade through the apiserver and a new connection into the
    /// pod every time, which on a real device over wifi cost several seconds —
    /// far more than reading the 14 KB body.
    ///
    /// The reply is read frame by frame rather than "until the peer hangs up",
    /// which is what a keep-alive connection rules out. Both framings the
    /// exporter can produce are handled: `Content-Length` for a body Go buffered,
    /// and chunked for one it streamed — which is what a gzipped scrape is, since
    /// Go cannot know the compressed length in advance.
    public func get(_ path: String, headers: [String: String] = [:]) async throws -> HTTPReply {
        connect()
        var head = "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n"
        for (k, v) in headers.sorted(by: { $0.key < $1.key }) { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var framed = Data([0])
        framed.append(Data(head.utf8))
        do { try await task.send(.data(framed)) } catch { atEnd = true; throw failure() }

        let statusLine = try await takeLine()
        let parts = statusLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2, let status = Int(parts[1]) else {
            throw Failure.malformed("bad status line \"\(statusLine)\"")
        }

        var fields: [String: String] = [:]
        while true {
            let line = try await takeLine()
            if line.isEmpty { break }
            guard let c = line.firstIndex(of: ":") else { continue }
            fields[String(line[line.startIndex..<c]).lowercased()] =
                String(line[line.index(after: c)...]).trimmingCharacters(in: .whitespaces)
        }

        let body: Data
        if fields["transfer-encoding"]?.lowercased().contains("chunked") == true {
            body = try await takeChunkedBody()
        } else if let length = fields["content-length"].flatMap(Int.init) {
            body = try await take(length)
        } else {
            // No framing at all means the body ends when the connection does.
            while await fill() {}
            body = buffer
            buffer.removeAll()
            atEnd = true
        }

        // Honour a peer that asked to close, so the next call reconnects rather
        // than writing into a socket that is going away.
        if fields["connection"]?.lowercased().contains("close") == true { atEnd = true }
        return HTTPReply(status: status, headers: fields, body: body)
    }

    /// RFC 9112 §7.1: each chunk is a hex length, CRLF, that many bytes, CRLF.
    /// A zero length ends the body, optionally followed by trailers.
    private func takeChunkedBody() async throws -> Data {
        var out = Data()
        while true {
            let header = try await takeLine()
            let hex = header.split(separator: ";").first.map(String.init) ?? header
            guard let size = Int(hex.trimmingCharacters(in: .whitespaces), radix: 16) else {
                throw Failure.malformed("chunk size \"\(header)\"")
            }
            if size == 0 {
                while !(try await takeLine()).isEmpty {}   // trailers, usually none
                return out
            }
            out.append(try await take(size))
            _ = try await takeLine()                       // CRLF after the chunk
        }
    }
}

/// The pieces of an HTTP/1.1 response Field needs.
public struct HTTPReply: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data

    /// `true` when the peer said the body is gzipped. It is up to the caller to
    /// inflate — this type does not guess at content.
    public var isGzipped: Bool {
        headers["content-encoding"]?.lowercased().contains("gzip") ?? false
    }

    public init(status: Int, headers: [String: String], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}
