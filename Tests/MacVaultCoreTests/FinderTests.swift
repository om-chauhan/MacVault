import Foundation
import XCTest
@testable import MacVaultCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class CleanupCandidateFinderTests: XCTestCase {
    func testCacheRuleOffersMeasuredChildrenAndRespectsExclusions() async throws {
        let t = try TempTree()
        let policy = try t.policy()
        try t.file("home/Library/Caches/com.example.big/a.bin", bytes: 5_000)
        try t.file("home/Library/Caches/com.example.big/sub/b.bin", bytes: 1_000)
        try t.file("home/Library/Caches/com.example.app/c.bin", bytes: 300)
        try t.file("home/Library/Caches/com.apple.Safari/x.bin", bytes: 100)   // excluded prefix
        try t.file("home/Library/Caches/.ssh/key", bytes: 100)                  // policy-protected
        try t.dir("home/Library/Caches/empty")                                  // nothing to free
        try t.symlink("home/Library/Caches/link", to: t.home + "/Documents")    // never offered

        let findings = try CleanupCandidateFinder(home: t.home, policy: policy).evaluate(RuleCatalog.userCaches)
        XCTAssertFalse(findings.locationMissing)
        XCTAssertEqual(findings.candidates.map(\.name), ["com.example.big", "com.example.app"])
        XCTAssertEqual(findings.candidates.first?.logicalBytes, 6_000)
        XCTAssertEqual(findings.totalBytes, 6_300)
        XCTAssertEqual(findings.protectedCount, 2)
        let first = try XCTUnwrap(findings.candidates.first)
        XCTAssertEqual(first.scopeRoot, t.home + "/Library/Caches")
        XCTAssertEqual(first.ruleId, "user-caches")
        XCTAssertTrue(first.selectedByDefault)
        XCTAssertEqual(first.resourceIdentifier, stat(of: first.path)?.resourceIdentifier)
    }

    func testMinimumAgeUsesNewestContent() async throws {
        let t = try TempTree()
        let policy = try t.policy()
        try t.file("home/Library/Logs/OldApp/old.log", bytes: 100)
        try t.setModified("home/Library/Logs/OldApp/old.log", daysAgo: 30)
        try t.setModified("home/Library/Logs/OldApp", daysAgo: 30)
        try t.file("home/Library/Logs/ActiveApp/old.log", bytes: 100)
        try t.setModified("home/Library/Logs/ActiveApp/old.log", daysAgo: 30)
        try t.file("home/Library/Logs/ActiveApp/today.log", bytes: 100)   // written today

        let findings = try CleanupCandidateFinder(home: t.home, policy: policy).evaluate(RuleCatalog.userLogs)
        XCTAssertEqual(findings.candidates.map(\.name), ["OldApp"])
        XCTAssertEqual(findings.tooRecentCount, 1)
    }

    func testMissingLocationIsNotAnError() async throws {
        let t = try TempTree()
        let findings = try CleanupCandidateFinder(home: t.home, policy: try t.policy()).evaluate(RuleCatalog.derivedData)
        XCTAssertTrue(findings.locationMissing)
        XCTAssertNil(findings.locationError)
        XCTAssertTrue(findings.candidates.isEmpty)
    }

    func testSingleItemRuleAndPartiallyReadableItemIsNotPreselected() async throws {
        let t = try TempTree()
        let policy = try t.policy()
        let npm = t.home + "/.npm/_cacache"
        try t.file("home/.npm/_cacache/index/a", bytes: 50)
        try t.dir("home/.npm/_cacache/locked")
        let probe = FileSystemProbe(stat: FileSystemProbe.posix.stat, list: {
            $0 == npm + "/locked" ? .failure(POSIXFailure(code: EACCES)) : FileSystemProbe.posix.list($0)
        })
        let findings = try CleanupCandidateFinder(home: t.home, policy: policy, probe: probe).evaluate(RuleCatalog.npmCache)
        let candidate = try XCTUnwrap(findings.candidates.first)
        XCTAssertEqual(candidate.path, npm)
        XCTAssertEqual(candidate.scopeRoot, t.home + "/.npm")
        XCTAssertTrue(candidate.sizeIsLowerBound)
        XCTAssertFalse(candidate.selectedByDefault, "an item that could not be fully read is never pre-selected")
    }

    func testHighRiskRuleCandidatesAreNotPreselected() async throws {
        let t = try TempTree()
        try t.file("home/Library/Developer/Xcode/Archives/2026-01-01/App.xcarchive/Info.plist", bytes: 10)
        let findings = try CleanupCandidateFinder(home: t.home, policy: try t.policy()).evaluate(RuleCatalog.xcodeArchives)
        XCTAssertEqual(findings.candidates.count, 1)
        XCTAssertEqual(findings.candidates.first?.riskLevel, .high)
        XCTAssertFalse(findings.candidates.first?.selectedByDefault ?? true)
    }

    func testFinderNeverModifiesAnything() async throws {
        let t = try TempTree()
        let policy = try t.policy()
        try t.file("home/Library/Caches/a/x.bin", bytes: 10)
        let before = try FileManager.default.subpathsOfDirectory(atPath: t.root).sorted()
        _ = try await CleanupCandidateFinder(home: t.home, policy: policy).evaluate(RuleCatalog.all)
        XCTAssertEqual(try FileManager.default.subpathsOfDirectory(atPath: t.root).sorted(), before)
    }
}

