import Foundation
@testable import MacVaultCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension TempTree {
    /// A fake home folder inside the temp tree.
    var home: String { path("home") }

    /// Policy rooted at the fake home. System roots are cleared because the temp tree itself lives
    /// under /private; the default system roots are covered by `SafetyPolicyTests`.
    func policy(ownData: String? = nil) throws -> SafetyPolicy {
        try dir("home")
        try dir("Applications")
        return SafetyPolicy(home: home, applicationRoots: [path("Applications"), home + "/Applications"],
                            systemRoots: [], ownDataDirectory: ownData)
    }

    func write(_ relative: String, _ text: String) throws {
        let p = path(relative)
        try FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: p))
    }

    func setModified(_ relative: String, daysAgo: Double) throws {
        let date = Date().addingTimeInterval(-daysAgo * 86_400)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path(relative))
    }
}

/// A Trash inside the temp tree. Records every call; never touches the user's real Trash.
final class FakeTrash: @unchecked Sendable {
    let directory: String
    private let lock = NSLock()
    private var moved: [String] = []
    var failWith: Int32?

    init(in tree: TempTree) throws {
        directory = tree.path("FakeTrash")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    var calls: [String] { lock.lock(); defer { lock.unlock() }; return moved }

    var trasher: FileTrasher {
        FileTrasher { [self] path in
            lock.lock(); moved.append(path); let fail = failWith; lock.unlock()
            if let fail { throw POSIXFailure(code: fail) }
            let destination = directory + "/" + UUID().uuidString + "-" + (path as NSString).lastPathComponent
            guard rename(path, destination) == 0 else { throw POSIXFailure(code: errno) }
            return destination
        }
    }
}

extension Store {
    func manifestStatusForTesting(id: String) throws -> ManifestStatus? {
        try db.query("SELECT status FROM operation_manifests WHERE id = ?", [.text(id)]) {
            $0.string(0).flatMap(ManifestStatus.init(rawValue:))
        }.first ?? nil
    }

    /// Creates and approves a manifest for the given candidates.
    func approvedManifest(_ type: OperationType, _ items: (String) -> [OperationItem]) async throws -> String {
        let id = UUID().uuidString
        let manifest = OperationManifest(id: id, type: type, title: "Test", ruleVersion: RuleCatalog.version,
                                         estimatedBytes: nil, items: items(id))
        try createManifest(manifest)
        try approveManifest(id: id)
        return id
    }
}

func stat(of path: String) -> FileStat? {
    if case .success(let st) = FileSystemProbe.posix.stat(path) { return st }
    return nil
}

/// lstat-based: true for dangling symlinks too.
func exists(_ path: String) -> Bool { stat(of: path) != nil }
