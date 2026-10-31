import XCTest

/// Visual review: visits every screen and its important states against the same fixture as
/// `MacVaultUITests`, and attaches a screenshot of the main window for each (kept in the result
/// bundle; export with `xcrun xcresulttool export attachments`). Runs in light and dark appearance,
/// at the minimum window size and at a large one. It asserts only what it needs to reach each
/// state; the behaviour itself is covered by `MacVaultUITests`.
///
/// Skipped unless requested, because it is slow and needs screen capture. Run it with
/// `Scripts/ui-screenshots.sh <output folder>`, or set `TEST_RUNNER_MACVAULT_SCREENSHOTS` for xcodebuild:
/// - `attach`: `XCUIElement.screenshot()`; needs Screen Recording permission for the test runner.
/// - `shell`: the test asks `Scripts/ui-screenshots.sh` (outside the sandbox) to capture the window's
///   screen area with `screencapture`, through files in the runner's temporary folder.
final class ScreenshotUITests: XCTestCase {
    private var fixture: Fixture!
    private var app: XCUIApplication!
    private var prefix = ""
    private var shot = 0

    private static let mode = ProcessInfo.processInfo.environment["MACVAULT_SCREENSHOTS"] ?? ""

    override func setUpWithError() throws {
        try XCTSkipUnless(["attach", "shell"].contains(Self.mode),
                          "Visual review only: run Scripts/ui-screenshots.sh (or set TEST_RUNNER_MACVAULT_SCREENSHOTS)")
        continueAfterFailure = true
        fixture = try Fixture()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        // Restore permissions changed for the partial-scan state, so the fixture can be removed.
        if let fixture { chmod(fixture.path("home/scan/Docs"), 0o755) }
        fixture = nil
    }

    func testScreensLightMinimum() throws { try captureAll(dark: false, size: "960x620") }
    func testScreensDarkMinimum() throws { try captureAll(dark: true, size: "960x620") }
    func testScreensLightLarge() throws { try captureAll(dark: false, size: "1600x1000") }
    func testScreensDarkLarge() throws { try captureAll(dark: true, size: "1600x1000") }

    // MARK: Flow

