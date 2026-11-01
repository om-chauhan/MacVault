import Foundation
import AppKit
import SwiftUI
import MacVaultCore

/// Where MacVault keeps its data and which locations it may touch.
///
/// UI test mode (DEBUG builds only, launched with `-MacVaultUITesting`) redirects every location
/// to a fixture folder chosen by the test: database, settings, home folder, Applications folder and
/// the Trash. It refuses to start unless all of them are set, so a partly configured test can never
/// reach the real database or Trash. Release builds ignore the flag and the environment variables
/// entirely, so these hooks cannot weaken the safety policy of a shipped app.
enum AppEnvironment {
    #if DEBUG
    static let isUITesting: Bool = {
        guard ProcessInfo.processInfo.arguments.contains("-MacVaultUITesting") else { return false }
        let env = ProcessInfo.processInfo.environment
        let missing = testKeys.filter { env[$0]?.isEmpty ?? true }
        if !missing.isEmpty {
            preconditionFailure("UI test mode needs \(missing.joined(separator: ", ")); refusing to start with the real locations")
        }
        // Every system root applies in tests too, so the fixture must not sit inside one.
        let home = PathUtilities.canonicalize(env["MACVAULT_HOME"]!)
        if let root = SafetyPolicy.defaultSystemRoots.first(where: { PathUtilities.path(home, isWithin: $0) }) {
            preconditionFailure("UI test mode: fixture home \(home) is inside the system root \(root); refusing to start")
        }
        // The fixture home stands in for the real one, so it must not be it or contain it.
        let realHome = PathUtilities.canonicalize(NSHomeDirectory())
        if PathUtilities.path(realHome, isWithin: home) {
            preconditionFailure("UI test mode: fixture home \(home) is or contains the real home \(realHome); refusing to start")
        }
        // Everything else the app may write to or move from must be inside the fixture: the folder
        // that contains the fixture home, which must not contain the real home either.
        let fixture = (home as NSString).deletingLastPathComponent
        if PathUtilities.path(realHome, isWithin: fixture) {
            preconditionFailure("UI test mode: fixture \(fixture) is or contains the real home \(realHome); refusing to start")
        }
        let paths = ["MACVAULT_DB_PATH", "MACVAULT_TRASH_DIR", "MACVAULT_APPLICATIONS"].map { ($0, env[$0]!) }
            + env["MACVAULT_LOCATIONS"]!.split(separator: ":").map { ("MACVAULT_LOCATIONS", String($0)) }
        for (key, path) in paths where !PathUtilities.path(PathUtilities.canonicalize(path), isWithin: fixture) {
            preconditionFailure("UI test mode: \(key) entry \(path) is outside the fixture \(fixture); refusing to start")
        }
        return true
    }()
    private static let testKeys = ["MACVAULT_DB_PATH", "MACVAULT_HOME", "MACVAULT_LOCATIONS",
                                   "MACVAULT_APPLICATIONS", "MACVAULT_TRASH_DIR"]
    private static var env: [String: String] { ProcessInfo.processInfo.environment }
    #else
    static let isUITesting = false
    private static var env: [String: String] { [:] }
    #endif

    private static func testValue(_ key: String) -> String? {
        isUITesting ? env[key].flatMap { $0.isEmpty ? nil : $0 } : nil
    }

    /// Settings store. UI tests get a private, freshly emptied suite.
    static let defaults: UserDefaults = {
        guard isUITesting else { return .standard }
        let suite = "com.macvault.uitests"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        // No menu bar item or notifications during tests.
        defaults.set(false, forKey: "showMenuBarExtra")
        // AppKit autosaves the window frame and the sidebar split state in the standard domain, so a
        // run that ended with the sidebar collapsed would change how the next one starts. Tests always
        // start with the sidebar shown and the window sized by MACVAULT_WINDOW_SIZE.
        for key in UserDefaults.standard.dictionaryRepresentation().keys
        where key.hasPrefix("NSSplitView Subview Frames") || key.hasPrefix("NSWindow Frame") {
            UserDefaults.standard.removeObject(forKey: key)
        }
        return defaults
    }()

    static func storeURL() throws -> URL {
        if let path = testValue("MACVAULT_DB_PATH") { return URL(fileURLWithPath: path) }
        return try Store.defaultURL()
    }

    static var home: String { testValue("MACVAULT_HOME") ?? NSHomeDirectory() }

    /// Folders to authorize at launch (UI tests cannot drive the open panel). Colon-separated.
    static var initialLocations: [String] {
        testValue("MACVAULT_LOCATIONS")?.split(separator: ":").map(String.init) ?? []
    }

    static var safetyPolicy: SafetyPolicy {
        let own = (try? storeURL())?.deletingLastPathComponent().path
        guard isUITesting else { return SafetyPolicy(ownDataDirectory: own) }
        // All default system roots apply: `isUITesting` refuses a fixture home inside one (the runner's
        // fixture is in its container under ~/Library/Containers, which is not a system root).
        return SafetyPolicy(home: home, applicationRoots: testValue("MACVAULT_APPLICATIONS").map { [$0] },
                            ownDataDirectory: own)
    }

