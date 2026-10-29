import Foundation
#if canImport(os)
import os

/// Technical diagnostics via OSLog. User-visible actions go to the audit log in SQLite instead.
/// Paths are logged with `.private` so they are redacted in collected logs.
public enum Log {
    public static let scanner = Logger(subsystem: "com.macvault.app", category: "scanner")
    public static let persistence = Logger(subsystem: "com.macvault.app", category: "persistence")
    public static let volumes = Logger(subsystem: "com.macvault.app", category: "volumes")
    public static let app = Logger(subsystem: "com.macvault.app", category: "app")
}
#else
/// Minimal stand-in on platforms without OSLog (Linux CI). Messages are discarded.
public struct LogShim: Sendable {
    public func debug(_ message: @autoclosure () -> String) {}
    public func info(_ message: @autoclosure () -> String) {}
    public func notice(_ message: @autoclosure () -> String) {}
    public func error(_ message: @autoclosure () -> String) {}
}

public enum Log {
    public static let scanner = LogShim()
    public static let persistence = LogShim()
    public static let volumes = LogShim()
    public static let app = LogShim()
}
#endif
