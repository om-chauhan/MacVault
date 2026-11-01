import XCTest

/// End-to-end tests of every screen. The app runs in UI test mode (DEBUG only): its database,
/// settings, home folder, Applications folder and Trash all point into a fixture created per test,
/// so these tests never read or change anything outside it.
final class MacVaultUITests: XCTestCase {
    private var fixture: Fixture!
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        fixture = try Fixture()
        app = XCUIApplication()
        app.launchArguments = ["-MacVaultUITesting"]
        app.launchEnvironment = [
            "MACVAULT_DB_PATH": fixture.path("db/macvault.sqlite"),
            "MACVAULT_HOME": fixture.path("home"),
            "MACVAULT_LOCATIONS": fixture.path("home/scan"),
            "MACVAULT_APPLICATIONS": fixture.path("home/Applications"),
            "MACVAULT_TRASH_DIR": fixture.path("trash"),
        ]
        app.launch()
        app.activate()
        // The first launch of a freshly signed build can take a while (code-signature checks).
        let window = app.windows.firstMatch
        if !window.waitForExistence(timeout: 45) {
            print("HIERARCHY:\n\(app.debugDescription)")
            XCTFail("main window did not appear")
        }
    }

    override func tearDownWithError() throws {
        app?.terminate()
        fixture = nil
    }

    // MARK: Helpers

    private func open(_ item: String) {
        let row = app.outlines.staticTexts[item]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "sidebar item \(item)")
        row.click()
    }

    private func element(labelContains text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// Static text whose label or value contains `text`. Headers (`.isHeader`) and most SwiftUI
    /// `Text` expose their string as a label; text in forms and lists is exposed as a value.
    /// Do not use `.firstMatch` here: for a typed query (`app.staticTexts`, or `elementType == …`
    /// in the predicate) its fast path reports `exists == false` for label-only texts such as the
    /// Overview subtitle, even while the same query's `count` is 1. `element(boundBy: 0)` resolves
    /// the full query and finds both label and value texts.
    private func text(containing text: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text))
            .element(boundBy: 0)
    }

    /// Regression guard for content laid out taller than the window (a List that grows to its
    /// content height pushes rows and buttons off screen, where they cannot be clicked). Records a
    /// failure without stopping the test, so the safety assertions that follow still run.
    private func assertInsideWindow(_ element: XCUIElement, _ what: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let window = app.windows.firstMatch
        let previous = continueAfterFailure
        continueAfterFailure = true
        defer { continueAfterFailure = previous }
        guard element.exists, window.exists else {
            XCTFail("\(what) does not exist (window exists: \(window.exists))", file: file, line: line)
            return
        }
        let frame = element.frame
        let windowFrame = window.frame
        // 2 pt tolerance: the sidebar outline sits 1 pt outside the window edge.
        let inside = windowFrame.insetBy(dx: -2, dy: -2).contains(frame)
        if !inside || !element.isHittable { dumpHierarchy("layout: \(what)") }
        XCTAssertTrue(inside, "content laid out outside the window: \(what) frame \(frame) is not inside window frame \(windowFrame)",
                      file: file, line: line)
        XCTAssertTrue(element.isHittable, "content laid out outside the window: \(what) is not hittable (frame \(frame), window \(windowFrame))",
                      file: file, line: line)
    }

    private func button(_ title: String) -> XCUIElement { app.buttons[title].firstMatch }

    /// The app's "~" display form of a path. The runner is sandboxed, so its `NSHomeDirectory()` is
    /// its container; the app (Direct, not sandboxed) abbreviates the account's real home folder.
    private func abbreviatingHome(_ path: String) -> String {
        guard let entry = getpwuid(getuid()) else { return path }
        let home = String(cString: entry.pointee.pw_dir)
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    @discardableResult
    private func wait(_ element: XCUIElement, _ what: String, timeout: TimeInterval = 30) -> XCUIElement {
        if !element.waitForExistence(timeout: timeout) {
            dumpHierarchy(what)
            XCTFail("timed out waiting for \(what)")
        }
        return element
    }

    /// Writes the accessibility hierarchy to diagnose a failure. The UI test runner is sandboxed, so
    /// `NSTemporaryDirectory()` is the runner's container, not the shell's `$TMPDIR`: dumps land in
    /// `~/Library/Containers/com.macvault.uitests.xctrunner/Data/tmp/macvault-ui-failure-<test>.txt`.
    /// The full path is also printed as `HIERARCHY-DUMP:` in the test log.
    private func dumpHierarchy(_ label: String) {
        let path = NSTemporaryDirectory() + "macvault-ui-failure-\(name.filter { $0.isLetter || $0.isNumber }).txt"
        try? "\(label)\n\(app.debugDescription)".write(toFile: path, atomically: true, encoding: .utf8)
        print("HIERARCHY-DUMP: \(path)")
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 20, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTFail("timed out waiting until \(what)")
    }

    private func approveSheet(expectTitle: String) {
        let title = wait(app.descendants(matching: .any)["approvalTitle"], "approval sheet")
        let shown = [title.label, title.value as? String ?? ""].joined(separator: " ")
        if !shown.contains(expectTitle) { dumpHierarchy("approval title: \(shown)") }
        XCTAssertTrue(shown.contains(expectTitle), "sheet title “\(shown)” mentions \(expectTitle)")
        app.buttons["approvalConfirm"].click()
        wait(app.descendants(matching: .any)["operationResult"], "result banner")
    }

    // MARK: Tests

    func testOverviewAndNavigationToEveryScreen() {
        wait(text(containing: "System-reported capacity"), "overview subtitle")
        for item in ["Storage Analyzer", "Cleaner", "Applications", "Duplicates", "Developer Tools", "Activity", "Settings", "Overview"] {
            open(item)
            XCTAssertFalse(element(labelContains: "Planned").exists || text(containing: "Planned").exists,
                           "\(item) must not show a placeholder")
        }
    }

    func testScanDrillDownAndTreemap() {
        open("Storage Analyzer")
        wait(app.buttons["scanButton"], "scan button").click()
        wait(app.staticTexts["Completed"], "completed scan", timeout: 60)

        let videos = wait(app.descendants(matching: .any)["breakdownRow-Videos"], "Videos row")
        assertInsideWindow(videos, "Storage Analyzer breakdownRow-Videos")
        videos.doubleClick()
        // Breadcrumbs are link-style buttons, which accessibility reports as links.
        wait(app.descendants(matching: .any)["crumb-Videos"], "breadcrumb")
        wait(app.descendants(matching: .any)["breakdownRow-trips"], "child folder trips")
        wait(app.descendants(matching: .any)["breakdownRow-Files here and smaller folders"], "remainder row")

        app.radioButtons["Treemap"].click()
        let tile = wait(app.descendants(matching: .any)["treemapTile-trips"], "treemap tile")
        tile.click()
        wait(app.descendants(matching: .any)["crumb-trips"], "drilled into trips via treemap")
        wait(app.descendants(matching: .any)["treemapTile-2026"], "nested tile")

        app.radioButtons["Largest Files"].click()
        wait(text(containing: "Files of"), "largest files header")
    }

    func testCleanerCancelChangesNothingAndApproveMovesToTrash() throws {
        open("Cleaner")
        button("Find Items").click()
        let cacheRow = wait(app.descendants(matching: .any)["candidate-com.example.cache"], "cache candidate")
        assertInsideWindow(cacheRow, "Cleaner candidate-com.example.cache")
        assertInsideWindow(button("Review & Move to Trash…"), "Cleaner “Review & Move to Trash…” button")
        let cache = fixture.path("home/Library/Caches/com.example.cache")

        // Cancel: nothing changes.
        button("Review & Move to Trash…").click()
        wait(app.descendants(matching: .any)["approvalTitle"], "approval sheet")
        app.buttons["approvalCancel"].click()
        XCTAssertTrue(fixture.exists("home/Library/Caches/com.example.cache"))
        XCTAssertEqual(fixture.trashCount, 0)

        // Approve: items move to the (fixture) Trash.
        button("Review & Move to Trash…").click()
        approveSheet(expectTitle: "to the Trash?")
        waitUntil("cache is moved") { !FileManager.default.fileExists(atPath: cache) }
        XCTAssertGreaterThan(fixture.trashCount, 0)
        waitUntil("old log is moved (pre-selected: older than 7 days)") { !fixture.exists("home/Library/Logs/OldApp") }
        XCTAssertTrue(fixture.exists("home/Library/Caches"), "the Caches folder itself is never removed")
        // The result banner wraps its message; it must not push the screen taller than the window.
        assertInsideWindow(app.descendants(matching: .any)["operationResult"], "Cleaner result banner")
        assertInsideWindow(button("Check Again"), "Cleaner “Check Again” button (after the result banner)")
        assertInsideWindow(button("Review & Move to Trash…"), "Cleaner “Review & Move to Trash…” button (after the result banner)")

        open("Activity")
        wait(text(containing: "Moved to the Trash"), "audit entry for moved item")
        // The detail pane is the right half of a split view: it must fit the window's width.
        assertInsideWindow(text(containing: "Select an event to see its details."), "Activity event detail pane")
    }

    func testHighRiskItemsNeedAcknowledgement() {
        open("Developer Tools")
        button("Find Caches").click()
        let archive = wait(app.checkBoxes["select-2026-01-01"], "archive checkbox (not pre-selected)")
        XCTAssertEqual(archive.value as? Int, 0, "high-risk items are never pre-selected")
        // Rows further down (like the archive) may legitimately be below the fold of a list that
        // scrolls; the first row and the footer button must be inside the window.
        let derived = app.checkBoxes["select-Proj-abc"]
        assertInsideWindow(derived, "Developer Tools select-Proj-abc checkbox (first row)")
        assertInsideWindow(button("Review & Move to Trash…"), "Developer Tools “Review & Move to Trash…” button")
        // Deselect everything else so only the archive is reviewed.
        if derived.exists, (derived.value as? Int) == 1 { derived.click() }
        archive.click()
        button("Review & Move to Trash…").click()
        wait(app.descendants(matching: .any)["approvalTitle"], "approval sheet")
        let confirm = app.buttons["approvalConfirm"]
        XCTAssertFalse(confirm.isEnabled, "confirm stays disabled until the risk is acknowledged")
        app.checkBoxes["riskAcknowledgement"].click()
        XCTAssertTrue(confirm.isEnabled)
        app.buttons["approvalCancel"].click()
        XCTAssertTrue(fixture.exists("home/Library/Developer/Xcode/Archives/2026-01-01"))
    }

    func testProjectBuildFolders() {
        open("Developer Tools")
        app.radioButtons["Project Build Folders"].click()
        button("Find Build Folders").click()
        wait(app.descendants(matching: .any)["candidate-node_modules"], "node_modules candidate")
        button("Review & Move to Trash…").click()
        approveSheet(expectTitle: "to the Trash?")
        waitUntil("node_modules moved") { !fixture.exists("home/scan/web/node_modules") }
        XCTAssertTrue(fixture.exists("home/scan/web/package.json"), "project files are untouched")
    }

    func testDuplicatesKeepOneCopy() {
        open("Duplicates")
        button("Find Duplicates").click()
        wait(text(containing: "2 copies"), "duplicate group", timeout: 60)
        let review = wait(button("Review & Move Copies to Trash…"), "review copies button")
        assertInsideWindow(review, "Duplicates “Review & Move Copies to Trash…” button")
        assertInsideWindow(text(containing: "2 copies"), "Duplicates group header")
        // Each copy's checkbox is its own control, not merged with "Keep This": one copy is selected,
        // the kept copy is unselected and can't be selected.
        let copies = app.checkBoxes.matching(NSPredicate(format: "identifier BEGINSWITH %@", "dup-"))
        XCTAssertEqual(copies.count, 2, "one checkbox per copy")
        let states = (0..<copies.count).map { copies.element(boundBy: $0) }.map { ($0.value as? Int ?? -1, $0.isEnabled) }
        XCTAssertEqual(states.filter { $0 == (1, true) }.count, 1, "one copy is selected to move: \(states)")
        XCTAssertEqual(states.filter { $0 == (0, false) }.count, 1, "the kept copy is unselected and locked: \(states)")
        // Each checkbox names its file and says whether it is the kept copy.
        let labels = (0..<copies.count).map { copies.element(boundBy: $0).label }
        XCTAssertEqual(Set(labels).count, 2, "checkbox labels differ per file: \(labels)")
        XCTAssertEqual(labels.filter { $0.hasPrefix("Kept copy ") && $0.hasSuffix(".jpg") }.count, 1, "kept copy is labelled: \(labels)")
        XCTAssertEqual(labels.filter { $0.hasPrefix("Move ") && $0.hasSuffix(".jpg to the Trash") }.count, 1, "copy to move is labelled: \(labels)")
        // "Keep This" is a separate button per copy, labelled with its file. Choosing it swaps the
        // kept copy, so the button moves to the other file and its label changes with it.
        let keepButtons = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "keep-"))
        XCTAssertEqual(keepButtons.count, 1, "one “Keep This” button, on the copy that is not kept")
        let firstKeep = keepButtons.element(boundBy: 0)
        let (firstID, firstLabel) = (firstKeep.identifier, firstKeep.label)
        XCTAssertEqual(firstLabel, "Keep " + abbreviatingHome(String(firstID.dropFirst("keep-".count))),
                       "“Keep This” is labelled with its file")
        firstKeep.click()
        waitUntil("“Keep This” moves to the other copy") {
            keepButtons.count == 1 && keepButtons.element(boundBy: 0).identifier != firstID
        }
        let secondKeep = keepButtons.element(boundBy: 0)
        XCTAssertNotEqual(secondKeep.label, firstLabel, "“Keep This” labels differ per file")
        XCTAssertEqual(secondKeep.label, "Keep " + abbreviatingHome(String(secondKeep.identifier.dropFirst("keep-".count))))
        // Identifiers this long need a predicate (subscripts are limited to 128 characters).
        let newlyKept = app.checkBoxes.matching(NSPredicate(format: "identifier == %@", "dup-" + firstID.dropFirst("keep-".count)))
            .element(boundBy: 0)
        XCTAssertTrue(newlyKept.label.hasPrefix("Kept copy "), "the newly kept copy's checkbox says so: \(newlyKept.label)")
        review.click()
        approveSheet(expectTitle: "Move 1 item")
        waitUntil("one copy moved") {
            fixture.exists("home/scan/Photos/beach.jpg") != fixture.exists("home/scan/Backup/beach copy.jpg")
        }
        XCTAssertTrue(fixture.exists("home/scan/Photos/beach.jpg") || fixture.exists("home/scan/Backup/beach copy.jpg"),
                      "exactly one copy remains")
    }

    func testAppRemovalKeepsDataUntilReviewedSeparately() {
        open("Applications")
        button("List Applications").click()
        let row = wait(app.outlines.staticTexts["Editor"], "Editor app row")
        row.click()
        let leftover = wait(app.descendants(matching: .any)["candidate-com.example.editor"], "leftover candidate")
        assertInsideWindow(leftover, "Applications candidate-com.example.editor")
        let moveApp = wait(button("Move App to Trash…"), "move app button")
        assertInsideWindow(moveApp, "Applications “Move App to Trash…” button")
        moveApp.click()
        approveSheet(expectTitle: "Remove Editor")
        waitUntil("bundle moved") { !fixture.exists("home/Applications/Editor.app") }
        XCTAssertTrue(fixture.exists("home/Library/Caches/com.example.editor"), "app data is a separate decision")

        // The data's review button, docked under the app detail (its help has the full description).
        button("Move Data to Trash…").click()
        approveSheet(expectTitle: "Data of Editor")
        waitUntil("leftovers moved") { !fixture.exists("home/Library/Caches/com.example.editor") }
    }

    /// At the minimum window width with the widest sidebar (the app detail is a fixed-width inspector
    /// card, so this is its narrowest layout), the detail's buttons stay inside the window at their
    /// full width (not truncated).
    func testApplicationsDetailFitsNarrowestLayout() {
        open("Applications")
        button("List Applications").click()
        wait(app.outlines.staticTexts["Editor"], "Editor app row").click()
        // The app's action row, and the review button of its data, docked under the detail pane.
        wait(app.descendants(matching: .any)["candidate-com.example.editor"], "leftover candidate")
        let titles = ["Reveal in Finder", "Move App to Trash…", "Move Data to Trash…"]
        for title in titles { wait(button(title), "“\(title)” button") }
        // Default layout: the whole detail pane is inside the window, and each button has its full width.
        for title in titles { assertInsideWindow(button(title), "Applications “\(title)” button (default layout)") }
        let fullWidths = titles.map { button($0).frame.width }

        // Narrowest: minimum window width (dragging the right edge; the height is kept) and the widest
        // sidebar. The detail card has a fixed width, so nothing else can squeeze it.
        let window = app.windows.firstMatch
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -2, dy: -2))
        corner.click(forDuration: 0.3, thenDragTo: corner.withOffset(CGVector(dx: 960 - window.frame.width - 100, dy: 0)))
        XCTAssertEqual(window.frame.width, 960, accuracy: 1, "window is at its minimum width")
        func splitters() -> [XCUIElement] {
            (0..<app.splitters.count).map { app.splitters.element(boundBy: $0) }.sorted { $0.frame.minX < $1.frame.minX }
        }
        XCTAssertGreaterThanOrEqual(splitters().count, 1, "sidebar divider")
        // The drag target stays on screen (off-screen drags are dropped): the sidebar divider 60 pt
        // right (its maximum is 20 pt away).
        let handle = splitters()[0].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        handle.click(forDuration: 0.3, thenDragTo: handle.withOffset(CGVector(dx: 60, dy: 0)))
        let sidebarWidth = splitters()[0].frame.minX - window.frame.minX
        XCTAssertGreaterThanOrEqual(sidebarWidth, 238, "sidebar dragged to its widest (240)")

        for (title, fullWidth) in zip(titles, fullWidths) {
            let element = button(title)
            XCTAssertTrue(element.exists, "“\(title)” exists with its full title")
            assertInsideWindow(element, "Applications “\(title)” button (narrowest layout)")
            if element.frame.width < fullWidth - 1 { dumpHierarchy("truncated: \(title)") }
            XCTAssertGreaterThanOrEqual(element.frame.width, fullWidth - 1,
                                        "“\(title)” is not truncated: \(element.frame.width) pt wide, \(fullWidth) pt at full width")
        }
    }

    /// The sidebar toggle collapses and expands the sidebar, and in both states the screen header
    /// (title) stays visible and clear of the toggle button, which stays hittable.
    func testSidebarCollapsesAndExpands() {
        let window = app.windows.firstMatch
        let toggle = app.descendants(matching: .any)["sidebarToggle"].firstMatch
        wait(toggle, "sidebar toggle")
        // "Overview" is both a sidebar row and the screen header; the header is the topmost one.
        func headerTitle() -> XCUIElement? {
            app.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", "Overview", "Overview"))
                .allElementsBoundByIndex.filter(\.exists).min { $0.frame.minY < $1.frame.minY }
        }
        let deadline = Date().addingTimeInterval(10)
        while headerTitle() == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        guard let title = headerTitle() else { dumpHierarchy("no Overview header"); return XCTFail("Overview header title not found") }
        let sidebarRow = wait(app.outlines.staticTexts["Storage Analyzer"], "sidebar row before collapsing")
        attachScreenshot("sidebar-expanded")
        XCTAssertFalse(title.frame.intersects(toggle.frame),
                       "header title \(title.frame) must not overlap the sidebar toggle \(toggle.frame) with the sidebar shown")

        toggle.click()
        let collapsed = NSPredicate(format: "exists == false || isHittable == false")
        _ = XCTWaiter.wait(for: [expectation(for: collapsed, evaluatedWith: sidebarRow)], timeout: 5)
        attachScreenshot("sidebar-collapsed")
        XCTAssertFalse(sidebarRow.isHittable, "sidebar rows are hidden after collapsing")
        // The toolbar is rebuilt while the column animates away; the toggle comes back in the detail's section.
        wait(toggle, "sidebar toggle after collapsing", timeout: 10)
        XCTAssertTrue(toggle.isHittable, "toggle is still clickable when collapsed (frame \(toggle.frame))")
        let collapsedTitle = headerTitle() ?? title
        XCTAssertTrue(collapsedTitle.exists && collapsedTitle.isHittable, "header title visible when collapsed")
        XCTAssertTrue(window.frame.contains(collapsedTitle.frame), "header title inside the window when collapsed")
        let overlaps = collapsedTitle.frame.intersects(toggle.frame)
        if overlaps { dumpHierarchy("collapsed sidebar: title overlaps toggle") }
        XCTAssertFalse(overlaps, "header title \(collapsedTitle.frame) must not overlap the sidebar toggle \(toggle.frame)")
        // The header moves below the title bar row that now holds the window controls and the toggle.
        XCTAssertGreaterThanOrEqual(collapsedTitle.frame.minY, toggle.frame.maxY - 1,
                                    "header sits below the toggle row when the sidebar is collapsed")

        toggle.click()
        _ = sidebarRow.waitForExistence(timeout: 5)
        wait(toggle, "sidebar toggle after expanding", timeout: 10)
        attachScreenshot("sidebar-expanded-again")
        XCTAssertTrue(sidebarRow.isHittable, "sidebar rows are back after expanding")
        open("Storage Analyzer")
        wait(app.buttons["scanButton"], "scan button after re-expanding")
    }

    /// First launch shows one permissions sheet with every permission, its state and "Allow All";
    /// "Not Now" dismisses it and it can be reopened from the Overview card. The test never clicks
    /// "Allow All": that would show real macOS dialogs on the test Mac.
    func testPermissionsSheetShowsEverythingAtOnce() {
        // Relaunch as a first launch that shows the sheet (tests otherwise suppress it).
        app.terminate()
        app.launchEnvironment["MACVAULT_SHOW_PERMISSIONS"] = "1"
        app.launch()
        app.activate()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 30), "permissions sheet opens on first launch")
        attachScreenshot("permissions-sheet")
        wait(text(containing: "Allow MacVault to read your Mac"), "sheet title")
        let allowAll = wait(app.descendants(matching: .any)["permissionsAllowAll"].firstMatch, "Allow All")
        XCTAssertTrue(allowAll.isEnabled, "Allow All is the one consent button and is enabled")
        // Each row is one combined accessibility element (title, status, description).
        for row in ["Desktop, Documents and Downloads", "Notifications"] {
            wait(element(labelContains: row), "row \(row)")
        }
        let rows = ["permission-protectedFolders", "permission-scanLocations", "permission-notifications"]
        let visibleActions = rows.filter { app.descendants(matching: .any)[$0].firstMatch.exists }
        XCTAssertFalse(visibleActions.isEmpty, "at least one permission can be granted from its row")
        // Scan locations: the fixture folder is authorized, so that row needs nothing.
        XCTAssertFalse(app.descendants(matching: .any)["permission-scanLocations"].firstMatch.exists,
                       "an authorized folder counts as a scan location")

        wait(app.descendants(matching: .any)["permissionsNotNow"].firstMatch, "Not Now").click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10), "Not Now closes the sheet")
        // Reviewed once: no banner any more, but the Overview card still offers the sheet.
        wait(text(containing: "System-reported capacity"), "overview")
        XCTAssertFalse(app.descendants(matching: .any)["permissionsBanner"].firstMatch.exists, "banner is gone after review")
        let review = wait(app.descendants(matching: .any)["reviewPermissions"].firstMatch, "Permissions… button")
        assertInsideWindow(review, "Permissions… button on the Overview card")
        review.click()
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "sheet reopens from the Overview card")
        wait(app.descendants(matching: .any)["permissionsNotNow"].firstMatch, "close button").click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10), "sheet closes again")
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSettingsMonitoringAndActivityExportMenu() throws {
        open("Settings")
        wait(text(containing: "Scheduled read-only scans"), "schedule label")
        let schedule = wait(app.popUpButtons["schedulePicker"], "schedule picker")
        XCTAssertEqual(schedule.value as? String, "Off", "scheduled scans are off by default")
        wait(app.switches["lowStorageToggle"], "low storage toggle")
        let menuBar = wait(app.switches["menuBarToggle"], "menu bar toggle")
        XCTAssertEqual(menuBar.value as? Int, 0, "UI test mode starts with the menu bar item hidden")
        open("Activity")
        let export = wait(app.menuButtons["Export"], "export menu")
        export.click()
        // All items are read from one snapshot, taken as soon as the menu is open. macOS closes an
        // open menu when the app loses focus (here: another app's window becoming active during the
        // run), so separate long waits for each item could find the menu already closed.
        let menu = app.menus.containing(NSPredicate(format: "title == %@", "JSON…")).element(boundBy: 0)
        let deadline = Date().addingTimeInterval(10)
        while !menu.exists && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        if !menu.exists {
            dumpHierarchy("export menu did not open")
            XCTFail("the export menu did not open (MacVault in the foreground: \(app.state == .runningForeground))")
        }
        func titles(_ element: XCUIElementSnapshot) -> [String] { [element.title] + element.children.flatMap(titles) }
        let shown = Set(titles(try menu.snapshot()))
        let expected = ["JSON…", "CSV…", "JSON with Full Paths…", "CSV with Full Paths…"]
        let missing = expected.filter { !shown.contains($0) }
        if !missing.isEmpty { dumpHierarchy("export menu items: \(shown.sorted())") }
        XCTAssertEqual(missing, [], "every export item is in the menu; it shows \(shown.sorted())")
        app.typeKey(.escape, modifierFlags: [])
    }
}

