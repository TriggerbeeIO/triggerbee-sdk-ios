import Foundation
import os

/// Pluggable logger so the SDK doesn't take a transitive dependency on a logging framework.
/// Most consumers wire in ``OSLogger`` (or leave ``NoOpLogger`` for release builds).
public protocol TriggerbeeLogger: Sendable {
    func debug(_ message: String, error: Error?)
    func info(_ message: String, error: Error?)
    func warn(_ message: String, error: Error?)
    func error(_ message: String, error: Error?)
}

public extension TriggerbeeLogger {
    func debug(_ message: String) { debug(message, error: nil) }
    func info(_ message: String) { info(message, error: nil) }
    func warn(_ message: String) { warn(message, error: nil) }
    func error(_ message: String) { error(message, error: nil) }
}

/// Drops everything. Default when ``TriggerbeeConfig/logger`` isn't overridden.
public struct NoOpLogger: TriggerbeeLogger {
    public init() {}
    public func debug(_ message: String, error: Error?) {}
    public func info(_ message: String, error: Error?) {}
    public func warn(_ message: String, error: Error?) {}
    public func error(_ message: String, error: Error?) {}
}

/// Routes to `os.Logger` under the `Triggerbee` subsystem. Visible in Console.app and Xcode's debug area.
public struct OSLogger: TriggerbeeLogger {
    private let logger: Logger

    public init(subsystem: String = "com.triggerbee.sdk", category: String = "Triggerbee") {
        self.logger = Logger(subsystem: subsystem, category: category)
    }

    public func debug(_ message: String, error: Error?) {
        if let error {
            logger.debug("\(message, privacy: .public) — \(error.localizedDescription, privacy: .public)")
        } else {
            logger.debug("\(message, privacy: .public)")
        }
    }

    public func info(_ message: String, error: Error?) {
        if let error {
            logger.info("\(message, privacy: .public) — \(error.localizedDescription, privacy: .public)")
        } else {
            logger.info("\(message, privacy: .public)")
        }
    }

    public func warn(_ message: String, error: Error?) {
        if let error {
            logger.warning("\(message, privacy: .public) — \(error.localizedDescription, privacy: .public)")
        } else {
            logger.warning("\(message, privacy: .public)")
        }
    }

    public func error(_ message: String, error: Error?) {
        if let error {
            logger.error("\(message, privacy: .public) — \(error.localizedDescription, privacy: .public)")
        } else {
            logger.error("\(message, privacy: .public)")
        }
    }
}