    private func captureAll(dark: Bool, size: String) throws {
        prefix = "\(dark ? "dark" : "light")-\(size)"
        launch(dark: dark, size: size)

        // Overview
        wait(text("System-reported capacity"), "overview")
        capture("overview")

        // Storage Analyzer: not scanned, scanning, results, drill-down, treemap, largest files.
        open("Storage Analyzer")
        wait(app.buttons["scanButton"], "scan button")
        capture("analyzer-not-scanned")
        app.buttons["scanButton"].click()
        wait(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Scan in progress")).firstMatch,
             "scan progress", timeout: 10)
        capture("analyzer-scanning")
        wait(app.staticTexts["Completed"], "completed scan", timeout: 60)
        capture("analyzer-breakdown")
        wait(app.descendants(matching: .any)["breakdownRow-Videos"], "Videos row").doubleClick()
        wait(app.descendants(matching: .any)["breakdownRow-trips"], "child folder trips")
        capture("analyzer-drilldown")
        app.radioButtons["Treemap"].click()
        wait(app.descendants(matching: .any)["treemapTile-trips"], "treemap tile")
        capture("analyzer-treemap")
        app.radioButtons["Largest Files"].click()
        wait(text("Files of"), "largest files")
        capture("analyzer-largest-files")
        app.radioButtons["Breakdown"].click()

        // Partial scan: one folder the app can't read.
        chmod(fixture.path("home/scan/Docs"), 0o000)
        app.buttons["scanButton"].click()
        wait(text("Scan incomplete"), "partial scan banner", timeout: 60)
        capture("analyzer-partial-scan")
        if app.buttons["Show Items"].exists {
            app.buttons["Show Items"].click()
            capture("analyzer-partial-scan-items")
        }
        chmod(fixture.path("home/scan/Docs"), 0o755)

        // Cleaner: empty, results, approval sheet, result banner and history.
        open("Cleaner")
        wait(button("Find Items"), "find items")
        capture("cleaner-empty")
        button("Find Items").click()
        wait(app.descendants(matching: .any)["candidate-com.example.cache"], "cache candidate")
        capture("cleaner-results")
        // Move only one cache, keeping the Editor app's cache for the Applications screen.
        let deselectAll = app.buttons["Deselect All"].firstMatch
        if deselectAll.exists { deselectAll.click() }
        app.checkBoxes["select-com.example.cache"].click()
        button("Review & Move to Trash…").click()
        wait(app.descendants(matching: .any)["approvalTitle"], "approval sheet")
        capture("approval-sheet", over: [app.sheets.firstMatch])
        app.buttons["approvalConfirm"].click()
        wait(app.descendants(matching: .any)["operationResult"], "result banner")
        capture("cleaner-result-banner")
        let history = app.descendants(matching: .any)["historyToggle"].firstMatch
        if history.waitForExistence(timeout: 5) {
            history.click()
            capture("cleaner-history")
            history.click()
        }

        // Developer Tools: global caches (with a high-risk approval), project build folders.
        open("Developer Tools")
        wait(button("Find Caches"), "find caches")
        capture("developer-caches-empty")
        button("Find Caches").click()
        let archive = wait(app.checkBoxes["select-2026-01-01"], "archive checkbox")
        capture("developer-caches-results")
        let derived = app.checkBoxes["select-Proj-abc"]
        if derived.exists, (derived.value as? Int) == 1 { derived.click() }
        archive.click()
        button("Review & Move to Trash…").click()
        wait(app.descendants(matching: .any)["approvalTitle"], "approval sheet")
        capture("approval-sheet-high-risk", over: [app.sheets.firstMatch])
        app.checkBoxes["riskAcknowledgement"].click()
        capture("approval-sheet-high-risk-acknowledged", over: [app.sheets.firstMatch])
        app.buttons["approvalCancel"].click()
        app.radioButtons["Project Build Folders"].click()
        wait(button("Find Build Folders"), "find build folders")
        capture("developer-projects-empty")
        button("Find Build Folders").click()
        wait(app.descendants(matching: .any)["candidate-node_modules"], "node_modules")
        capture("developer-projects-results")

        // Applications: empty, list + detail, narrowest detail.
        open("Applications")
        wait(button("List Applications"), "list applications")
        capture("applications-empty")
        button("List Applications").click()
        wait(app.outlines.staticTexts["Editor"], "Editor row").click()
        wait(app.descendants(matching: .any)["candidate-com.example.editor"], "leftover")
        capture("applications-detail")
        if size == "960x620" {
            dragApplicationsToNarrowest()
            capture("applications-detail-narrowest")
        }

        // Duplicates: empty, results.
        open("Duplicates")
        wait(button("Find Duplicates"), "find duplicates")
        capture("duplicates-empty")
        button("Find Duplicates").click()
        wait(text("2 copies"), "duplicate group", timeout: 60)
        capture("duplicates-results")

        // Activity: table, detail, export menu.
        open("Activity")
        let movedEvent = wait(text("Moved to the Trash"), "activity row")
        capture("activity")
        movedEvent.click()
        capture("activity-detail")
        app.menuButtons["Export"].click()
        let exportItem = app.menuItems["JSON with Full Paths…"]
        _ = exportItem.waitForExistence(timeout: 5)
        capture("activity-export-menu", over: [exportItem])
        app.typeKey(.escape, modifierFlags: [])

        // Settings: top and bottom of the form.
        open("Settings")
        wait(app.popUpButtons["schedulePicker"], "schedule picker")
        capture("settings")
        // The form's scroll view (not the sidebar's): the one holding the schedule picker.
        let form = app.scrollViews.containing(.popUpButton, identifier: "schedulePicker").firstMatch
        if form.exists {
            form.scroll(byDeltaX: 0, deltaY: -3000)
            capture("settings-bottom")
        }

        // Overview again, now with scans and activity.
        open("Overview")
        wait(text("System-reported capacity"), "overview")
        capture("overview-with-data")
    }

