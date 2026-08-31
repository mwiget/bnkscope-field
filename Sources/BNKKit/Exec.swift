import Foundation

/// Running a command inside a container, over `pods/exec`.
///
/// The framing is `v5.channel.k8s.io`, the same shape as port-forward's: one
/// channel byte then payload. Here channel 0 is stdin, 1 stdout, 2 stderr, and 3
/// carries a JSON `Status` at the end saying whether the command succeeded — the
/// only place an exit code appears, since the WebSocket closes cleanly either
/// way.
///
/// No TTY is requested, and that is a deliberate limit rather than an oversight.
/// A TTY means a terminal emulator: cursor addressing, scroll regions, the
/// alternate screen. What this is for is `tmctl`, `configview` and `bdt_cli` —
/// commands that print and exit — and pretending to be a shell that cannot run
/// `vi` would be worse than not offering one.
public enum Exec {
    public struct Chunk: Sendable {
        public enum Source: Sendable { case stdout, stderr }
        public let source: Source
        public let text: String
    }

    public enum Failure: Error, CustomStringConvertible {
        case failed(String)
        public var description: String {
            switch self { case .failed(let m): return m }
        }
    }

    /// What the apiserver reports on channel 3 when the command is done.
    struct Status: Decodable {
        let status: String?
        let message: String?
        let reason: String?
    }
}

extension KubeClient {
    /// Run `command` and stream its output.
    ///
    /// The stream finishes when the command exits. A non-zero exit arrives as a
    /// thrown `Exec.Failure` carrying the apiserver's own message, which is
    /// where the exit code lives.
    public func exec(namespace: String, pod: String, container: String?,
                     command: [String]) -> AsyncThrowingStream<Exec.Chunk, Error> {
        AsyncThrowingStream { continuation in
            let work = Task {
                var items = [
                    URLQueryItem(name: "stdout", value: "true"),
                    URLQueryItem(name: "stderr", value: "true"),
                    URLQueryItem(name: "stdin", value: "false"),
                    URLQueryItem(name: "tty", value: "false"),
                ]
                if let container { items.append(URLQueryItem(name: "container", value: container)) }
                items.append(contentsOf: command.map { URLQueryItem(name: "command", value: $0) })

                do {
                    let task = try webSocket("/api/v1/namespaces/\(namespace)/pods/\(pod)/exec",
                                             items: items, protocols: ["v5.channel.k8s.io"])
                    task.resume()
                    defer { task.cancel(with: .goingAway, reason: nil) }

                    var status: Exec.Status?
                    while !Task.isCancelled {
                        let message: URLSessionWebSocketTask.Message
                        do { message = try await task.receive() } catch { break }
                        guard case .data(let frame) = message, let channel = frame.first else { continue }
                        let payload = Data(frame.dropFirst())
                        guard !payload.isEmpty else { continue }
                        switch channel {
                        case 1:
                            continuation.yield(.init(source: .stdout, text: String(decoding: payload, as: UTF8.self)))
                        case 2:
                            continuation.yield(.init(source: .stderr, text: String(decoding: payload, as: UTF8.self)))
                        case 3:
                            status = try? JSONDecoder().decode(Exec.Status.self, from: payload)
                        default:
                            continue
                        }
                    }
                    // "Success" is the only status that is not a problem. A
                    // non-zero exit arrives here as Failure with the reason.
                    if let status, status.status != "Success" {
                        throw Exec.Failure.failed(status.message ?? status.reason ?? "the command failed")
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }
}
