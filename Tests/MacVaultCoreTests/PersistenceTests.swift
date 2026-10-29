import Foundation
import XCTest
@testable import MacVaultCore

final class MigrationTests: XCTestCase {
    func testFreshDatabaseIsAtLatestVersionWithForeignKeys() async throws {
        let store = try Store.inMemory()
        let version = try await store.schemaVersion()
        XCTAssertEqual(version, Migrations.all.map(\.version).max())
        let fk = try await store.foreignKeysEnabled()
        XCTAssertTrue(fk)
    }

    func testUpgradeFromV1PreservesData() throws {
        let t = try TempTree()
        let path = t.path("upgrade.sqlite")
        do {
            let db = try SQLiteConnection(path: path)
            XCTAssertEqual(try Migrations.migrate(db, migrations: [Migrations.v1]), 1)
            try db.run("INSERT INTO scan_sessions (id, scope_description, status, started_at, files_visited) VALUES (?, ?, ?, ?, ?)",
                       [.text("old"), .text("Legacy scan"), .text("completed"), .date(Date()), .integer(42)])
        }
        let db = try SQLiteConnection(path: path)
        XCTAssertEqual(try Migrations.migrate(db), 2)
        let files = try db.query("SELECT files_visited, symlinks_skipped, root_path FROM scan_sessions WHERE id = 'old'") {
            ($0.int(0), $0.int(1), $0.string(2))
        }
        XCTAssertEqual(files.first?.0, 42)
        XCTAssertEqual(files.first?.1, 0, "new NOT NULL columns get their defaults")
        XCTAssertNil(files.first?.2, "unknown values stay NULL")
    }

