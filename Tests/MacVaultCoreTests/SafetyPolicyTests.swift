import Foundation
import XCTest
@testable import MacVaultCore

/// The policy is pure path logic, so these tests use the real default system roots and a
/// realistic (non-existent) home path. Nothing here touches the filesystem.
final class SafetyPolicyTests: XCTestCase {
    let home = "/Users/tester-macvault-\(UUID().uuidString.prefix(8))"
    /// Only paths named "*Bundle*.app" are treated as real application bundles here.
    lazy var policy = SafetyPolicy(home: home, ownDataDirectory: home + "/Library/Application Support/MacVault",
                                   isApplicationBundle: { $0.hasSuffix("Bundle.app") })
    lazy var caches = home + "/Library/Caches"

    private func assertDenied(_ path: String, _ type: OperationType = .cleanup, scope: String? = nil,
                              file: StaticString = #filePath, line: UInt = #line) {
        let verdict = policy.evaluate(path, for: type, scopeRoot: scope ?? caches)
        XCTAssertNotEqual(verdict, .allowed, "\(path) must be denied for \(type)", file: file, line: line)
    }

    private func assertAllowed(_ path: String, _ type: OperationType = .cleanup, scope: String?,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(policy.evaluate(path, for: type, scopeRoot: scope), .allowed, path, file: file, line: line)
    }

    func testOrdinaryCacheChildIsAllowed() {
        assertAllowed(caches + "/com.example.app", scope: caches)
    }

    func testStructurallyInvalidPathsAreDenied() {
        for path in ["", "relative/path", "/", caches + "/a/", caches + "/../Documents", caches + "/./x",
                     caches + "//x", caches + "/a\0b"] {
            assertDenied(path)
        }
    }

    func testSystemLocationsAreDeniedForEveryType() {
        for path in ["/System/Library/Caches/x", "/usr/local/lib/x", "/bin/ls", "/private/var/folders/x",
                     "/Library/Caches/com.example", "/etc/hosts", "/opt/homebrew/Cellar/x", "/Applications/Utilities/Terminal.app"] {
            for type in OperationType.allCases {
                XCTAssertNotEqual(policy.evaluate(path, for: type, scopeRoot: (path as NSString).deletingLastPathComponent),
                                  .allowed, "\(path) for \(type)")
            }
        }
    }

    func testHomeItsParentsStandardFoldersAndOtherUsersAreDenied() {
        assertDenied(home, scope: "/Users")
        assertDenied("/Users", scope: "/")
        for folder in ["Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures", "Applications"] {
            assertDenied(home + "/" + folder, .duplicateRemoval, scope: home)
        }
        assertDenied("/Users/someone-else/Library/Caches/x", scope: "/Users/someone-else/Library/Caches")
    }

    func testTopLevelLibraryFoldersThemselvesAreDenied() {
        for name in ["Caches", "Logs", "Application Support", "Preferences", "Containers"] {
            assertDenied(home + "/Library/" + name, .appLeftovers, scope: home + "/Library")
        }
    }

    func testProtectedPersonalDataIsDenied() {
        for relative in ["Library/Keychains/login.keychain-db", "Library/Mail/V10/x", "Library/Messages/chat.db",
                         "Library/Mobile Documents/com~apple~CloudDocs/file", "Library/CloudStorage/Dropbox/x",
                         "Library/Group Containers/group.x/data", "Library/Application Support/MobileSync/Backup/x",
                         "Library/LaunchAgents/com.example.plist", "Library/Preferences/com.apple.finder.plist",
                         ".Trash/old"] {
            let path = home + "/" + relative
            for type in OperationType.allCases {
                XCTAssertNotEqual(policy.evaluate(path, for: type, scopeRoot: (path as NSString).deletingLastPathComponent),
                                  .allowed, "\(relative) for \(type)")
            }
        }
    }

    func testCredentialsVersionControlAndSigningAssetsAreDenied() {
        let projects = home + "/Projects"
        for path in [projects + "/app/.git/objects/ab", projects + "/app/.ssh/id_ed25519",
                     projects + "/.aws/credentials", projects + "/cert.p12", projects + "/release.keystore",
                     projects + "/upload.jks", projects + "/dist.mobileprovision", projects + "/key.pem",
                     home + "/Pictures/Photos Library.photoslibrary", projects + "/Song.logicx"] {
            assertDenied(path, .duplicateRemoval, scope: home)
        }
    }

    func testItemsInsidePackagesAreDenied() {
        assertDenied("/Applications/Foo.app/Contents/Resources/big.bin", .duplicateRemoval, scope: "/Applications")
        assertDenied(home + "/Projects/X.framework/Versions/A/X", .duplicateRemoval, scope: home)
        assertDenied(home + "/Downloads/MyBundle.app/Contents/MacOS/x", .duplicateRemoval, scope: home)
        assertDenied(home + "/Downloads/MyBundle.app", .duplicateRemoval, scope: home)
    }

