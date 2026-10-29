import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The only mutating file operation in MacVault: move one item to the Trash.
/// Returns the item's new location when the system reports it.
public struct FileTrasher: Sendable {
    public var moveToTrash: @Sendable (String) throws -> String?

    public init(moveToTrash: @escaping @Sendable (String) throws -> String?) {
        self.moveToTrash = moveToTrash
    }

    /// Finder Trash via `FileManager.trashItem`. Items can be put back from Finder until the Trash is emptied.
    public static let system = FileTrasher { path in
        #if os(macOS)
        var resulting: NSURL?
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resulting)
        return resulting?.path
        #else
        throw POSIXFailure(code: ENOTSUP)
        #endif
    }
}

public enum ExecutionError: Error, Sendable, Equatable, LocalizedError {
    case notApproved(ManifestStatus?)

    public var errorDescription: String? {
        switch self {
        case .notApproved(let status):
            return "This list has not been approved (status: \(status?.displayName ?? "missing")). Nothing was changed."
        }
    }
}

public struct ExecutionProgress: Sendable, Equatable {
    public let processed: Int
    public let total: Int
    public let currentPath: String

    public init(processed: Int, total: Int, currentPath: String) {
        self.processed = processed
        self.total = total
        self.currentPath = currentPath
    }
}

/// Executes an approved manifest, item by item.
///
/// Before moving each item it checks, in order:
/// 1. `SafetyPolicy` still allows the path for this operation and scope.
/// 2. Every parent folder is still a real folder (no symlink was swapped in since review).
/// 3. The item still exists, is not a symlink, and has the same device:inode that was reviewed.
/// 4. Directory/regular-file kind matches the operation (duplicates must be regular files).
/// 5. Duplicates: the item and the kept copy both still hash to the reviewed content, and are different files.
/// 6. The item is not in use (e.g. the app is running), via `inUseCheck`.
/// Any failed check skips the item and records why. Items are processed one at a time and each
/// outcome is persisted before the next starts; cancellation leaves remaining items untouched.
public struct OperationExecutor: Sendable {
    let store: Store
    let policy: SafetyPolicy
    let probe: FileSystemProbe
    let trasher: FileTrasher
    let hasher: ContentHasher
    /// Returns a reason when the item must not be moved right now (e.g. the application is running).
    let inUseCheck: @Sendable (OperationItem) -> String?

    public init(store: Store, policy: SafetyPolicy, probe: FileSystemProbe = .posix, trasher: FileTrasher = .system,
                hasher: ContentHasher = ContentHasher(), inUseCheck: @escaping @Sendable (OperationItem) -> String? = { _ in nil }) {
        self.store = store
        self.policy = policy
        self.probe = probe
        self.trasher = trasher
        self.hasher = hasher
        self.inUseCheck = inUseCheck
    }

    @discardableResult
    public func execute(manifestId: String,
                        progress: @Sendable (ExecutionProgress) async -> Void = { _ in }) async throws -> OperationManifest {
        guard let loaded = try await store.manifest(id: manifestId) else {
            throw OperationStoreError.manifestNotFound(manifestId)
        }
        guard loaded.status == .approved else { throw ExecutionError.notApproved(loaded.status) }
        // Atomic approved → executing; a second concurrent execute fails here.
        do { try await store.beginExecution(id: manifestId) }
        catch { throw ExecutionError.notApproved(try await store.manifest(id: manifestId)?.status) }

        var manifest = loaded
        manifest.status = .executing
        try? await store.appendAudit(AuditEvent(
            operationId: manifestId, eventType: "operation.started", severity: .notice,
            message: "\(manifest.type.displayName) started: \(manifest.items.count) item(s) to move to the Trash",
            details: ["title": manifest.title, "ruleVersion": manifest.ruleVersion ?? "none"]))

        var cancelled = false
        /// Set when an outcome could not be saved. Execution stops: nothing more is moved without a record.
        var unrecorded: OperationItem?
        let total = manifest.items.count
        for index in manifest.items.indices where manifest.items[index].status == .pending {
            if Task.isCancelled { cancelled = true; break }
            var item = manifest.items[index]
            await progress(ExecutionProgress(processed: index, total: total, currentPath: item.originalPath))
            if Task.isCancelled { cancelled = true; break }
            item.startedAt = Date()

            if let reason = revalidate(item, type: manifest.type) {
                item.status = .skipped
                item.message = reason
            } else {
                do {
                    item.resultingPath = try trasher.moveToTrash(item.originalPath)
                    item.status = .trashed
                    item.message = "Moved to the Trash"
                } catch {
                    let ns = error as NSError
                    item.status = .failed
                    item.errorDomain = (error as? POSIXFailure).map { _ in "POSIX" } ?? ns.domain
                    item.errorCode = (error as? POSIXFailure).map { Int($0.code) } ?? ns.code
                    item.message = (error as? POSIXFailure)?.message ?? ns.localizedDescription
                }
            }
            item.completedAt = Date()
            manifest.items[index] = item
            do {
                try await store.updateOperationItem(item)
            } catch {
                unrecorded = item
                break
            }
            try? await store.appendAudit(itemEvent(item))
        }

        let trashed = manifest.count(.trashed)
        let failed = manifest.count(.failed)
        let skipped = manifest.count(.skipped)
        let status: ManifestStatus
        if unrecorded != nil {
            status = trashed > 0 ? .partial : .failed
        } else if cancelled {
            status = .cancelled
        } else if trashed == total {
            status = .completed
        } else if trashed == 0 && failed > 0 {
            status = .failed
        } else if trashed == 0 {
            status = .nothingMoved
        } else {
            status = .partial
        }
        var reason: String? = status == .completed ? nil
            : "\(trashed) moved, \(skipped) skipped, \(failed) failed\(cancelled ? ", \(manifest.count(.pending)) not processed (cancelled)" : "")"
        if let unrecorded {
            let where_ = unrecorded.status == .trashed ? "It was \(unrecorded.resultingPath.map { "moved to \($0)" } ?? "moved to the Trash")" : "Its outcome was \(unrecorded.status.rawValue)"
            reason = "MacVault stopped because it could not save the outcome for \(unrecorded.originalPath). \(where_). Remaining items were not touched. \(reason ?? "")"
        }
        // Best effort: if the database is failing, the manifest is reconciled as interrupted on next launch.
        try? await store.finishExecution(id: manifestId, status: status, failureReason: reason)
        manifest.status = status
        manifest.failureReason = reason
        manifest.completedAt = Date()
        await progress(ExecutionProgress(processed: total, total: total, currentPath: ""))

        let severity: AuditSeverity
        switch status {
        case .completed: severity = .info
        case .cancelled, .nothingMoved: severity = .notice
        default: severity = unrecorded == nil ? .warning : .error
        }
        try? await store.appendAudit(AuditEvent(
            operationId: manifestId, eventType: "operation.\(status.rawValue)", severity: severity,
            message: "\(manifest.type.displayName) \(status.displayName.lowercased()): \(trashed) item(s), \(ByteFormat.string(manifest.trashedBytes)) moved to the Trash",
            details: ["trashed": "\(trashed)", "skipped": "\(skipped)", "failed": "\(failed)",
                      "pending": "\(manifest.count(.pending))"]))
        return manifest
    }

