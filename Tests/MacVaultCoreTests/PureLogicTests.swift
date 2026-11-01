import Foundation
import XCTest
@testable import MacVaultCore

final class TreemapLayoutTests: XCTestCase {
    func testAreasAreProportionalAndInsideBoundsWithoutOverlap() {
        let bounds = LayoutRect(x: 10, y: 20, width: 600, height: 400)
        let weights: [Double] = [500, 300, 120, 60, 10, 6, 3, 1]
        let laid = TreemapLayout.squarify(weights.enumerated().map { (id: $0.offset, weight: $0.element) }, in: bounds)
        XCTAssertEqual(laid.count, weights.count)
        let total = weights.reduce(0, +)
        for (id, rect) in laid {
            XCTAssertEqual(rect.area, bounds.area * weights[id] / total, accuracy: bounds.area * 1e-9)
            XCTAssertGreaterThanOrEqual(rect.x, bounds.x - 1e-9)
            XCTAssertGreaterThanOrEqual(rect.y, bounds.y - 1e-9)
            XCTAssertLessThanOrEqual(rect.x + rect.width, bounds.x + bounds.width + 1e-6)
            XCTAssertLessThanOrEqual(rect.y + rect.height, bounds.y + bounds.height + 1e-6)
        }
        for i in laid.indices {
            for j in laid.indices where j > i {
                let a = laid[i].rect, b = laid[j].rect
                let overlapW = min(a.x + a.width, b.x + b.width) - max(a.x, b.x)
                let overlapH = min(a.y + a.height, b.y + b.height) - max(a.y, b.y)
                XCTAssertFalse(overlapW > 1e-6 && overlapH > 1e-6, "\(laid[i].id) overlaps \(laid[j].id)")
            }
        }
        XCTAssertEqual(laid.reduce(0) { $0 + $1.rect.area }, bounds.area, accuracy: 1e-6)
    }

    func testDegenerateInputs() {
        let bounds = LayoutRect(x: 0, y: 0, width: 100, height: 50)
        XCTAssertTrue(TreemapLayout.squarify([(id: "a", weight: 0), (id: "b", weight: -1)], in: bounds).isEmpty)
        XCTAssertTrue(TreemapLayout.squarify([(id: "a", weight: 1)], in: LayoutRect(x: 0, y: 0, width: 0, height: 10)).isEmpty)
        let one = TreemapLayout.squarify([(id: "a", weight: 7), (id: "z", weight: 0)], in: bounds)
        XCTAssertEqual(one.map(\.id), ["a"])
        XCTAssertEqual(one.first?.rect, bounds)
    }
}

final class ActivityExporterTests: XCTestCase {
    private let home = "/Users/jdoe"
    private func events() -> [AuditEvent] {
        [
            AuditEvent(operationId: "op-1", eventType: "operation.item.trashed", severity: .info,
                       message: "Moved to the Trash: /Users/jdoe/Library/Caches/x, owner jdoe",
                       details: ["path": "/Users/jdoe/Library/Caches/x"], createdAt: Date(timeIntervalSince1970: 0)),
            AuditEvent(operationId: nil, eventType: "scan.partial", severity: .warning,
                       message: "=HYPERLINK(\"http://evil\"), with \"quotes\"\nand newline", createdAt: Date(timeIntervalSince1970: 1)),
        ]
    }

    func testJSONExportIsValidAndRedacted() throws {
        let data = try ActivityExporter.export(events(), format: .json, home: home, userName: "jdoe")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["eventCount"] as? Int, 2)
        XCTAssertEqual(object["redaction"] as? String, "homeFolder")
        let rows = try XCTUnwrap(object["events"] as? [[String: Any]])
        XCTAssertEqual(rows.first?["message"] as? String, "Moved to the Trash: ~/Library/Caches/x, owner <user>")
        XCTAssertEqual((rows.first?["details"] as? [String: String])?["path"], "~/Library/Caches/x")
        XCTAssertEqual(rows.first?["time"] as? String, "1970-01-01T00:00:00.000Z")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("jdoe"))
    }

    func testUnredactedExportKeepsPaths() throws {
        let data = try ActivityExporter.export(events(), format: .json, redaction: .none, home: home, userName: "jdoe")
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("/Users/jdoe/Library/Caches/x"))
    }

    func testCSVEscapingAndFormulaNeutralisation() throws {
        let csv = String(decoding: try ActivityExporter.export(events(), format: .csv, home: home, userName: "jdoe"), as: UTF8.self)
        let lines = csv.components(separatedBy: "\r\n")
        XCTAssertEqual(lines.first, "time,severity,event_type,operation_id,message,details")
        XCTAssertTrue(csv.contains("\"'=HYPERLINK(\"\"http://evil\"\"), with \"\"quotes\"\"\nand newline\""))
        XCTAssertFalse(csv.contains("jdoe"))
        XCTAssertEqual(ActivityExporter.csvField("-1"), "'-1")
        XCTAssertEqual(ActivityExporter.csvField("@x"), "'@x")
        XCTAssertEqual(ActivityExporter.csvField("plain"), "plain")
        XCTAssertEqual(ActivityExporter.csvField("a,b"), "\"a,b\"")
    }

    func testHomeIsOnlyReplacedAtAPathBoundary() {
        XCTAssertEqual(ActivityExporter.redactHome("/Users/al/x and /Users/alice/x and /Users/al", home: "/Users/al", userName: "zz"),
                       "~/x and /Users/alice/x and ~")
    }

    func testUserNameIsOnlyReplacedAsAWholeWord() {
        XCTAssertEqual(ActivityExporter.redactHome("jdoe2 and jdoe.", home: "/Users/jdoe", userName: "jdoe"), "jdoe2 and <user>.")
    }
}