final class ProjectArtifactFinderTests: XCTestCase {
    func testDetectsArtifactsOnlyNextToTheirMarkers() async throws {
        let t = try TempTree()
        let policy = try t.policy()
        try t.file("home/dev/web/package.json", bytes: 2)
        try t.file("home/dev/web/node_modules/left-pad/index.js", bytes: 400)
        try t.file("home/dev/web/node_modules/inner/node_modules/x/y.js", bytes: 100)
        try t.file("home/dev/app/pubspec.yaml", bytes: 2)
        try t.file("home/dev/app/build/out.bin", bytes: 300)
        try t.file("home/dev/app/.dart_tool/cache", bytes: 200)
        try t.file("home/dev/app/android/build.gradle", bytes: 2)
        try t.file("home/dev/app/android/build/x.bin", bytes: 250)
        try t.file("home/dev/rusty/Cargo.toml", bytes: 2)
        try t.file("home/dev/rusty/target/debug/bin", bytes: 500)
        try t.file("home/dev/notes/build/keep-me.txt", bytes: 99)          // no marker → never offered
        try t.file("home/dev/vcs/package.json", bytes: 2)
        try t.file("home/dev/vcs/node_modules/.git/HEAD", bytes: 10)        // contains VCS data → never offered
        try t.file("home/dev/linked/package.json", bytes: 2)
        try t.symlink("home/dev/linked/node_modules", to: t.home + "/Documents")  // symlink → never offered

        let found = try await ProjectArtifactFinder(policy: policy).find(in: t.home + "/dev")
        let byPath = Dictionary(uniqueKeysWithValues: found.map { ($0.path, $0) })
        XCTAssertEqual(Set(byPath.keys), [
            t.home + "/dev/web/node_modules", t.home + "/dev/app/build", t.home + "/dev/app/.dart_tool",
            t.home + "/dev/app/android/build", t.home + "/dev/rusty/target",
        ])
        XCTAssertEqual(byPath[t.home + "/dev/web/node_modules"]?.logicalBytes, 500, "nested node_modules measured once")
        XCTAssertEqual(byPath[t.home + "/dev/app/build"]?.ruleId, "project-flutter-build")
        XCTAssertEqual(byPath[t.home + "/dev/app/android/build"]?.ruleId, "project-gradle-build")
        XCTAssertTrue(found.allSatisfy { $0.scopeRoot == t.home + "/dev" && $0.riskLevel == .low })
        XCTAssertEqual(found.first?.path, t.home + "/dev/rusty/target", "sorted by size")
    }

    func testRespectsMaxDepthAndSkipsLibrary() async throws {
        let t = try TempTree()
        let policy = try t.policy()
        try t.file("home/a/b/c/package.json", bytes: 2)
        try t.file("home/a/b/c/node_modules/x.js", bytes: 10)
        try t.file("home/Library/proj/package.json", bytes: 2)
        try t.file("home/Library/proj/node_modules/x.js", bytes: 10)
        let shallow = try await ProjectArtifactFinder(policy: policy, maxDepth: 2).find(in: t.home)
        XCTAssertTrue(shallow.isEmpty)
        let deep = try await ProjectArtifactFinder(policy: policy, maxDepth: 5).find(in: t.home)
        XCTAssertEqual(deep.map(\.path), [t.home + "/a/b/c/node_modules"])
    }
}