    // MARK: Revalidation

    /// Returns why the item must be skipped, or nil when it may be moved.
    func revalidate(_ item: OperationItem, type: OperationType) -> String? {
        let path = item.originalPath
        if case .denied(let why) = policy.evaluate(path, for: type, scopeRoot: item.scopeRoot) {
            return "Protected: \(why)"
        }
        let parent = (path as NSString).deletingLastPathComponent
        if PathUtilities.canonicalize(parent) != parent {
            return "A folder in its path changed since review"
        }

        let current: FileStat
        switch probe.stat(path) {
        case .failure(let failure):
            return failure.code == ENOENT ? "No longer exists" : "Could not be checked: \(failure.message)"
        case .success(let value):
            current = value
        }
        if current.kind == .symlink { return "Became a symbolic link since review" }
        guard let expected = item.resourceIdentifier, expected == current.resourceIdentifier else {
            return "Changed since review (it is a different item now)"
        }
        switch type {
        case .duplicateRemoval:
            guard current.kind == .regular else { return "No longer a regular file" }
            guard current.linkCount <= 1 else { return "Has other hard links; moving it would not free space" }
        case .appUninstall:
            guard current.kind == .directory else { return "No longer an application bundle" }
        case .cleanup, .developerCleanup, .appLeftovers:
            guard current.kind == .directory || current.kind == .regular else { return "Unsupported item type" }
        }

        if type == .duplicateRemoval, let problem = revalidateDuplicate(item, current: current) {
            return problem
        }
        if let busy = inUseCheck(item) { return busy }
        return nil
    }

    private func revalidateDuplicate(_ item: OperationItem, current: FileStat) -> String? {
        guard let expectedHash = item.contentHash, let keeper = item.keeperPath else {
            return "Missing duplicate verification data"
        }
        guard keeper != item.originalPath else { return "The kept copy is the same file" }
        guard case .success(let keeperStat) = probe.stat(keeper), keeperStat.kind == .regular else {
            return "The copy you chose to keep no longer exists"
        }
        if keeperStat.resourceIdentifier == current.resourceIdentifier {
            return "The kept copy is the same file (hard link)"
        }
        guard keeperStat.logicalSize == current.logicalSize else { return "The copies no longer have the same size" }
        do {
            guard try hasher.sha256(path: keeper) == expectedHash else { return "The copy you chose to keep has changed" }
            guard try hasher.sha256(path: item.originalPath) == expectedHash else { return "Content changed since review" }
        } catch {
            return "Content could not be verified: \((error as? POSIXFailure)?.message ?? error.localizedDescription)"
        }
        return nil
    }

    private func itemEvent(_ item: OperationItem) -> AuditEvent {
        let display = PathUtilities.abbreviatingHome(item.originalPath)
        var details = ["path": item.originalPath, "status": item.status.rawValue]
        if let resulting = item.resultingPath { details["trashPath"] = resulting }
        if let size = item.expectedSizeBytes { details["expectedBytes"] = "\(size)" }
        if let rule = item.ruleId { details["ruleId"] = rule }
        if let code = item.errorCode { details["errorCode"] = "\(code)"; details["errorDomain"] = item.errorDomain ?? "" }
        switch item.status {
        case .trashed:
            return AuditEvent(operationId: item.manifestId, eventType: "operation.item.trashed", severity: .info,
                              message: "Moved to the Trash: \(display)", details: details)
        case .skipped:
            return AuditEvent(operationId: item.manifestId, eventType: "operation.item.skipped", severity: .notice,
                              message: "Skipped \(display): \(item.message ?? "")", details: details)
        case .failed:
            return AuditEvent(operationId: item.manifestId, eventType: "operation.item.failed", severity: .error,
                              message: "Could not move \(display): \(item.message ?? "")", details: details)
        case .pending:
            return AuditEvent(operationId: item.manifestId, eventType: "operation.item.pending", severity: .info,
                              message: "Not processed: \(display)", details: details)
        }
    }
}
