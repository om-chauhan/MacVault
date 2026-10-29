import Foundation
import XCTest
@testable import MacVaultCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class ScanServiceIntegrationTests: XCTestCase {
    func testCompletedScanIsPersistedAndAudited() async throws {
        let t = try TempTree()
        try t.file("Videos/clip.mov", bytes: 300_000)
        try t.file("Docs/note.txt", bytes: 100)
        let store = try Store.inMemory()
        let service = ScanService(store: store)
        let log = ProgressLog()

        var config = ScanConfiguration(rootPath: t.root, largeFileThresholdBytes: 200_000)
        config.progressInterval = 0
        let outcome = try await service.runScan(configuration: config, scopeDescription: "Fixture") { log.append($0) }

        XCTAssertNil(outcome.failureMessage)
        XCTAssertEqual(outcome.warnings, [])
        XCTAssertEqual(outcome.result?.status, .completed)
        XCTAssertFalse(log.all.isEmpty)

        let sessionValue = try await store.scanSession(id: outcome.scanId)
        let session = try XCTUnwrap(sessionValue)
        XCTAssertEqual(session.status, .completed)
        XCTAssertEqual(session.bytesObserved, 300_100)
        XCTAssertEqual(session.rootPath, t.root)
        XCTAssertNotNil(session.volumeId, "the volume containing the root was observed")

        let findings = try await store.findings(scanId: outcome.scanId)
        XCTAssertEqual(findings.map(\.name), ["clip.mov"])

        let events = try await store.auditEvents().filter { $0.operationId == outcome.scanId }
        XCTAssertEqual(Set(events.map(\.eventType)), ["scan.started", "scan.completed"])

        let volumeId = try XCTUnwrap(session.volumeId)
        let snaps = try await store.snapshots(volumeId: volumeId)
        XCTAssertEqual(snaps.count, 1)
        XCTAssertEqual(snaps.first?.scannedScopeBytes, 300_100)
        XCTAssertNotNil(snaps.first?.totalBytes)
    }

    func testPartialScanIsRecordedAsPartialWithWarningAudit() async throws {
        let t = try TempTree()
        try t.file("ok/a.bin", bytes: 10)
        try t.dir("locked")
        let locked = t.path("locked")
        let scanner = FilesystemScanner(probe: FileSystemProbe(
            stat: FileSystemProbe.posix.stat,
            list: { $0 == locked ? .failure(POSIXFailure(code: EPERM)) : FileSystemProbe.posix.list($0) }))
        let store = try Store.inMemory()
        let outcome = try await ScanService(store: store, scanner: scanner)
            .runScan(configuration: ScanConfiguration(rootPath: t.root), scopeDescription: "Fixture")

        let session = try await store.scanSession(id: outcome.scanId)
        XCTAssertEqual(session?.status, .partial)
        XCTAssertEqual(session?.inaccessibleItems, 1)
        let partial = try await store.auditEvents(minimumSeverity: .warning)
        XCTAssertEqual(partial.first?.eventType, "scan.partial")
        let issues = try await store.issues(scanId: outcome.scanId)
        XCTAssertEqual(issues.first?.errorCode, EPERM)
    }

    func testFailedScanIsRecordedNotSilentlyDropped() async throws {
        let store = try Store.inMemory()
        let outcome = try await ScanService(store: store)
            .runScan(configuration: ScanConfiguration(rootPath: "/definitely/missing/\(UUID().uuidString)"), scopeDescription: "Missing")
        XCTAssertNil(outcome.result)
        XCTAssertNotNil(outcome.failureMessage)
        let session = try await store.scanSession(id: outcome.scanId)
        XCTAssertEqual(session?.status, .failed)
        XCTAssertNotNil(session?.failureReason)
        let events = try await store.auditEvents()
        XCTAssertEqual(events.first?.eventType, "scan.failed")
        XCTAssertEqual(events.first?.severity, .error)
    }

    func testCancelledScanIsNotMarkedComplete() async throws {
        let t = try TempTree()
        for d in 0..<10 { for f in 0..<100 { try t.file("d\(d)/f\(f)", bytes: 1) } }
        let store = try Store.inMemory()
        var config = ScanConfiguration(rootPath: t.root)
        config.progressInterval = 0
        let task = Task {
            try await ScanService(store: store).runScan(configuration: config, scopeDescription: "Fixture") { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        let outcome = try await task.value
        let session = try await store.scanSession(id: outcome.scanId)
        XCTAssertEqual(session?.status, .cancelled)
        let volumeId = try XCTUnwrap(session?.volumeId)
        let snaps = try await store.snapshots(volumeId: volumeId)
        XCTAssertNil(snaps.first?.scannedScopeBytes, "a cancelled scan does not report scope bytes as measured")
    }
}

final class VolumeInfoTests: XCTestCase {
    func testObservesRealVolumeWithSourceAndTimestamp() throws {
        let before = Date()
        let v = try VolumeInfoService().observeVolume(containing: NSTemporaryDirectory())
        XCTAssertGreaterThan(v.totalBytes ?? 0, 0)
        XCTAssertNotNil(v.availableBytes)
        XCTAssertLessThanOrEqual(v.availableBytes ?? .max, v.totalBytes ?? 0)
        XCTAssertFalse(v.source.isEmpty)
        XCTAssertGreaterThanOrEqual(v.observedAt, before)
        XCTAssertEqual(v.usedBytes, (v.totalBytes ?? 0) - (v.availableBytes ?? 0))
    }

    func testMountedVolumesIsNotEmpty() {
        XCTAssertFalse(VolumeInfoService().mountedVolumes().isEmpty)
    }

    func testUnknownValuesStayUnknown() {
        let v = VolumeObservation(id: "x", displayName: "x", mountPath: nil, totalBytes: nil, availableBytes: 5,
                                  availableForImportantUsageBytes: nil, isRemovable: nil, isReadOnly: nil, isInternal: nil,
                                  formatDescription: nil, source: "test", observedAt: Date())
        XCTAssertNil(v.usedBytes)
        XCTAssertNil(v.usedFraction)
    }
}

final class SupportTests: XCTestCase {
    func testByteFormatting() {
        XCTAssertEqual(ByteFormat.string(0), "0 bytes")
        XCTAssertEqual(ByteFormat.string(1), "1 byte")
        XCTAssertEqual(ByteFormat.string(999), "999 bytes")
        XCTAssertEqual(ByteFormat.string(1_000), "1.00 KB")
        XCTAssertEqual(ByteFormat.string(1_500_000), "1.50 MB")
        XCTAssertEqual(ByteFormat.string(245_100_000_000), "245 GB")
        XCTAssertEqual(ByteFormat.string(nil as Int64?), "Unknown")
    }

    func testTimestampsRoundTripInUTC() {
        let d = Date(timeIntervalSince1970: 1_800_000_000.123)
        let s = Timestamp.string(d)
        XCTAssertTrue(s.hasSuffix("Z"))
        XCTAssertEqual(Timestamp.date(s)?.timeIntervalSince1970 ?? 0, d.timeIntervalSince1970, accuracy: 0.001)
    }

    func testPathContainmentIsComponentAware() {
        XCTAssertTrue(PathUtilities.path("/a/b", isWithin: "/a/b"))
        XCTAssertTrue(PathUtilities.path("/a/b/c", isWithin: "/a/b"))
        XCTAssertFalse(PathUtilities.path("/a/bc", isWithin: "/a/b"))
        XCTAssertTrue(PathUtilities.path("/x", isWithin: "/"))
    }

    func testHomeAbbreviation() {
        XCTAssertEqual(PathUtilities.abbreviatingHome("/Users/om/Movies/a.mov", home: "/Users/om"), "~/Movies/a.mov")
        XCTAssertEqual(PathUtilities.abbreviatingHome("/Users/omar/x", home: "/Users/om"), "/Users/omar/x")
    }

    func testAuditDetailsAreValidJSON() throws {
        let e = AuditEvent(operationId: nil, eventType: "t", severity: .info, message: "m", details: ["a": "1", "b": "two"])
        let data = try XCTUnwrap(e.detailsJSON?.data(using: .utf8))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: String]
        XCTAssertEqual(obj, ["a": "1", "b": "two"])
    }
}
