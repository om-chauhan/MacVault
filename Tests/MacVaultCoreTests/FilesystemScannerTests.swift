import Foundation
import XCTest
@testable import MacVaultCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class FilesystemScannerTests: XCTestCase {

    func testNestedTreeSizesAndCounts() async throws {
        let t = try TempTree()
        try t.file("a/one.bin", bytes: 1_000)
        try t.file("a/b/two.bin", bytes: 2_000)
        try t.file("a/b/c/three.bin", bytes: 3_000)
        try t.file("top.bin", bytes: 500)
        try t.file(".hidden", bytes: 10)
        try t.dir("empty")

        let result = try await FilesystemScanner().scan(ScanConfiguration(rootPath: t.root, largeFileThresholdBytes: 2_000))

        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.counters.filesVisited, 5)
        XCTAssertEqual(result.counters.directoriesVisited, 5) // root, a, a/b, a/b/c, empty
        XCTAssertEqual(result.counters.logicalBytes, 6_510)
        XCTAssertEqual(result.counters.inaccessibleItems, 0)

        XCTAssertEqual(result.largeFiles.map(\.logicalSizeBytes), [3_000, 2_000])
        XCTAssertEqual(result.largeFiles.first?.path, t.path("a/b/c/three.bin"))

        let a = try XCTUnwrap(result.topLevel.first { $0.name == "a" })
        XCTAssertEqual(a.logicalBytes, 6_000)
        XCTAssertEqual(a.fileCount, 3)
        XCTAssertTrue(a.isDirectory)
        XCTAssertEqual(result.topLevel.first?.name, "a", "breakdown is sorted by size")
        let empty = try XCTUnwrap(result.topLevel.first { $0.name == "empty" })
        XCTAssertEqual(empty.logicalBytes, 0)
        XCTAssertEqual(result.topLevel.reduce(0) { $0 + $1.logicalBytes }, result.counters.logicalBytes)
    }

    func testUnusualNames() async throws {
        let t = try TempTree()
        try t.file("spaces in name.txt", bytes: 7)
        try t.file("ünïcødé 名前.txt", bytes: 8)
        try t.file("quote'\"semi;colon.txt", bytes: 9)
        let result = try await FilesystemScanner().scan(ScanConfiguration(rootPath: t.root))
        XCTAssertEqual(result.counters.filesVisited, 3)
        XCTAssertEqual(result.counters.logicalBytes, 24)
        XCTAssertEqual(result.status, .completed)
    }

    func testSymlinksAreNotFollowed() async throws {
        let outside = try TempTree()
        try outside.file("big-outside.bin", bytes: 50_000)
        let t = try TempTree()
        try t.file("inside.bin", bytes: 100)
        try t.symlink("link-to-outside-dir", to: outside.root)
        try t.symlink("link-to-file", to: t.path("inside.bin"))
        try t.symlink("dangling", to: t.path("does-not-exist"))

        let result = try await FilesystemScanner().scan(ScanConfiguration(rootPath: t.root, largeFileThresholdBytes: 1))

        XCTAssertEqual(result.counters.symlinksSkipped, 3)
        XCTAssertEqual(result.counters.filesVisited, 1)
        XCTAssertEqual(result.counters.logicalBytes, 100)
        XCTAssertFalse(result.largeFiles.contains { $0.path.contains("big-outside") })
        XCTAssertEqual(result.status, .completed, "skipping symlinks by policy is not an error")
    }

    func testSymlinkRootIsResolved() async throws {
        let real = try TempTree()
        try real.file("x.bin", bytes: 10)
        let holder = try TempTree()
        try holder.symlink("alias", to: real.root)
        let config = ScanConfiguration(rootPath: holder.path("alias"))
        XCTAssertEqual(config.rootPath, real.root)
        let result = try await FilesystemScanner().scan(config)
        XCTAssertEqual(result.counters.filesVisited, 1)
    }

    func testExclusionsAreSkippedAndCounted() async throws {
        let t = try TempTree()
        try t.file("keep/a.bin", bytes: 100)
        try t.file("skip/b.bin", bytes: 1_000)
        try t.file("skipper/c.bin", bytes: 10) // shares a prefix but is not inside "skip"
        let result = try await FilesystemScanner().scan(
            ScanConfiguration(rootPath: t.root, exclusions: [t.path("skip")]))
        XCTAssertEqual(result.counters.excludedItems, 1)
        XCTAssertEqual(result.counters.logicalBytes, 110)
        XCTAssertFalse(result.topLevel.contains { $0.name == "skip" })
        XCTAssertTrue(result.topLevel.contains { $0.name == "skipper" })
    }

    func testHardLinksCountedOnce() async throws {
        let t = try TempTree()
        let original = try t.file("original.bin", bytes: 4_000)
        try FileManager.default.linkItem(atPath: original, toPath: t.path("hardlink.bin"))
        let result = try await FilesystemScanner().scan(ScanConfiguration(rootPath: t.root))
        XCTAssertEqual(result.counters.filesVisited, 2)
        XCTAssertEqual(result.counters.hardLinkRepeats, 1)
        XCTAssertEqual(result.counters.logicalBytes, 4_000)
    }

    func testLargeFileFindingsAreBounded() async throws {
        let t = try TempTree()
        for i in 0..<30 { try t.file("f\(i).bin", bytes: 100 + i) }
        let result = try await FilesystemScanner().scan(
            ScanConfiguration(rootPath: t.root, largeFileThresholdBytes: 100, maxLargeFileFindings: 5))
        XCTAssertEqual(result.largeFiles.count, 5)
        XCTAssertEqual(result.largeFiles.map(\.logicalSizeBytes), [129, 128, 127, 126, 125])
        XCTAssertEqual(result.counters.filesVisited, 30, "bounding findings never bounds the scan")
    }

    func testMissingRootThrows() async {
        do {
            _ = try await FilesystemScanner().scan(ScanConfiguration(rootPath: "/nonexistent-\(UUID().uuidString)"))
            XCTFail("expected error")
        } catch let error as ScanError {
            guard case .rootUnavailable(_, let code) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(code, ENOENT)
        } catch { XCTFail("\(error)") }
    }

    func testRootThatIsAFileThrows() async throws {
        let t = try TempTree()
        let f = try t.file("plain.txt", bytes: 1)
        do {
            _ = try await FilesystemScanner().scan(ScanConfiguration(rootPath: f))
            XCTFail("expected error")
        } catch let error as ScanError {
            XCTAssertEqual(error, .rootNotDirectory(path: f))
        }
    }

    /// Real permission denial. Root bypasses permission bits, so this is skipped when running as root;
    /// `testInjectedPermissionDenialMarksScanPartial` covers the same logic deterministically.
    func testRealUnreadableDirectoryMarksScanPartial() async throws {
        try XCTSkipIf(geteuid() == 0, "permission bits are not enforced for root")
        let t = try TempTree()
        try t.file("ok/a.bin", bytes: 10)
        try t.file("locked/secret.bin", bytes: 10)
        chmod(t.path("locked"), 0o000)
        let result = try await FilesystemScanner().scan(ScanConfiguration(rootPath: t.root))
        XCTAssertEqual(result.status, .partial)
        XCTAssertEqual(result.counters.inaccessibleItems, 1)
        XCTAssertEqual(result.issues.first?.kind, .unreadableDirectory)
        XCTAssertEqual(result.issues.first?.errorCode, EACCES)
    }

    func testInjectedPermissionDenialMarksScanPartial() async throws {
        let t = try TempTree()
        try t.file("ok/a.bin", bytes: 10)
        try t.file("locked/secret.bin", bytes: 10)
        try t.file("locked/inner/more.bin", bytes: 10)
        let locked = t.path("locked")
        let probe = FileSystemProbe(
            stat: FileSystemProbe.posix.stat,
            list: { path in path == locked ? .failure(POSIXFailure(code: EACCES)) : FileSystemProbe.posix.list(path) })

        let result = try await FilesystemScanner(probe: probe).scan(ScanConfiguration(rootPath: t.root))

        XCTAssertEqual(result.status, .partial, "inaccessible items must never produce .completed")
        XCTAssertEqual(result.counters.inaccessibleItems, 1)
        XCTAssertEqual(result.counters.filesVisited, 1)
        XCTAssertEqual(result.issueCount, 1)
        XCTAssertEqual(result.issues, [ScanIssue(path: locked, kind: .unreadableDirectory, errorCode: EACCES)])
        let lockedEntry = try XCTUnwrap(result.topLevel.first { $0.name == "locked" })
        XCTAssertFalse(lockedEntry.isComplete, "size of an unreadable folder is a lower bound, not zero")
    }

    func testInjectedMetadataFailureIsCounted() async throws {
        let t = try TempTree()
        try t.file("a.bin", bytes: 10)
        let bad = try t.file("vanished.bin", bytes: 10)
        let probe = FileSystemProbe(
            stat: { $0 == bad ? .failure(POSIXFailure(code: ENOENT)) : FileSystemProbe.posix.stat($0) },
            list: FileSystemProbe.posix.list)
        let result = try await FilesystemScanner(probe: probe).scan(ScanConfiguration(rootPath: t.root))
        XCTAssertEqual(result.status, .partial)
        XCTAssertEqual(result.issues.first?.kind, .metadataUnavailable)
        XCTAssertEqual(result.counters.logicalBytes, 10)
    }

    func testUndecodableNamesAreReportedNotGuessed() async throws {
        let t = try TempTree()
        try t.file("a.bin", bytes: 10)
        let root = t.root
        let probe = FileSystemProbe(
            stat: FileSystemProbe.posix.stat,
            list: { path in
                guard case .success(var listing) = FileSystemProbe.posix.list(path) else { return FileSystemProbe.posix.list(path) }
                if path == root { listing.undecodableCount = 2 }
                return .success(listing)
            })
        let result = try await FilesystemScanner(probe: probe).scan(ScanConfiguration(rootPath: t.root))
        XCTAssertEqual(result.status, .partial)
        XCTAssertEqual(result.counters.otherErrors, 2)
    }

    func testMountBoundaryIsNotCrossedByDefault() async throws {
        let t = try TempTree()
        try t.file("local/a.bin", bytes: 10)
        try t.file("othervolume/b.bin", bytes: 1_000)
        let other = t.path("othervolume")
        let probe = FileSystemProbe(
            stat: { path in
                guard case .success(var st) = FileSystemProbe.posix.stat(path) else { return FileSystemProbe.posix.stat(path) }
                if path == other { st.device &+= 1 }
                return .success(st)
            },
            list: FileSystemProbe.posix.list)

        let stayed = try await FilesystemScanner(probe: probe).scan(ScanConfiguration(rootPath: t.root))
        XCTAssertEqual(stayed.counters.mountPointsSkipped, 1)
        XCTAssertEqual(stayed.counters.logicalBytes, 10)
        XCTAssertEqual(stayed.status, .completed, "a skipped mount point is policy, not an error")
        XCTAssertEqual(stayed.issues.first?.kind, .mountPointSkipped)

        var crossing = ScanConfiguration(rootPath: t.root)
        crossing.crossMountPoints = true
        let crossed = try await FilesystemScanner(probe: probe).scan(crossing)
        XCTAssertEqual(crossed.counters.logicalBytes, 1_010)
    }

    func testCancellationReturnsPartialObservations() async throws {
        let t = try TempTree()
        for d in 0..<20 {
            for f in 0..<100 { try t.file("d\(d)/f\(f).bin", bytes: 1) }
        }
        var config = ScanConfiguration(rootPath: t.root)
        config.progressInterval = 0

        let task = Task {
            try await FilesystemScanner().scan(config) { _ in
                // Cancel from inside the scan the first time progress is reported.
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        let result = try await task.value
        XCTAssertEqual(result.status, .cancelled)
        XCTAssertLessThan(result.counters.filesVisited, 2_000)
    }

    func testCancelledBeforeStartVisitsNothing() async throws {
        let t = try TempTree()
        try t.file("a.bin", bytes: 1)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await FilesystemScanner().scan(ScanConfiguration(rootPath: t.root))
        }
        let result = try await task.value
        XCTAssertEqual(result.status, .cancelled)
        XCTAssertEqual(result.counters.filesVisited, 0)
    }

    func testProgressIsReportedAndMonotonic() async throws {
        let t = try TempTree()
        for d in 0..<10 { for f in 0..<60 { try t.file("d\(d)/f\(f).bin", bytes: 2) } }
        var config = ScanConfiguration(rootPath: t.root)
        config.progressInterval = 0
        let log = ProgressLog()
        let result = try await FilesystemScanner().scan(config) { log.append($0) }
        let reports = log.all
        XCTAssertGreaterThan(reports.count, 1)
        XCTAssertEqual(reports.last?.filesVisited, result.counters.filesVisited, "final report matches the result")
        XCTAssertEqual(reports.map(\.filesVisited), reports.map(\.filesVisited).sorted())
    }

    func testScannerHasNoMutatingCapability() async throws {
        // The scan must leave the tree byte-for-byte unchanged.
        let t = try TempTree()
        try t.file("a/b.bin", bytes: 123)
        let before = try FileManager.default.subpathsOfDirectory(atPath: t.root).sorted()
        _ = try await FilesystemScanner().scan(ScanConfiguration(rootPath: t.root))
        let after = try FileManager.default.subpathsOfDirectory(atPath: t.root).sorted()
        XCTAssertEqual(before, after)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: t.path("a/b.bin"))[.size] as? Int, 123)
    }
}
