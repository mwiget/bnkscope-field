import Foundation
import Observation
import BNKKit

/// One command's output.
struct ExecRun: Identifiable {
    let id = UUID()
    let command: String
    let container: String
    var lines: [Line] = []
    var finished = false
    var failure: String?

    struct Line: Identifiable, Hashable {
        let id = UUID()
        let text: String
        let isError: Bool
    }
}

/// Runs commands in a container and keeps what they printed.
@Observable
@MainActor
final class ExecEngine {
    private(set) var runs: [ExecRun] = []
    private(set) var running = false
    private var task: Task<Void, Never>?

    /// Enough to look back over a short investigation without holding a session
    /// of output in memory forever.
    static let historyLimit = 40

    func run(_ command: [String], container: String,
             namespace: String, pod: String, client: KubeClient) {
        guard !command.isEmpty else { return }
        task?.cancel()
        running = true
        runs.append(ExecRun(command: Argv.join(command), container: container))
        if runs.count > Self.historyLimit { runs.removeFirst(runs.count - Self.historyLimit) }
        let index = runs.count - 1

        task = Task { [weak self] in
            do {
                for try await chunk in client.exec(namespace: namespace, pod: pod,
                                                   container: container, command: command) {
                    guard let self, !Task.isCancelled else { return }
                    self.append(chunk, at: index)
                }
                self?.finish(at: index, failure: nil)
            } catch {
                self?.finish(at: index, failure: TelemetryEngine.brief(error))
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        running = false
    }

    func clear() {
        cancel()
        runs.removeAll()
    }

    /// Output arrives in arbitrarily sized pieces, not lines — a chunk can end
    /// mid-line and the next one continues it. Splitting each chunk on its own
    /// would break a table row in half.
    private func append(_ chunk: Exec.Chunk, at index: Int) {
        guard runs.indices.contains(index) else { return }
        let isError = chunk.source == .stderr
        var pieces = chunk.text.components(separatedBy: "\n")
        if let first = pieces.first, let last = runs[index].lines.last,
           last.isError == isError, !runs[index].lines.isEmpty, !first.isEmpty,
           !(runs[index].lines.last?.text.isEmpty ?? true) || first.isEmpty {
            // Continue the partial line the previous chunk ended on.
            runs[index].lines[runs[index].lines.count - 1] =
                ExecRun.Line(text: last.text + first, isError: isError)
            pieces.removeFirst()
        }
        for piece in pieces {
            runs[index].lines.append(ExecRun.Line(text: piece, isError: isError))
        }
    }

    private func finish(at index: Int, failure: String?) {
        guard runs.indices.contains(index) else { return }
        runs[index].finished = true
        runs[index].failure = failure
        // Commands that print nothing and exit are common; a trailing blank
        // line from the final newline is not output.
        if runs[index].lines.last?.text.isEmpty == true { runs[index].lines.removeLast() }
        running = false
    }
}