final class ApplicationInventoryTests: XCTestCase {
    private func makeApp(_ t: TempTree, _ relative: String, bundleId: String?, name: String? = nil, version: String = "1.0",
                         bytes: Int = 1_000) throws {
        var info: [String: Any] = ["CFBundleShortVersionString": version]
        if let bundleId { info["CFBundleIdentifier"] = bundleId }
        if let name { info["CFBundleName"] = name }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try t.file(relative + "/Contents/MacOS/binary", bytes: bytes)
        try data.write(to: URL(fileURLWithPath: t.path(relative + "/Contents/Info.plist")))
    }

    func testInventoryReadsBundlesAndProtectsAppleAndSelf() async throws {
        let t = try TempTree()
        let policy = try t.policy()
        try makeApp(t, "Applications/Editor.app", bundleId: "com.example.editor", name: "Editor", bytes: 5_000)
        try makeApp(t, "Applications/Safari.app", bundleId: "com.apple.Safari", bytes: 2_000)
        try makeApp(t, "Applications/MacVault.app", bundleId: "com.macvault.app", bytes: 100)
        try makeApp(t, "Applications/Suite/Tool.app", bundleId: "com.example.tool", bytes: 700)
        try makeApp(t, "Applications/NoPlist.app", bundleId: nil, bytes: 10)
        try t.symlink("Applications/Alias.app", to: t.path("Applications/Editor.app"))

        let inventory = ApplicationInventory(policy: policy, ownBundleId: "com.macvault.app")
        let apps = try await inventory.scan()
        XCTAssertEqual(apps.map(\.displayName), ["Editor", "Safari", "Tool", "MacVault", "NoPlist"])

        let editor = try XCTUnwrap(apps.first { $0.displayName == "Editor" })
        XCTAssertEqual(editor.bundleId, "com.example.editor")
        XCTAssertEqual(editor.version, "1.0")
        XCTAssertGreaterThanOrEqual(editor.bundleSizeBytes ?? 0, 5_000)
        XCTAssertFalse(editor.isProtected)
        XCTAssertNotNil(inventory.uninstallCandidate(for: editor))

        for name in ["Safari", "MacVault"] {
            let app = try XCTUnwrap(apps.first { $0.displayName == name })
            XCTAssertTrue(app.isProtected, name)
            XCTAssertNil(inventory.uninstallCandidate(for: app), name)
            XCTAssertTrue(inventory.associatedItems(for: app).isEmpty, name)
        }
        XCTAssertFalse(apps.first { $0.displayName == "Tool" }?.isProtected ?? true, "apps one folder down are listed")
    }

    func testAssociatedItemsAreSeparateAndConfidenceRated() async throws {
        let t = try TempTree()
        let policy = try t.policy()
        try makeApp(t, "Applications/Editor.app", bundleId: "com.example.editor", name: "Editor")
        try t.file("home/Library/Caches/com.example.editor/c.bin", bytes: 100)
        try t.file("home/Library/Preferences/com.example.editor.plist", bytes: 10)
        try t.file("home/Library/Application Support/com.example.editor/db.sqlite", bytes: 300)
        try t.file("home/Library/Application Support/Editor/name-match.bin", bytes: 50)
        try t.file("home/Library/Containers/com.example.editor/Data/x", bytes: 20)
        try t.file("home/Library/Application Support/com.example.other/x", bytes: 999)  // unrelated

        let inventory = ApplicationInventory(policy: policy)
        let scanned = try await inventory.scan()
        let app = try XCTUnwrap(scanned.first)
        let items = inventory.associatedItems(for: app)
        let byPath = Dictionary(uniqueKeysWithValues: items.map { ($0.candidate.path, $0) })
        let lib = t.home + "/Library"
        XCTAssertEqual(Set(byPath.keys), [
            lib + "/Caches/com.example.editor", lib + "/Preferences/com.example.editor.plist",
            lib + "/Application Support/com.example.editor", lib + "/Application Support/Editor",
            lib + "/Containers/com.example.editor",
        ])
        XCTAssertEqual(byPath[lib + "/Application Support/Editor"]?.confidence, .medium)
        XCTAssertFalse(byPath[lib + "/Application Support/Editor"]?.candidate.selectedByDefault ?? true)
        XCTAssertEqual(byPath[lib + "/Caches/com.example.editor"]?.confidence, .high)
        XCTAssertTrue(byPath[lib + "/Caches/com.example.editor"]?.candidate.selectedByDefault ?? false)
        XCTAssertFalse(byPath[lib + "/Application Support/com.example.editor"]?.candidate.selectedByDefault ?? true,
                       "data that may hold documents is never pre-selected")
        XCTAssertTrue(items.allSatisfy { policy.evaluate($0.candidate.path, for: .appLeftovers, scopeRoot: $0.candidate.scopeRoot).isAllowed })
        XCTAssertNil(inventory.uninstallCandidate(for: app)?.scopeRoot)
        XCTAssertFalse(items.contains { $0.candidate.path == app.bundlePath }, "the bundle is never part of leftovers")
    }