final class WholeVolumeScanConfigurationTests: XCTestCase {
    func testWholeVolumeScanSkipsTheVolumeGroupMounts() {
        let implicit = ScanConfiguration.implicitExclusions(forRoot: "/")
        XCTAssertEqual(implicit, ["/System/Volumes"])
        // Trailing slashes and "." still mean the root.
        XCTAssertEqual(ScanConfiguration.implicitExclusions(forRoot: "//"), implicit)
        XCTAssertEqual(ScanConfiguration.implicitExclusions(forRoot: "/."), implicit)

        let config = ScanConfiguration(rootPath: "/", exclusions: ["/Users/Shared/x"] + implicit)
        XCTAssertTrue(config.isExcluded("/System/Volumes"))
        XCTAssertTrue(config.isExcluded("/System/Volumes/Data/Users"))
        XCTAssertFalse(config.isExcluded("/System/Library"))
        XCTAssertFalse(config.isExcluded("/Users"))
        XCTAssertTrue(config.isExcluded("/Users/Shared/x"), "user exclusions are kept alongside the implicit ones")
    }

    func testFolderScansGetNoImplicitExclusions() {
        XCTAssertEqual(ScanConfiguration.implicitExclusions(forRoot: "/Users"), [])
        XCTAssertEqual(ScanConfiguration.implicitExclusions(forRoot: "/System"), [])
        XCTAssertEqual(ScanConfiguration.implicitExclusions(forRoot: NSHomeDirectory()), [])
    }
}

final class MonitoringTests: XCTestCase {
    func testScheduleDue() {
        let now = Date()
        XCTAssertFalse(ScanSchedule.off.isDue(lastRun: nil, now: now))
        XCTAssertTrue(ScanSchedule.daily.isDue(lastRun: nil, now: now))
        XCTAssertFalse(ScanSchedule.daily.isDue(lastRun: now.addingTimeInterval(-3_600), now: now))
        XCTAssertTrue(ScanSchedule.daily.isDue(lastRun: now.addingTimeInterval(-86_400), now: now))
        XCTAssertFalse(ScanSchedule.weekly.isDue(lastRun: now.addingTimeInterval(-86_400 * 6), now: now))
        XCTAssertTrue(ScanSchedule.weekly.isDue(lastRun: now.addingTimeInterval(86_400), now: now), "future last-run cannot stall")
    }

    private func volume(available: Int64?, total: Int64? = 1_000) -> VolumeObservation {
        VolumeObservation(id: "v", displayName: "Disk", mountPath: "/", totalBytes: total, availableBytes: available,
                          availableForImportantUsageBytes: nil, isRemovable: nil, isReadOnly: nil, isInternal: nil,
                          formatDescription: nil, source: "test", observedAt: Date())
    }

    func testLowStorageWarnsOnceWithHysteresis() {
        let monitor = LowStorageMonitor(thresholdFraction: 0.10, recoveryMargin: 0.02)
        XCTAssertEqual(monitor.evaluate(volume(available: 500), alreadyWarned: false), .none)
        XCTAssertEqual(monitor.evaluate(volume(available: 50), alreadyWarned: false), .warn(availableFraction: 0.05))
        XCTAssertEqual(monitor.evaluate(volume(available: 50), alreadyWarned: true), .none)
        XCTAssertEqual(monitor.evaluate(volume(available: 110), alreadyWarned: true), .none, "inside the margin")
        XCTAssertEqual(monitor.evaluate(volume(available: 130), alreadyWarned: true), .rearm)
        XCTAssertEqual(monitor.evaluate(volume(available: nil), alreadyWarned: false), .none, "unknown is never low")
        XCTAssertEqual(monitor.evaluate(volume(available: 0, total: 0), alreadyWarned: false), .none)
    }
}