    func testFoldersNamedAfterBundleIdentifiersAreNotTreatedAsApps() {
        assertAllowed(caches + "/com.example.app", scope: caches)
        assertAllowed(caches + "/com.example.app/fsCachedData", scope: caches)
        assertAllowed(home + "/Library/Containers/com.example.app", .appLeftovers, scope: home + "/Library/Containers")
    }

    func testNothingInsideApplicationsFoldersOutsideAppRemoval() {
        assertDenied("/Applications/Tools/readme.txt", .duplicateRemoval, scope: "/Applications")
        assertDenied(home + "/Applications/old.dmg", .duplicateRemoval, scope: home)
    }

    func testOwnDataIsDenied() {
        assertDenied(home + "/Library/Application Support/MacVault/macvault.sqlite", .appLeftovers,
                     scope: home + "/Library/Application Support")
        assertDenied(home + "/Library/Application Support/MacVault", .appLeftovers,
                     scope: home + "/Library/Application Support")
    }

    func testScopeIsRequiredAndEnforced() {
        XCTAssertNotEqual(policy.evaluate(caches + "/x", for: .cleanup, scopeRoot: nil), .allowed)
        assertDenied(caches, scope: caches)                       // the scope itself
        assertDenied(home + "/Library/Logs/x", scope: caches)     // outside scope
        assertDenied(caches + "x/y", scope: caches)               // prefix collision is not "inside"
    }

    func testCleanupRulesStayInsideHome() {
        XCTAssertNotEqual(policy.evaluate("/Volumes/Data/cache/x", for: .cleanup, scopeRoot: "/Volumes/Data/cache"), .allowed)
    }

    func testVolumeRootsAreDeniedButContentsOfChosenFoldersAllowed() {
        assertDenied("/Volumes/External", .duplicateRemoval, scope: "/Volumes")
        assertAllowed("/Volumes/External/Photos/copy.jpg", .duplicateRemoval, scope: "/Volumes/External")
        assertAllowed("/Volumes/External/dev/app/node_modules", .developerCleanup, scope: "/Volumes/External/dev")
    }

    func testAppLeftoversOnlyInKnownLibraryLocations() {
        assertAllowed(home + "/Library/Application Support/com.example.app", .appLeftovers,
                      scope: home + "/Library/Application Support")
        assertAllowed(home + "/Library/Preferences/com.example.app.plist", .appLeftovers, scope: home + "/Library/Preferences")
        assertDenied(home + "/Documents/com.example.app", .appLeftovers, scope: home + "/Documents")
        assertDenied(home + "/Library/Application Support/x", .appLeftovers, scope: home + "/Library")
    }

    func testDuplicatesNeverInsideLibrary() {
        assertDenied(home + "/Library/Application Support/x/file.bin", .duplicateRemoval, scope: home)
        assertAllowed(home + "/Documents/copy.pdf", .duplicateRemoval, scope: home)
    }

    func testAppBundlesOnlyThroughAppUninstallAndOnlyInApplicationsFolders() {
        assertAllowed("/Applications/Foo.app", .appUninstall, scope: nil)
        assertAllowed("/Applications/Adobe/Bar.app", .appUninstall, scope: nil)
        assertAllowed(home + "/Applications/Baz.app", .appUninstall, scope: nil)
        assertDenied("/Applications/Foo.app", .cleanup, scope: "/Applications")
        assertDenied(home + "/Downloads/FooBundle.app", .duplicateRemoval, scope: home)
        assertDenied(home + "/Downloads/Foo.app", .appUninstall)
        assertDenied("/Applications/a/b/Deep.app", .appUninstall)
        assertDenied("/Applications/Utilities/Terminal.app", .appUninstall)
        assertDenied("/Applications", .appUninstall)
        assertDenied("/Applications/NotAnApp", .appUninstall)
        assertDenied("/System/Applications/Mail.app", .appUninstall)
    }

    func testEveryBuiltInRuleTargetsAnAllowedLocation() {
        for rule in RuleCatalog.all {
            let path: String
            let scope: String
            switch rule.target {
            case .childrenOf(let relative):
                scope = home + "/" + relative
                path = scope + "/example-child"
            case .item(let relative):
                path = home + "/" + relative
                scope = (path as NSString).deletingLastPathComponent
            }
            XCTAssertEqual(policy.evaluate(path, for: rule.operation, scopeRoot: scope), .allowed, rule.id)
        }
    }

    func testRulesNeverPreselectRiskyItems() {
        for rule in RuleCatalog.all where rule.risk != .low {
            XCTAssertFalse(rule.selectedByDefault, rule.id)
        }
        let forced = CleanupRule(id: "x", title: "x", explanation: "x", consequence: "x", category: .caches,
                                 operation: .cleanup, risk: .high, target: .item("x"), selectedByDefault: true)
        XCTAssertFalse(forced.selectedByDefault, "the initializer refuses to pre-select non-low-risk rules")
    }
}
