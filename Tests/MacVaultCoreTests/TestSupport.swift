import Foundation
import XCTest
@testable import MacVaultCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Isolated temporary directory. Every filesystem test works only inside one of these —
/// never against the developer's home directory.
final class TempTree {
    let root: String

    init() throws {
        let base = PathUtilities.canonicalize(NSTemporaryDirectory())
        root = base + "/macvault-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    deinit {
        // Restore permissions so cleanup of the fixture itself succeeds.
        if let e = FileManager.default.enumerator(atPath: root) {
            for case let rel as String in e { chmod(root + "/" + rel, 0o755) }
        }
        try? FileManager.default.removeItem(atPath: root)
    }

    func path(_ relative: String) -> String { root + "/" + relative }

    @discardableResult
    func file(_ relative: String, bytes: Int) throws -> String {
        let p = path(relative)
        try FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: p, contents: Data(count: bytes)) else {
            throw POSIXFailure(code: errno)
        }
        return p
    }

    func dir(_ relative: String) throws {
        try FileManager.default.createDirectory(atPath: path(relative), withIntermediateDirectories: true)
    }

    func symlink(_ relative: String, to destination: String) throws {
        try FileManager.default.createSymbolicLink(atPath: path(relative), withDestinationPath: destination)
    }
}

/// Thread-safe collector for progress callbacks.
final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ScanProgress] = []
    func append(_ p: ScanProgress) { lock.lock(); items.append(p); lock.unlock() }
    var all: [ScanProgress] { lock.lock(); defer { lock.unlock() }; return items }
}