    func testFailingMigrationRollsBackCompletely() throws {
        let db = try SQLiteConnection(path: ":memory:")
        try Migrations.migrate(db, migrations: [Migrations.v1])
        let broken = Migration(version: 2, name: "broken", sql: """
        CREATE TABLE should_not_survive (id INTEGER);
        THIS IS NOT SQL;
        """)
        XCTAssertThrowsError(try Migrations.migrate(db, migrations: [Migrations.v1, broken])) { error in
            guard case DatabaseError.migrationFailed(let v, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(v, 2)
        }
        XCTAssertEqual(try Migrations.currentVersion(db), 1)
        let leftovers = try db.query("SELECT name FROM sqlite_master WHERE name = 'should_not_survive'") { $0.string(0) }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testMigrationIsIdempotent() throws {
        let db = try SQLiteConnection(path: ":memory:")
        XCTAssertEqual(try Migrations.migrate(db), 2)
        XCTAssertEqual(try Migrations.migrate(db), 2)
    }

    func testForeignKeyIsEnforced() throws {
        let db = try SQLiteConnection(path: ":memory:")
        try Migrations.migrate(db)
        XCTAssertThrowsError(try db.run("""
        INSERT INTO file_findings (id, scan_id, path, category, risk_level, eligibility_status, observed_at)
        VALUES ('f', 'no-such-scan', '/x', 'largeFile', 'notAssessed', 'reviewOnly', '2026-01-01T00:00:00.000Z')
        """))
    }
}

final class StoreTests: XCTestCase {
    private func sampleResult(root: String = "/scan/root", status: ScanStatus = .partial) -> ScanResult {
        var c = ScanCounters()
        c.filesVisited = 10; c.directoriesVisited = 3; c.logicalBytes = 5_000; c.allocatedBytes = 8_192
        c.inaccessibleItems = 1; c.symlinksSkipped = 2; c.excludedItems = 4; c.mountPointsSkipped = 1
        return ScanResult(
            rootPath: root, status: status, counters: c,
            largeFiles: [
                LargeFileRecord(path: root + "/big.mov", logicalSizeBytes: 4_000, allocatedSizeBytes: nil,
                                modifiedAt: Date(timeIntervalSince1970: 1_700_000_000), resourceIdentifier: "1:2"),
            ],
            topLevel: [DirectoryAggregate(name: "Movies", path: root + "/Movies", isDirectory: true,
                                          logicalBytes: 4_500, allocatedBytes: 8_000, fileCount: 7, inaccessibleItems: 1)],
            issues: [ScanIssue(path: root + "/locked", kind: .unreadableDirectory, errorCode: 13)],
            issueCount: 1, startedAt: Date(), finishedAt: Date())
    }

    func testScanSessionLifecycleRoundTrip() async throws {
        let store = try Store.inMemory()
        try await store.createScanSession(id: "s1", volumeId: nil, scopeDescription: "Root", rootPath: "/scan/root", startedAt: Date())
        let running = try await store.scanSession(id: "s1")
        XCTAssertEqual(running?.status, .running)

        try await store.updateScanProgress(id: "s1", progress: ScanProgress(filesVisited: 3, logicalBytes: 99))
        let mid = try await store.scanSession(id: "s1")
        XCTAssertEqual(mid?.filesVisited, 3)

        try await store.finishScan(id: "s1", result: sampleResult())
        let doneValue = try await store.scanSession(id: "s1")
        let done = try XCTUnwrap(doneValue)
        XCTAssertEqual(done.status, .partial)
        XCTAssertEqual(done.bytesObserved, 5_000)
        XCTAssertEqual(done.allocatedBytesObserved, 8_192)
        XCTAssertEqual(done.symlinksSkipped, 2)
        XCTAssertEqual(done.excludedItems, 4)
        XCTAssertEqual(done.mountPointsSkipped, 1)
        XCTAssertNotNil(done.completedAt)

        let findings = try await store.findings(scanId: "s1")
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings[0].logicalSizeBytes, 4_000)
        XCTAssertNil(findings[0].allocatedSizeBytes, "unknown size is NULL, not zero")
        XCTAssertEqual(findings[0].riskLevel, .notAssessed)
        XCTAssertEqual(findings[0].eligibility, .reviewOnly)
        XCTAssertEqual(findings[0].modifiedAt?.timeIntervalSince1970 ?? 0, 1_700_000_000, accuracy: 0.001)

        let aggregates = try await store.aggregates(scanId: "s1")
        XCTAssertEqual(aggregates.first?.inaccessibleItems, 1)
        let issues = try await store.issues(scanId: "s1")
        XCTAssertEqual(issues.first?.errorCode, 13)

        // Progress updates no longer apply after the session is terminal.
        try await store.updateScanProgress(id: "s1", progress: ScanProgress(filesVisited: 1))
        let after = try await store.scanSession(id: "s1")
        XCTAssertEqual(after?.filesVisited, 10)
    }

    func testInterruptedScansAreReconciled() async throws {
        let store = try Store.inMemory()
        try await store.createScanSession(id: "crashed", volumeId: nil, scopeDescription: "x", rootPath: "/", startedAt: Date())
        try await store.createScanSession(id: "fine", volumeId: nil, scopeDescription: "y", rootPath: "/", startedAt: Date())
        try await store.finishScan(id: "fine", result: sampleResult(status: .completed))

        let count = try await LaunchReconciler.run(store: store)
        XCTAssertEqual(count, 1)
        let crashed = try await store.scanSession(id: "crashed")
        XCTAssertEqual(crashed?.status, .interrupted)
        XCTAssertNotNil(crashed?.failureReason)
        let fine = try await store.scanSession(id: "fine")
        XCTAssertEqual(fine?.status, .completed)
        let events = try await store.auditEvents()
        XCTAssertEqual(events.first?.eventType, "scan.reconciled")
        XCTAssertEqual(events.first?.operationId, "crashed")
    }

    func testRetentionKeepsNewestAndNeverPrunesRunning() async throws {
        let store = try Store.inMemory()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0..<5 {
            try await store.createScanSession(id: "s\(i)", volumeId: nil, scopeDescription: "\(i)", rootPath: "/",
                                              startedAt: base.addingTimeInterval(Double(i)))
            try await store.finishScan(id: "s\(i)", result: sampleResult())
        }
        try await store.createScanSession(id: "live", volumeId: nil, scopeDescription: "live", rootPath: "/",
                                          startedAt: base.addingTimeInterval(-100))
        let removed = try await store.pruneScans(keepLatest: 2)
        XCTAssertEqual(removed, 3)
        let remaining = try await store.recentScans().map(\.id)
        XCTAssertEqual(Set(remaining), ["s4", "s3", "live"])
        let orphanFindings = try await store.findings(scanId: "s0")
        XCTAssertTrue(orphanFindings.isEmpty)
    }

    func testVolumeSnapshotsAreRateLimited() async throws {
        let store = try Store.inMemory()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func volume(_ at: Date, available: Int64) -> VolumeObservation {
            VolumeObservation(id: "vol-1", displayName: "Macintosh HD", mountPath: "/", totalBytes: 1_000,
                              availableBytes: available, availableForImportantUsageBytes: nil, isRemovable: false,
                              isReadOnly: false, isInternal: true, formatDescription: nil, source: "test", observedAt: at)
        }
        let first = try await store.recordVolumeSnapshotIfDue(volume(t0, available: 400), minimumInterval: 3600)
        let tooSoon = try await store.recordVolumeSnapshotIfDue(volume(t0.addingTimeInterval(60), available: 390), minimumInterval: 3600)
        let later = try await store.recordVolumeSnapshotIfDue(volume(t0.addingTimeInterval(7200), available: 300), minimumInterval: 3600)
        XCTAssertTrue(first); XCTAssertFalse(tooSoon); XCTAssertTrue(later)
        let snaps = try await store.snapshots(volumeId: "vol-1")
        XCTAssertEqual(snaps.map(\.availableBytes), [400, 300], "oldest first, no invented points")
        XCTAssertNil(snaps[0].scannedScopeBytes)
    }

    func testAuditSearchAndSeverityFilter() async throws {
        let store = try Store.inMemory()
        try await store.appendAudit(AuditEvent(operationId: "op-1", eventType: "scan.completed", severity: .info, message: "Scan completed: 10 files"))
        try await store.appendAudit(AuditEvent(operationId: "op-2", eventType: "scan.partial", severity: .warning, message: "Scan incomplete: 3 items"))
        try await store.appendAudit(AuditEvent(operationId: nil, eventType: "data.reset", severity: .notice, message: "100% of history_removed"))

        let warnings = try await store.auditEvents(minimumSeverity: .warning)
        XCTAssertEqual(warnings.map(\.eventType), ["scan.partial"])
        let byText = try await store.auditEvents(search: "incomplete")
        XCTAssertEqual(byText.count, 1)
        let byOp = try await store.auditEvents(search: "op-1")
        XCTAssertEqual(byOp.first?.eventType, "scan.completed")
        // LIKE wildcards in user input are treated literally.
        let literalPercent = try await store.auditEvents(search: "100%")
        XCTAssertEqual(literalPercent.count, 1)
        let literalUnderscore = try await store.auditEvents(search: "y_r")
        XCTAssertEqual(literalUnderscore.count, 1)
        let none = try await store.auditEvents(search: "%")
        XCTAssertEqual(none.count, 1, "only the event whose message contains a literal %")
    }

    func testDeleteScanHistoryKeepsAuditTrail() async throws {
        let store = try Store.inMemory()
        try await store.createScanSession(id: "s", volumeId: nil, scopeDescription: "x", rootPath: "/", startedAt: Date())
        try await store.finishScan(id: "s", result: sampleResult())
        try await store.appendAudit(AuditEvent(operationId: "s", eventType: "scan.partial", severity: .warning, message: "m"))
        try await store.deleteScanHistory()
        let scans = try await store.recentScans()
        XCTAssertTrue(scans.isEmpty)
        let audit = try await store.auditEvents()
        XCTAssertEqual(audit.count, 1)
    }
}
