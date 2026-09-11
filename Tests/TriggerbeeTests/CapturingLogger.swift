import Foundation
@testable import Triggerbee

/// Test-only ``TriggerbeeLogger`` that records what the SDK logged, so tests can assert on
/// fail-soft paths that deliberately produce no other observable effect (an empty widget URL,
/// a rejected configuration).
final class CapturingLogger: TriggerbeeLogger, @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func debug(_ message: String, error: Error?) { record("debug", message) }
    func info(_ message: String, error: Error?) { record("info", message) }
    func warn(_ message: String, error: Error?) { record("warn", message) }
    func error(_ message: String, error: Error?) { record("error", message) }

    private func record(_ level: String, _ message: String) {
        lock.withLock { lines.append("\(level): \(message)") }
    }

    /// True when any captured line contains `needle`.
    func logged(_ needle: String) -> Bool {
        return lock.withLock { lines.contains { $0.contains(needle) } }
    }
}