    func testGenericAndShortNamesAreNotMatched() async throws {
        let t = try TempTree()
        let policy = try t.policy()
        try makeApp(t, "Applications/Google.app", bundleId: "com.example.g", name: "Google")
        try t.file("home/Library/Application Support/Google/Chrome/data", bytes: 100)
        let inventory = ApplicationInventory(policy: policy)
        let scanned = try await inventory.scan()
        let app = try XCTUnwrap(scanned.first)
        XCTAssertTrue(inventory.associatedItems(for: app).isEmpty)
    }

    func testRemovingTheAppThroughTheExecutorKeepsItsData() async throws {
        let t = try TempTree()
        let policy = try t.policy()
        try makeApp(t, "Applications/Editor.app", bundleId: "com.example.editor", name: "Editor")
        try t.file("home/Library/Caches/com.example.editor/c.bin", bytes: 100)
        let inventory = ApplicationInventory(policy: policy)
        let scanned = try await inventory.scan()
        let app = try XCTUnwrap(scanned.first)
        let candidate = try XCTUnwrap(inventory.uninstallCandidate(for: app))

        let store = try Store.inMemory()
        let trash = try FakeTrash(in: t)
        let id = try await store.approvedManifest(.appUninstall) { [candidate.operationItem(manifestId: $0)] }
        let running = try await OperationExecutor(store: store, policy: policy, trasher: trash.trasher,
                                                  inUseCheck: { _ in "Editor is running. Quit it first." }).execute(manifestId: id)
        XCTAssertEqual(running.items.first?.status, .skipped, "running apps are never moved")

        let id2 = try await store.approvedManifest(.appUninstall) { [candidate.operationItem(manifestId: $0)] }
        let done = try await OperationExecutor(store: store, policy: policy, trasher: trash.trasher).execute(manifestId: id2)
        XCTAssertEqual(done.status, .completed)
        XCTAssertFalse(exists(app.bundlePath))
        XCTAssertTrue(exists(t.home + "/Library/Caches/com.example.editor/c.bin"), "leftovers need a separate approval")
    }

    func testInventoryPersistence() async throws {
        let store = try Store.inMemory()
        let a = ApplicationRecord(bundlePath: "/Applications/A.app", bundleId: "a", displayName: "A", version: "1",
                                  bundleSizeBytes: 10, sizeIsLowerBound: false, isProtected: false, protectionReason: nil,
                                  resourceIdentifier: nil, observedAt: Date())
        let b = ApplicationRecord(bundlePath: "/Applications/B.app", bundleId: "com.apple.b", displayName: "B", version: nil,
                                  bundleSizeBytes: 20, sizeIsLowerBound: false, isProtected: true, protectionReason: "Apple",
                                  resourceIdentifier: nil, observedAt: Date())
        try await store.replaceApplications([a, b])
        var saved = try await store.applications()
        XCTAssertEqual(saved.map(\.displayName), ["B", "A"])
        XCTAssertTrue(saved[0].isProtected)
        try await store.replaceApplications([a])
        saved = try await store.applications()
        XCTAssertEqual(saved.map(\.displayName), ["A"], "uninstalled apps leave the inventory")
    }
}