/// A throwaway tree that stands in for the user's disk.
final class Fixture {
    let root: String

    init() throws {
        root = (NSTemporaryDirectory() as NSString).appendingPathComponent("macvault-ui-" + UUID().uuidString)
        // Fake home: caches, old logs, developer caches, leftovers of the fake app.
        try file("home/Library/Caches/com.example.cache/blob.bin", bytes: 200_000)
        try file("home/Library/Caches/com.example.other/blob.bin", bytes: 50_000)
        try file("home/Library/Caches/com.example.editor/data.bin", bytes: 30_000)
        try file("home/Library/Logs/OldApp/old.log", bytes: 4_000)
        try age("home/Library/Logs/OldApp/old.log", days: 30)
        try age("home/Library/Logs/OldApp", days: 30)
        try file("home/Library/Developer/Xcode/DerivedData/Proj-abc/Build/out.bin", bytes: 80_000)
        try file("home/Library/Developer/Xcode/Archives/2026-01-01/App.xcarchive/Info.plist", bytes: 1_000)
        // Folder to scan, inside the fake home like a real user folder: nested videos, an exact
        // duplicate pair, and a Node project. (The UI test runner is sandboxed, so the fixture is
        // under /Users/<user>/Library/Containers; anything outside the fake home would be refused
        // as "another user's folder".)
        try file("home/scan/Videos/trips/2026/clip.mov", bytes: 3_000_000)
        try file("home/scan/Videos/trips/2026/other.mov", bytes: 500_000)
        try file("home/scan/Videos/loose.mov", bytes: 200_000)
        try file("home/scan/Docs/note.txt", bytes: 100)
        let photo = Data((0..<1_500_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        try write("home/scan/Photos/beach.jpg", photo)
        try write("home/scan/Backup/beach copy.jpg", photo)
        try file("home/scan/web/package.json", bytes: 20)
        try file("home/scan/web/node_modules/left-pad/index.js", bytes: 40_000)
        // ~/Applications with one third-party app.
        let info: [String: Any] = ["CFBundleIdentifier": "com.example.editor", "CFBundleName": "Editor",
                                   "CFBundleShortVersionString": "2.1"]
        try file("home/Applications/Editor.app/Contents/MacOS/Editor", bytes: 120_000)
        try write("home/Applications/Editor.app/Contents/Info.plist",
                  try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0))
        try FileManager.default.createDirectory(atPath: path("trash"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: path("db"), withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(atPath: root) }

    func path(_ relative: String) -> String { (root as NSString).appendingPathComponent(relative) }

    func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: path(relative)) }

    var trashCount: Int { (try? FileManager.default.contentsOfDirectory(atPath: path("trash")).count) ?? 0 }

    private func file(_ relative: String, bytes: Int) throws { try write(relative, Data(count: bytes)) }

    private func write(_ relative: String, _ data: Data) throws {
        let p = path(relative)
        try FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: p))
    }

    private func age(_ relative: String, days: Double) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-days * 86_400)],
                                              ofItemAtPath: path(relative))
    }
}
