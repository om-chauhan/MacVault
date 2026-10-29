import Foundation
import XCTest
@testable import MacVaultCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class OperationExecutorTests: XCTestCase {
    private var tree: TempTree!
    private var store: Store!
    private var trash: FakeTrash!
    private var policy: SafetyPolicy!
    private var caches: String { tree.home + "/Library/Caches" }

    override func setUp() async throws {
        tree = try TempTree()
        store = try Store.inMemory()
        trash = try FakeTrash(in: tree)
        policy = try tree.policy()
        try tree.dir("home/Library/Caches")
    }

    private func executor(inUse: @escaping @Sendable (OperationItem) -> String? = { _ in nil }) -> OperationExecutor {
        OperationExecutor(store: store, policy: policy, trasher: trash.trasher, inUseCheck: inUse)
    }

    /// A cache item reviewed "now": its current device:inode is recorded.
    private func cacheItem(_ name: String, bytes: Int = 100, manifestId: String) throws -> OperationItem {
        let path = try tree.file("home/Library/Caches/\(name)/data.bin", bytes: bytes)
        let dir = (path as NSString).deletingLastPathComponent
        return OperationItem(manifestId: manifestId, originalPath: dir, resourceIdentifier: stat(of: dir)?.resourceIdentifier,
                             expectedSizeBytes: Int64(bytes), ruleId: "user-caches", riskLevel: .low, reason: "test",
                             scopeRoot: caches)
    }

    // MARK: Approval gate

    func testDraftManifestIsNeverExecuted() async throws {
        let id = UUID().uuidString
        let item = try cacheItem("a", manifestId: id)
        try await store.createManifest(OperationManifest(id: id, type: .cleanup, title: "t", ruleVersion: nil,
                                                         estimatedBytes: 100, items: [item]))
        do {
            try await executor().execute(manifestId: id)
            XCTFail("a draft must not execute")
        } catch ExecutionError.notApproved(let status) {
            XCTAssertEqual(status, .draft)
        }
        XCTAssertTrue(trash.calls.isEmpty)
        XCTAssertTrue(exists(item.originalPath))
    }

    func testManifestExecutesOnlyOnce() async throws {
        let id = try await store.approvedManifest(.cleanup) { [self] id in [try! cacheItem("a", manifestId: id)] }
        let first = try await executor().execute(manifestId: id)
        XCTAssertEqual(first.status, .completed)
        do {
            try await executor().execute(manifestId: id)
            XCTFail("second execution must be refused")
        } catch ExecutionError.notApproved(let status) {
            XCTAssertEqual(status, .completed)
        }
        XCTAssertEqual(trash.calls.count, 1)
    }

    func testInvalidTransitionsAreRefused() async throws {
        let id = try await store.approvedManifest(.cleanup) { [self] id in [try! cacheItem("a", manifestId: id)] }
        do { try await store.approveManifest(id: id); XCTFail() } catch OperationStoreError.invalidTransition {}
        do { try await store.discardManifest(id: id); XCTFail() } catch OperationStoreError.invalidTransition {}
        do { try await store.approveManifest(id: "missing"); XCTFail() } catch OperationStoreError.manifestNotFound {}
        do {
            try await store.createManifest(OperationManifest(type: .cleanup, title: "x", ruleVersion: nil, estimatedBytes: nil, items: []))
            XCTFail("empty manifests are refused")
        } catch OperationStoreError.emptyManifest {}
    }

    // MARK: Happy path

    func testApprovedItemsAreMovedToTrashAndEveryOutcomeIsRecorded() async throws {
        let id = try await store.approvedManifest(.cleanup) { [self] id in
            [try! cacheItem("a", bytes: 10, manifestId: id), try! cacheItem("b", bytes: 20, manifestId: id)]
        }
        let result = try await executor().execute(manifestId: id)

        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.trashedBytes, 30)
        XCTAssertFalse(exists(caches + "/a"))
        XCTAssertFalse(exists(caches + "/b"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trash.directory).count, 2,
                       "items are moved, not deleted")

        let saved = try await store.manifest(id: id)
        XCTAssertEqual(saved?.status, .completed)
        XCTAssertNotNil(saved?.approvedAt)
        XCTAssertNotNil(saved?.completedAt)
        XCTAssertEqual(saved?.items.map(\.status), [.trashed, .trashed])
        XCTAssertTrue(saved?.items.allSatisfy { $0.resultingPath?.hasPrefix(trash.directory) == true } ?? false)

        let events = try await store.auditEvents().filter { $0.operationId == id }.map(\.eventType)
        XCTAssertEqual(events.filter { $0 == "operation.item.trashed" }.count, 2)
        XCTAssertTrue(events.contains("operation.started"))
        XCTAssertTrue(events.contains("operation.completed"))
    }

    // MARK: Revalidation

    func testMissingItemIsSkippedNotFailed() async throws {
        let id = try await store.approvedManifest(.cleanup) { [self] id in [try! cacheItem("gone", manifestId: id)] }
        try FileManager.default.removeItem(atPath: caches + "/gone")
        let result = try await executor().execute(manifestId: id)
        XCTAssertEqual(result.items.first?.status, .skipped)
        XCTAssertEqual(result.items.first?.message, "No longer exists")
        XCTAssertEqual(result.status, .partial)
        XCTAssertTrue(trash.calls.isEmpty)
    }

    func testReplacedItemIsSkipped() async throws {
        let id = try await store.approvedManifest(.cleanup) { [self] id in [try! cacheItem("swapped", manifestId: id)] }
        // Same path, different item (new inode) — e.g. the folder was recreated after review.
        try FileManager.default.removeItem(atPath: caches + "/swapped")
        try tree.file("home/Library/Caches/swapped/other.bin", bytes: 5)
        let result = try await executor().execute(manifestId: id)
        XCTAssertEqual(result.items.first?.status, .skipped)
        XCTAssertTrue(exists(caches + "/swapped/other.bin"))
        XCTAssertTrue(trash.calls.isEmpty)
    }

    func testItemReplacedBySymlinkIsSkippedAndTargetUntouched() async throws {
        let precious = try tree.file("home/Documents/precious.txt", bytes: 10)
        let id = try await store.approvedManifest(.cleanup) { [self] id in [try! cacheItem("link", manifestId: id)] }
        try FileManager.default.removeItem(atPath: caches + "/link")
        try FileManager.default.createSymbolicLink(atPath: caches + "/link", withDestinationPath: tree.home + "/Documents")
        let result = try await executor().execute(manifestId: id)
        XCTAssertEqual(result.items.first?.status, .skipped)
        XCTAssertTrue(exists(precious))
        XCTAssertTrue(trash.calls.isEmpty)
    }

    func testParentFolderSwappedForSymlinkIsSkipped() async throws {
        try tree.dir("home/Library/Caches/vendor")
        let path = try tree.file("home/Library/Caches/vendor/inner/data.bin", bytes: 10)
        let inner = (path as NSString).deletingLastPathComponent
        let id = try await store.approvedManifest(.cleanup) { [self] id in
            [OperationItem(manifestId: id, originalPath: inner, resourceIdentifier: stat(of: inner)?.resourceIdentifier,
                           expectedSizeBytes: 10, ruleId: "user-caches", riskLevel: .low, reason: "t", scopeRoot: caches)]
        }
        // Move the real folder away and point the parent at another location with the same layout.
        try FileManager.default.moveItem(atPath: caches + "/vendor", toPath: tree.home + "/Documents-vendor")
        try FileManager.default.createSymbolicLink(atPath: caches + "/vendor", withDestinationPath: tree.home + "/Documents-vendor")
        let result = try await executor().execute(manifestId: id)
        XCTAssertEqual(result.items.first?.status, .skipped)
        XCTAssertTrue(exists(tree.home + "/Documents-vendor/inner/data.bin"))
        XCTAssertTrue(trash.calls.isEmpty)
    }

    func testPolicyIsReappliedAtExecutionTime() async throws {
        // An item that should never have been approved (e.g. tampered database) is still refused.
        let ssh = try tree.file("home/Library/Caches/.ssh/id_ed25519", bytes: 10)
        let dir = (ssh as NSString).deletingLastPathComponent
        let docs = try tree.file("home/Documents/report.pdf", bytes: 10)
        let id = try await store.approvedManifest(.cleanup) { [self] id in [
            OperationItem(manifestId: id, originalPath: dir, resourceIdentifier: stat(of: dir)?.resourceIdentifier,
                          expectedSizeBytes: 10, ruleId: nil, riskLevel: .low, reason: "t", scopeRoot: caches),
            OperationItem(manifestId: id, originalPath: docs, resourceIdentifier: stat(of: docs)?.resourceIdentifier,
                          expectedSizeBytes: 10, ruleId: nil, riskLevel: .low, reason: "t", scopeRoot: caches),
            OperationItem(manifestId: id, originalPath: tree.home + "/Documents", resourceIdentifier: stat(of: tree.home + "/Documents")?.resourceIdentifier,
                          expectedSizeBytes: 10, ruleId: nil, riskLevel: .low, reason: "t", scopeRoot: tree.home),
        ] }
        let result = try await executor().execute(manifestId: id)
        XCTAssertEqual(result.items.map(\.status), [.skipped, .skipped, .skipped])
        XCTAssertTrue(result.items.allSatisfy { $0.message?.hasPrefix("Protected") == true })
        XCTAssertTrue(trash.calls.isEmpty)
        XCTAssertTrue(exists(ssh) && exists(docs))
    }

    func testItemWithoutRecordedIdentityIsSkipped() async throws {
        try tree.file("home/Library/Caches/x/data.bin", bytes: 1)
        let id = try await store.approvedManifest(.cleanup) { [self] id in
            [OperationItem(manifestId: id, originalPath: caches + "/x", resourceIdentifier: nil, expectedSizeBytes: 1,
                           ruleId: nil, riskLevel: .low, reason: "t", scopeRoot: caches)]
        }
        let result = try await executor().execute(manifestId: id)
        XCTAssertEqual(result.items.first?.status, .skipped)
        XCTAssertTrue(trash.calls.isEmpty)
    }

    func testInUseItemIsSkipped() async throws {
        let id = try await store.approvedManifest(.cleanup) { [self] id in [try! cacheItem("busy", manifestId: id)] }
        let result = try await executor(inUse: { _ in "The app is running" }).execute(manifestId: id)
        XCTAssertEqual(result.items.first?.status, .skipped)
        XCTAssertEqual(result.items.first?.message, "The app is running")
        XCTAssertTrue(exists(caches + "/busy"))
    }

    func testTrashFailureIsRecordedAsFailed() async throws {
        trash.failWith = EACCES
        let id = try await store.approvedManifest(.cleanup) { [self] id in [try! cacheItem("locked", manifestId: id)] }
        let result = try await executor().execute(manifestId: id)
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.items.first?.status, .failed)
        XCTAssertEqual(result.items.first?.errorCode, Int(EACCES))
        let errors = try await store.auditEvents(minimumSeverity: .error)
        XCTAssertEqual(errors.first?.eventType, "operation.item.failed")
    }

    // MARK: Cancellation & interruption

    func testCancellationLeavesRemainingItemsUntouched() async throws {
        let id = try await store.approvedManifest(.cleanup) { [self] id in
            (0..<5).map { try! cacheItem("c\($0)", manifestId: id) }
        }
        // Cancel the executing task itself from its progress callback (deterministic, no race).
        let result = try await executor().execute(manifestId: id) { progress in
            if progress.processed == 2 { withUnsafeCurrentTask { $0?.cancel() } }
        }
        XCTAssertEqual(result.status, .cancelled)
        XCTAssertEqual(result.count(.trashed), 2)
        XCTAssertEqual(result.count(.pending), 3)
        XCTAssertEqual(trash.calls.count, 2)
        for n in 2..<5 { XCTAssertTrue(exists(caches + "/c\(n)")) }
        let saved = try await store.manifest(id: id)
        XCTAssertEqual(saved?.status, .cancelled)
    }

    func testExecutingManifestIsReconciledAsInterruptedOnLaunch() async throws {
        let id = try await store.approvedManifest(.cleanup) { [self] id in [try! cacheItem("a", manifestId: id)] }
        try await store.beginExecution(id: id)   // simulate a crash mid-execution
        let reconciled = try await LaunchReconciler.run(store: store)
        XCTAssertEqual(reconciled, 1)
        let saved = try await store.manifest(id: id)
        XCTAssertEqual(saved?.status, .interrupted)
        XCTAssertEqual(saved?.items.first?.status, .pending)
        let events = try await store.auditEvents(minimumSeverity: .warning).map(\.eventType)
        XCTAssertTrue(events.contains("operation.reconciled"))
    }

    // MARK: Duplicates

    private func duplicatePair(_ a: String = "a.bin", _ b: String = "b.bin") throws -> (keeper: String, extra: String, hash: String) {
        try tree.write("home/Photos/\(a)", "same content")
        try tree.write("home/Photos/\(b)", "same content")
        let keeper = tree.home + "/Photos/" + a
        return (keeper, tree.home + "/Photos/" + b, try ContentHasher().sha256(path: keeper))
    }

    private func duplicateItem(_ pair: (keeper: String, extra: String, hash: String), manifestId: String) -> OperationItem {
        OperationItem(manifestId: manifestId, originalPath: pair.extra, resourceIdentifier: stat(of: pair.extra)?.resourceIdentifier,
                      expectedSizeBytes: 12, ruleId: "duplicate-sha256", riskLevel: .low, reason: "dup",
                      scopeRoot: tree.home, contentHash: pair.hash, keeperPath: pair.keeper)
    }

    func testDuplicateIsMovedWhenBothCopiesStillMatch() async throws {
        let pair = try duplicatePair()
        let id = try await store.approvedManifest(.duplicateRemoval) { [self] id in [duplicateItem(pair, manifestId: id)] }
        let result = try await executor().execute(manifestId: id)
        XCTAssertEqual(result.status, .completed)
        XCTAssertTrue(exists(pair.keeper))
        XCTAssertFalse(exists(pair.extra))
    }

    func testDuplicateSkippedWhenKeeperChangedOrMissing() async throws {
        let pair = try duplicatePair()
        let id = try await store.approvedManifest(.duplicateRemoval) { [self] id in [duplicateItem(pair, manifestId: id)] }
        try Data("edited!!!!!!".utf8).write(to: URL(fileURLWithPath: pair.keeper))
        let result = try await executor().execute(manifestId: id)
        XCTAssertEqual(result.items.first?.status, .skipped)
        XCTAssertTrue(exists(pair.extra), "the last good copy is never removed")

        let pair2 = try duplicatePair("c.bin", "d.bin")
        let id2 = try await store.approvedManifest(.duplicateRemoval) { [self] id in [duplicateItem(pair2, manifestId: id)] }
        try FileManager.default.removeItem(atPath: pair2.keeper)
        let result2 = try await executor().execute(manifestId: id2)
        XCTAssertEqual(result2.items.first?.status, .skipped)
        XCTAssertTrue(exists(pair2.extra))
    }

    func testDuplicateSkippedWhenItsOwnContentChanged() async throws {
        let pair = try duplicatePair()
        let id = try await store.approvedManifest(.duplicateRemoval) { [self] id in [duplicateItem(pair, manifestId: id)] }
        // Same size, different content, same inode (edited in place).
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: pair.extra))
        try handle.write(contentsOf: Data("SAME".utf8))
        try handle.close()
        let result = try await executor().execute(manifestId: id)
        XCTAssertEqual(result.items.first?.status, .skipped)
        XCTAssertEqual(result.items.first?.message, "Content changed since review")
        XCTAssertTrue(exists(pair.extra))
    }

    func testDuplicateSkippedWhenKeeperIsAHardLinkToTheItem() async throws {
        try tree.write("home/Photos/a.bin", "content")
        let keeper = tree.home + "/Photos/a.bin"
        let extra = tree.home + "/Photos/b.bin"
        XCTAssertEqual(link(keeper, extra), 0)
        let hash = try ContentHasher().sha256(path: keeper)
        let id = try await store.approvedManifest(.duplicateRemoval) { [self] id in
            [duplicateItem((keeper, extra, hash), manifestId: id)]
        }
        let result = try await executor().execute(manifestId: id)
        XCTAssertEqual(result.items.first?.status, .skipped)
        XCTAssertTrue(exists(extra))
    }

    func testDuplicateItemWithoutVerificationDataIsSkipped() async throws {
        let pair = try duplicatePair()
        let id = try await store.approvedManifest(.duplicateRemoval) { [self] id in
            [OperationItem(manifestId: id, originalPath: pair.extra, resourceIdentifier: stat(of: pair.extra)?.resourceIdentifier,
                           expectedSizeBytes: 12, ruleId: nil, riskLevel: .low, reason: "dup", scopeRoot: tree.home)]
        }
        let result = try await executor().execute(manifestId: id)
        XCTAssertEqual(result.items.first?.status, .skipped)
        XCTAssertTrue(exists(pair.extra))
    }

    func testDuplicateRemovalItemsNeverIncludeTheKeeper() throws {
        let files = (0..<3).map { DuplicateFile(path: "/x/\($0)", resourceIdentifier: "1:\($0)", modifiedAt: nil) }
        let group = DuplicateGroup(contentHash: "h", sizeBytes: 10, files: files)
        let items = group.removalItems(keeping: "/x/1", manifestId: "m", scopeRoot: "/x")
        XCTAssertEqual(items.map(\.originalPath), ["/x/0", "/x/2"])
        XCTAssertTrue(items.allSatisfy { $0.keeperPath == "/x/1" && $0.contentHash == "h" })
        XCTAssertTrue(group.removalItems(keeping: "/not/in/group", manifestId: "m", scopeRoot: "/x").isEmpty)
    }
}