final class DuplicateFinderTests: XCTestCase {
    func testFindsVerifiedDuplicatesAndIgnoresLookalikes() async throws {
        let t = try TempTree()
        let policy = try t.policy()
        let big = String(repeating: "x", count: 100_000)
        try t.write("home/Photos/a.jpg", big)
        try t.write("home/Backup/a copy.jpg", big)
        try t.write("home/Backup/old/a.jpg", big)
        // Same size, same 64 KiB prefix, different tail → not a duplicate.
        try t.write("home/Photos/b.jpg", String(repeating: "x", count: 99_999) + "y")
        // Same size, different content.
        try t.write("home/Docs/c.txt", String(repeating: "z", count: 100_000))
        // A hard-linked file: removing one name would free nothing, so neither name is offered.
        try t.write("home/Photos/linked.jpg", big)
        XCTAssertEqual(link(t.home + "/Photos/linked.jpg", t.home + "/Photos/linked-2.jpg"), 0)
        // Small duplicates under the minimum size.
        try t.write("home/Docs/s1.txt", "tiny"); try t.write("home/Docs/s2.txt", "tiny")
        // Symlinks and package contents are ignored.
        try t.symlink("home/Docs/alias.jpg", to: t.home + "/Photos/a.jpg")
        try t.write("home/Docs/Thing.photoslibrary/a.jpg", big)
        try t.write("home/dev/node_modules/a.jpg", big)

        let result = try await DuplicateFinder(policy: policy).find(in: t.home, minimumSize: 1_000)
        XCTAssertEqual(result.groups.count, 1)
        let group = try XCTUnwrap(result.groups.first)
        XCTAssertEqual(Set(group.files.map(\.path)), [t.home + "/Photos/a.jpg", t.home + "/Backup/a copy.jpg",
                                                       t.home + "/Backup/old/a.jpg"])
        XCTAssertEqual(group.sizeBytes, 100_000)
        XCTAssertEqual(group.reclaimableBytes, 200_000)
        XCTAssertEqual(result.hardLinksIgnored, 2)
        XCTAssertEqual(group.contentHash, try ContentHasher().sha256(path: t.home + "/Photos/a.jpg"))
        XCTAssertTrue(result.isComplete)
    }

    func testSuggestedKeeperIsOldestThenShortestPath() {
        let now = Date()
        let files = [
            DuplicateFile(path: "/x/zz/new.bin", resourceIdentifier: "1:1", modifiedAt: now),
            DuplicateFile(path: "/x/longer/old.bin", resourceIdentifier: "1:2", modifiedAt: now.addingTimeInterval(-100)),
            DuplicateFile(path: "/x/old.bin", resourceIdentifier: "1:3", modifiedAt: now.addingTimeInterval(-100)),
        ]
        XCTAssertEqual(DuplicateGroup(contentHash: "h", sizeBytes: 1, files: files).suggestedKeeper.path, "/x/old.bin")
    }

    func testCancellationStopsTheSearch() async throws {
        let t = try TempTree()
        let policy = try t.policy()
        for i in 0..<20 { try t.write("home/f\(i).bin", String(repeating: "q", count: 5_000)) }
        let task = Task { try await DuplicateFinder(policy: policy).find(in: t.home, minimumSize: 1) }
        task.cancel()
        do { _ = try await task.value; XCTFail("expected cancellation") } catch is CancellationError {}
    }
}

final class ContentHasherTests: XCTestCase {
    func testKnownVectors() throws {
        let t = try TempTree()
        let vectors: [(String, String)] = [
            ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
            ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
            ("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
             "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"),
        ]
        for (index, (input, expected)) in vectors.enumerated() {
            try t.write("v\(index)", input)
            XCTAssertEqual(try ContentHasher(chunkSize: 4096).sha256(path: t.path("v\(index)")), expected)
            var portable = PortableSHA256()
            portable.update(Array(input.utf8))
            XCTAssertEqual(portable.finalize().map { String(format: "%02x", $0) }.joined(), expected)
        }
    }

    func testMillionAsAcrossChunkBoundaries() throws {
        let t = try TempTree()
        try t.write("m", String(repeating: "a", count: 1_000_000))
        let expected = "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
        XCTAssertEqual(try ContentHasher(chunkSize: 4096).sha256(path: t.path("m")), expected)
        var portable = PortableSHA256()
        for _ in 0..<1000 { portable.update(Array(repeating: UInt8(ascii: "a"), count: 1000)) }
        XCTAssertEqual(portable.finalize().map { String(format: "%02x", $0) }.joined(), expected)
    }

    func testPrefixHashAndSymlinksAreRefused() throws {
        let t = try TempTree()
        try t.write("full", "abcdef")
        try t.write("prefix", "abc")
        XCTAssertEqual(try ContentHasher().prefixSHA256(path: t.path("full"), bytes: 3),
                       try ContentHasher().sha256(path: t.path("prefix")))
        try t.symlink("link", to: t.path("full"))
        XCTAssertThrowsError(try ContentHasher().sha256(path: t.path("link")), "O_NOFOLLOW")
    }
}
