import Foundation

/// A tiny inline status line shown while we wait for the model to start
/// responding — like Claude Code's "Thinking… 650ms". It writes only to the
/// current terminal line (carriage-return + clear-to-end-of-line) and clears
/// itself the moment the first event streams in. `start()`/`stop()` are both
/// idempotent and safe to call from any task; a lock makes the spinner's own
/// writes and `stop()`'s clear mutually exclusive, so no stray frame can land
/// after the line is cleared.
final class TurnSpinner: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard task == nil else { return }
        let frames = self.frames
        let begin = Date()
        task = Task { [weak self] in
            var i = 0
            while !Task.isCancelled {
                self?.tick(frame: frames[i % frames.count], begin: begin)
                i += 1
                do { try await Task.sleep(nanoseconds: 90_000_000) } catch { break }
            }
        }
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        guard task != nil else { return }
        task?.cancel()
        task = nil
        out("\r\u{001B}[K")   // return to col 0, clear to end of line
    }

    private func tick(frame: String, begin: Date) {
        lock.lock(); defer { lock.unlock() }
        guard task != nil else { return }   // already stopped → don't draw
        let ms = Int(Date().timeIntervalSince(begin) * 1000)
        let elapsed = ms < 1000 ? "\(ms)ms" : String(format: "%.1fs", Double(ms) / 1000)
        out("\r\u{001B}[2m\(frame) Thinking… \(elapsed)\u{001B}[0m\u{001B}[K")
    }
}