    /// The real Finder Trash, or in UI tests a folder inside the fixture.
    static var trasher: FileTrasher {
        guard let directory = testValue("MACVAULT_TRASH_DIR") else { return .system }
        return FileTrasher { path in
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let destination = directory + "/" + UUID().uuidString + "-" + (path as NSString).lastPathComponent
            try FileManager.default.moveItem(atPath: path, toPath: destination)
            return destination
        }
    }
}

// MARK: - UI test hooks (screenshots)

extension AppEnvironment {
    /// UI tests only: the main window's content size, from `MACVAULT_WINDOW_SIZE` ("960x620").
    /// Used by the screenshot test to check the smallest and a large layout. Nil in release builds.
    static var uiTestWindowSize: CGSize? {
        guard let value = testValue("MACVAULT_WINDOW_SIZE") else { return nil }
        let parts = value.lowercased().split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
        return CGSize(width: parts[0], height: parts[1])
    }

    /// UI tests only: seconds a scan waits in its running state before reading, from
    /// `MACVAULT_SCAN_DELAY`, so the screenshot test can capture the progress panel of a scan of a
    /// tiny fixture. Zero in release builds. Cancelling the scan ends the wait.
    static var uiTestScanDelay: Double {
        testValue("MACVAULT_SCAN_DELAY").flatMap(Double.init) ?? 0
    }

    /// UI tests only: whether the first-launch permissions sheet opens. Tests start with a fresh
    /// settings suite, so without this the sheet would cover every screen in every test; the test
    /// that checks the sheet sets `MACVAULT_SHOW_PERMISSIONS=1`. Follows the setting otherwise.
    static var showsFirstLaunchPermissions: Bool {
        guard isUITesting else { return true }
        return testValue("MACVAULT_SHOW_PERMISSIONS") == "1"
    }

    /// UI tests only: the app's appearance, from `MACVAULT_APPEARANCE` ("light" or "dark"), so the
    /// screenshot test can check both whatever the Mac is set to (`-AppleInterfaceStyle` can only
    /// force dark). Nil in release builds.
    static var uiTestAppearance: NSAppearance? {
        switch testValue("MACVAULT_APPEARANCE")?.lowercased() {
        case "light": return NSAppearance(named: .aqua)
        case "dark": return NSAppearance(named: .darkAqua)
        default: return nil
        }
    }

    /// UI tests only: applies the test appearance and makes sure the main window opens. Does nothing
    /// otherwise (and in release builds).
    @MainActor
    static func applyUITestHooks() {
        if let appearance = uiTestAppearance { NSApp.appearance = appearance }
        ensureUITestWindow()
    }

    /// UI tests only: makes sure the main window opens. When another copy of MacVault with the same
    /// bundle identifier is already running (for example one started from Xcode), macOS can deliver
    /// the launch event to that copy, and the copy under test opens no window. If no window is shown
    /// shortly after launch, this process sends itself a reopen event, which opens the main window.
    /// Does nothing otherwise (and in release builds).
    @MainActor
    private static func ensureUITestWindow() {
        #if DEBUG
        guard isUITesting else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) else { return }
            let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass),
                                               eventID: AEEventID(kAEReopenApplication),
                                               targetDescriptor: NSAppleEventDescriptor(processIdentifier: getpid()),
                                               returnID: AEReturnID(kAutoGenerateReturnID),
                                               transactionID: AETransactionID(kAnyTransactionID))
            _ = try? event.sendEvent(options: [.noReply], timeout: 5)
        }
        #endif
    }
}

extension View {
    /// UI tests only: sizes the hosting window to `MACVAULT_WINDOW_SIZE` (content size), placed at the
    /// top left of its screen. Does nothing otherwise (and in release builds).
    @ViewBuilder
    func uiTestWindowSize() -> some View {
        if let size = AppEnvironment.uiTestWindowSize {
            background(UITestWindowSizer(size: size))
        } else {
            self
        }
    }
}

private struct UITestWindowSizer: NSViewRepresentable {
    let size: CGSize

    func makeNSView(context: Context) -> NSView { SizingView(size: size) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class SizingView: NSView {
        let size: CGSize
        init(size: CGSize) {
            self.size = size
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Again after window restoration, which may set its own frame once the window is shown.
            for delay in [0.0, 0.5, 1.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.apply() }
            }
        }

        private func apply() {
            guard let window, let screen = window.screen ?? NSScreen.main else { return }
            let content = NSRect(origin: .zero, size: size)
            var frame = window.frameRect(forContentRect: content)
            let visible = screen.visibleFrame
            frame.size.width = min(frame.width, visible.width)
            frame.size.height = min(frame.height, visible.height)
            frame.origin = NSPoint(x: visible.minX, y: visible.maxY - frame.height)
            window.setFrame(frame, display: true)
        }
    }
}