final class ScannerTreeTests: XCTestCase {
    func testTreeRollsUpSizesToEveryTrackedAncestor() async throws {
        let t = try TempTree()
        try t.file("a/one.bin", bytes: 1_000)
        try t.file("a/b/two.bin", bytes: 2_000)
        try t.file("a/b/c/d/deep.bin", bytes: 4_000)
        try t.file("top.bin", bytes: 7)
        var config = ScanConfiguration(rootPath: t.root)
        config.maxTreeDepth = 3
        let result = try await FilesystemScanner().scan(config)
        let byPath = Dictionary(uniqueKeysWithValues: result.tree.map { ($0.path, $0) })

        XCTAssertEqual(Set(byPath.keys), [t.path("a"), t.path("a/b"), t.path("a/b/c")], "depth limited; files are not nodes")
        XCTAssertEqual(byPath[t.path("a")]?.logicalBytes, 7_000)
        XCTAssertEqual(byPath[t.path("a")]?.fileCount, 3)
        XCTAssertNil(byPath[t.path("a")]?.parentPath)
        XCTAssertEqual(byPath[t.path("a/b")]?.logicalBytes, 6_000)
        XCTAssertEqual(byPath[t.path("a/b")]?.parentPath, t.path("a"))
        XCTAssertEqual(byPath[t.path("a/b/c")]?.logicalBytes, 4_000, "deeper content rolls into the deepest tracked node")
        XCTAssertEqual(byPath[t.path("a/b/c")]?.depth, 3)
    }

    func testPruningKeepsLargestAndAllTheirAncestors() async throws {
        let t = try TempTree()
        for i in 0..<10 { try t.file("p\(i)/q/r.bin", bytes: 100 * (i + 1)) }
        var config = ScanConfiguration(rootPath: t.root)
        config.maxTreeNodes = 5
        let result = try await FilesystemScanner().scan(config)
        XCTAssertEqual(result.tree.count, 5)
        let kept = Set(result.tree.map(\.path))
        for node in result.tree {
            if let parent = node.parentPath { XCTAssertTrue(kept.contains(parent), "\(node.path) kept without its parent") }
        }
        XCTAssertTrue(kept.contains(t.path("p9")))
        XCTAssertTrue(kept.contains(t.path("p9/q")))
    }

    func testUnreadableFolderMarksAncestorsAsLowerBound() async throws {
        let t = try TempTree()
        try t.file("a/b/ok.bin", bytes: 10)
        try t.dir("a/b/locked")
        let locked = t.path("a/b/locked")
        let scanner = FilesystemScanner(probe: FileSystemProbe(stat: FileSystemProbe.posix.stat, list: {
            $0 == locked ? .failure(POSIXFailure(code: 13)) : FileSystemProbe.posix.list($0)
        }))
        let result = try await scanner.scan(ScanConfiguration(rootPath: t.root))
        let byPath = Dictionary(uniqueKeysWithValues: result.tree.map { ($0.path, $0) })
        XCTAssertEqual(byPath[t.path("a")]?.inaccessibleItems, 1)
        XCTAssertEqual(byPath[t.path("a/b")]?.inaccessibleItems, 1)
        XCTAssertEqual(byPath[t.path("a/b/locked")]?.inaccessibleItems, 1)
        XCTAssertFalse(byPath[t.path("a")]?.isComplete ?? true)
    }

    func testTreeIsPersistedAndQueriedByParentAndRemovedWithTheScan() async throws {
        let t = try TempTree()
        try t.file("a/b/x.bin", bytes: 10)
        try t.file("a/c/y.bin", bytes: 30)
        let store = try Store.inMemory()
        let outcome = try await ScanService(store: store).runScan(configuration: ScanConfiguration(rootPath: t.root),
                                                                  scopeDescription: "Fixture")
        let roots = try await store.treeNodes(scanId: outcome.scanId, parentPath: nil)
        XCTAssertEqual(roots.map(\.name), ["a"])
        let children = try await store.treeNodes(scanId: outcome.scanId, parentPath: t.path("a"))
        XCTAssertEqual(children.map(\.name), ["c", "b"])
        let one = try await store.treeNode(scanId: outcome.scanId, path: t.path("a/c"))
        XCTAssertEqual(one?.logicalBytes, 30)

        try await store.deleteScanHistory()
        let after = try await store.treeNodes(scanId: outcome.scanId, parentPath: nil)
        XCTAssertTrue(after.isEmpty)
    }

    func testUpgradeFromV2KeepsScansAndAddsNewTables() throws {
        let t = try TempTree()
        let path = t.path("v2.sqlite")
        do {
            let db = try SQLiteConnection(path: path)
            XCTAssertEqual(try Migrations.migrate(db, migrations: [Migrations.v1, Migrations.v2]), 2)
            try db.run("INSERT INTO scan_sessions (id, scope_description, status, started_at) VALUES ('s', 'x', 'completed', ?)",
                       [.date(Date())])
            try db.run("""
            INSERT INTO operation_manifests (id, operation_type, status, created_at) VALUES ('m', 'cleanup', 'draft', ?)
            """, [.date(Date())])
        }
        let db = try SQLiteConnection(path: path)
        XCTAssertEqual(try Migrations.migrate(db), 3)
        XCTAssertEqual(try db.query("SELECT COUNT(*) FROM scan_sessions") { $0.int(0) }.first, 1)
        XCTAssertEqual(try db.query("SELECT title FROM operation_manifests WHERE id = 'm'") { $0.string(0) }.first, .some(nil))
        XCTAssertEqual(try db.query("SELECT COUNT(*) FROM scan_tree_nodes") { $0.int(0) }.first, 0)
    }
}