    // MARK: Helpers

    private func launch(dark: Bool, size: String) {
        app = XCUIApplication()
        app.launchArguments = ["-MacVaultUITesting", "-AppleInterfaceStyle", dark ? "Dark" : "Light"]
        app.launchEnvironment = [
            "MACVAULT_DB_PATH": fixture.path("db/macvault.sqlite"),
            "MACVAULT_HOME": fixture.path("home"),
            "MACVAULT_LOCATIONS": fixture.path("home/scan"),
            "MACVAULT_APPLICATIONS": fixture.path("home/Applications"),
            "MACVAULT_TRASH_DIR": fixture.path("trash"),
            "MACVAULT_WINDOW_SIZE": size,
            // `-AppleInterfaceStyle` can only force dark; this sets either appearance.
            "MACVAULT_APPEARANCE": dark ? "dark" : "light",
            "MACVAULT_SCAN_DELAY": "3",
        ]
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 45), "main window")
        // Let the window sizing hook and the first layout settle.
        RunLoop.current.run(until: Date().addingTimeInterval(2))
    }

    /// `over`: elements drawn over or beyond the window (sheet, menu) to include in the capture.
    private func capture(_ name: String, over: [XCUIElement] = []) {
        // Let animations finish.
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        shot += 1
        let title = String(format: "%@-%02d-%@", prefix, shot, name)
        let attachment: XCTAttachment
        if Self.mode == "shell" {
            guard let file = shellCapture(title, over: over) else {
                XCTFail("no screenshot for \(title): is Scripts/ui-screenshots.sh running?")
                return
            }
            attachment = XCTAttachment(contentsOfFile: file, uniformTypeIdentifier: "public.png")
        } else {
            attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        }
        attachment.name = title
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Asks the capture script for a screenshot of the window's screen area (with any sheet or menu
    /// over it) and waits for the PNG. The runner is sandboxed; its temporary folder is the exchange.
    private func shellCapture(_ title: String, over: [XCUIElement]) -> URL? {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macvault-shots")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var area = app.windows.firstMatch.frame
        for element in over where element.exists { area = area.union(element.frame) }
        let png = directory.appendingPathComponent(title + ".png")
        let request = directory.appendingPathComponent(title + ".request")
        try? FileManager.default.removeItem(at: png)
        let rect = [area.minX, area.minY, area.width, area.height].map { String(Int($0.rounded())) }.joined(separator: ",")
        try? rect.write(to: request, atomically: true, encoding: .utf8)
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: png.path),
               !FileManager.default.fileExists(atPath: request.path) { return png }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        try? FileManager.default.removeItem(at: request)
        return nil
    }

    private func open(_ item: String) {
        let row = app.outlines.staticTexts[item]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "sidebar item \(item)")
        row.click()
    }

    private func button(_ title: String) -> XCUIElement { app.buttons[title].firstMatch }

    private func text(_ text: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).element(boundBy: 0)
    }

    @discardableResult
    private func wait(_ element: XCUIElement, _ what: String, timeout: TimeInterval = 30) -> XCUIElement {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "timed out waiting for \(what)")
        return element
    }

    private func chmod(_ path: String, _ mode: Int) {
        try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
    }

    /// The widest sidebar and the app list's divider dragged as far right as it goes.
    private func dragApplicationsToNarrowest() {
        let window = app.windows.firstMatch
        func splitters() -> [XCUIElement] {
            (0..<app.splitters.count).map { app.splitters.element(boundBy: $0) }.sorted { $0.frame.minX < $1.frame.minX }
        }
        guard splitters().count == 2 else { return }
        for (index, distance) in [(0, CGFloat(60)), (1, window.frame.maxX - 10 - splitters()[1].frame.midX)] {
            let handle = splitters()[index].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            handle.click(forDuration: 0.3, thenDragTo: handle.withOffset(CGVector(dx: distance, dy: 0)))
        }
    }
}
