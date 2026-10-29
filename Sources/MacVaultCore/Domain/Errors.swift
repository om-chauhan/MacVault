import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A POSIX errno captured at the point of failure.
public struct POSIXFailure: Error, Sendable, Equatable {
    public let code: Int32
    public init(code: Int32) { self.code = code }

    public var message: String { String(cString: strerror(code)) }
    public var isPermissionDenied: Bool { code == EACCES || code == EPERM }
}

public enum ScanError: Error, Sendable, Equatable, LocalizedError {
    case rootUnavailable(path: String, code: Int32)
    case rootNotDirectory(path: String)

    public var errorDescription: String? {
        switch self {
        case let .rootUnavailable(path, code):
            let reason = POSIXFailure(code: code)
            if reason.isPermissionDenied {
                return "MacVault does not have permission to read \(path). Choose the folder again or grant access in System Settings › Privacy & Security."
            }
            return "\(path) could not be opened: \(reason.message)."
        case let .rootNotDirectory(path):
            return "\(path) is not a folder."
        }
    }
}

public enum DatabaseError: Error, Sendable, Equatable, LocalizedError {
    case openFailed(code: Int32, message: String)
    case prepareFailed(code: Int32, message: String, sql: String)
    case stepFailed(code: Int32, message: String)
    case migrationFailed(version: Int, message: String)
    case invalidValue(column: String)

    public var errorDescription: String? {
        switch self {
        case let .openFailed(code, message): return "Database could not be opened (\(code)): \(message)"
        case let .prepareFailed(code, message, _): return "Database statement failed to prepare (\(code)): \(message)"
        case let .stepFailed(code, message): return "Database write failed (\(code)): \(message)"
        case let .migrationFailed(version, message): return "Database migration \(version) failed: \(message)"
        case let .invalidValue(column): return "Database contains an invalid value in \(column)"
        }
    }
}
