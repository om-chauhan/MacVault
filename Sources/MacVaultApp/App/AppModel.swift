import Foundation
import Observation
import MacVaultCore

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case overview, analyzer, cleaner, applications, duplicates, developer, activity, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .analyzer: return "Storage Analyzer"
        case .cleaner: return "Cleaner"
        case .applications: return "Applications"
        case .duplicates: return "Duplicates"
        case .developer: return "Developer Tools"
        case .activity: return "Activity"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.33percent"
        case .analyzer: return "chart.bar.doc.horizontal"
        case .cleaner: return "sparkles.rectangle.stack"
        case .applications: return "square.grid.2x2"
        case .duplicates: return "doc.on.doc"
        case .developer: return "hammer"
        case .activity: return "list.bullet.rectangle"
        case .settings: return "gearshape"
        }
    }
}

enum ScanPhase: Equatable {
    case idle
    case running(locationID: UUID, progress: ScanProgress)
    case failed(String)
}

@MainActor
@Observable
final class AppModel {
    var selection: SidebarItem? = .overview

    let access = AccessCoordinator()
    let settings = AppSettings()
    let permissions = PermissionsModel()
    /// The one-time permissions sheet; opened on first launch and from Settings or the Overview banner.
    var showPermissions = false

    private(set) var store: Store?
    private(set) var startupError: String?
    private var started = false

    // Volumes
    private(set) var volumes: [VolumeObservation] = []
    private(set) var volumeError: String?
    private(set) var isRefreshingVolumes = false
    private(set) var history: [String: [StorageSnapshot]] = [:]

    // Scans
    private(set) var recentScans: [ScanSessionRecord] = []
    private(set) var scanPhase: ScanPhase = .idle
    private(set) var lastWarnings: [String] = []
    private(set) var reconciledOnLaunch = LaunchReconciler.Outcome(interruptedScans: 0, interruptedOperations: 0)
    private var scanTask: Task<Void, Never>?

    var selectedLocationID: UUID?
    private(set) var displayedScan: ScanSessionRecord?
    private(set) var displayedFindings: [FileFinding] = []
    private(set) var displayedAggregates: [DirectoryAggregate] = []
    private(set) var displayedIssues: [ScanIssue] = []

    // Activity
    private(set) var recentEvents: [AuditEvent] = []

    // Maintenance features. Each builds review lists; only `operations` can move items to the Trash.
    let operations = OperationsModel()
    let cleaner = RuleScanModel(rules: RuleCatalog.cleanerRules, operationType: .cleanup)
    let developerCaches = RuleScanModel(rules: RuleCatalog.developerRules, operationType: .developerCleanup)
    let projects = ProjectArtifactsModel()
    let applications = ApplicationsModel()
    let duplicates = DuplicatesModel()

    // Monitoring
    private var monitorTask: Task<Void, Never>?
    private(set) var lastScheduledRun: Date?
    private(set) var scheduledRunActive = false

    /// True while a single scan runs, and for the whole of a scheduled run across several folders.
    var isScanning: Bool {
        if scheduledRunActive { return true }
        if case .running = scanPhase { return true }
        return false
    }

    var selectedLocation: AuthorizedLocation? {
        access.locations.first { $0.id == selectedLocationID } ?? access.locations.first
    }

    // MARK: Lifecycle

    func start() async {
        guard !started else { return }
        started = true
        do {
            let url = try AppEnvironment.storeURL()
            let store = try Store(path: url.path)
            self.store = store
            reconciledOnLaunch = try await LaunchReconciler.reconcile(store: store)
        } catch {
            startupError = "MacVault could not open its local database. Scan history and the activity log are unavailable. (\(error.localizedDescription))"
            Log.app.error("Store open failed")
        }
        operations.attach(store: { [weak self] in self?.store }, audit: { [weak self] event in await self?.audit(event) })
        for path in AppEnvironment.initialLocations { access.add(URL(fileURLWithPath: path)) }
        selectedLocationID = access.locations.first?.id
        await refreshVolumes()
        await reloadScans()
        await reloadActivity()
        await operations.reloadHistory()
        if let latest = latestScan(for: selectedLocation) { await show(scanID: latest.id) }
        startMonitoring()
        await permissions.refresh()
        if !settings.permissionsConsentShown && AppEnvironment.showsFirstLaunchPermissions {
            showPermissions = true
        }
    }

    // MARK: Volumes

    func refreshVolumes() async {
        isRefreshingVolumes = true
        defer { isRefreshingVolumes = false }
        let service = VolumeInfoService()
        let observed = await Task.detached(priority: .userInitiated) { service.mountedVolumes() }.value
        // Boot volume first, then by name.
        volumes = observed.sorted { a, b in
            if a.mountPath == "/" { return true }
            if b.mountPath == "/" { return false }
            return a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
        }
        volumeError = observed.isEmpty ? "No volume information could be read." : nil

        guard let store else { return }
        for volume in volumes {
            _ = try? await store.recordVolumeSnapshotIfDue(volume, minimumInterval: 3600)
            history[volume.id] = (try? await store.snapshots(volumeId: volume.id)) ?? []
        }
    }

    // MARK: Scans

    func reloadScans() async {
        guard let store else { return }
        recentScans = (try? await store.recentScans(limit: 50)) ?? []
    }

    func latestScan(for location: AuthorizedLocation?) -> ScanSessionRecord? {
        guard let location else { return nil }
        return recentScans.first { $0.rootPath == location.path }
    }

    func scans(for location: AuthorizedLocation?) -> [ScanSessionRecord] {
        guard let location else { return [] }
        return recentScans.filter { $0.rootPath == location.path }
    }

    func show(scanID: String) async {
        guard let store else { return }
        displayedScan = try? await store.scanSession(id: scanID)
        displayedFindings = (try? await store.findings(scanId: scanID)) ?? []
        displayedAggregates = (try? await store.aggregates(scanId: scanID)) ?? []
        displayedIssues = (try? await store.issues(scanId: scanID)) ?? []
    }

    /// Children of `parent` (nil = scan root) in the displayed scan's drill-down tree.
    func treeChildren(of parent: String?) async -> [TreeNode] {
        guard let store, let scan = displayedScan else { return [] }
        return (try? await store.treeNodes(scanId: scan.id, parentPath: parent)) ?? []
    }

    func selectLocation(_ id: UUID?) async {
        selectedLocationID = id
        clearDisplayedScan()
        if let latest = latestScan(for: selectedLocation) { await show(scanID: latest.id) }
    }

    private func clearDisplayedScan() {
        displayedScan = nil
        displayedFindings = []
        displayedAggregates = []
        displayedIssues = []
    }

    func chooseAndAddLocation() async {
        guard let location = access.chooseFolder(message: "Choose a folder for MacVault to scan. MacVault only reads this folder; it does not change or delete anything.") else { return }
        await audit(AuditEvent(operationId: nil, eventType: "access.granted", severity: .info,
                               message: "Folder access added: \(location.displayPath)"))
        await selectLocation(location.id)
    }

    /// Adds a typed folder path and selects it. Returns a message when the path cannot be used.
    @discardableResult
    func addLocation(path: String) async -> String? {
        switch access.addPath(path) {
        case .failure(let error):
            return error.message
        case .success(let location):
            await audit(AuditEvent(operationId: nil, eventType: "access.granted", severity: .info,
                                   message: "Folder access added: \(location.displayPath)"))
            await selectLocation(location.id)
            return nil
        }
    }

    /// Selects the whole startup disk as the scan scope, adding it on first use.
    @discardableResult
    func selectWholeMac() async -> String? {
        if let existing = access.locations.first(where: \.isWholeVolume) {
            await selectLocation(existing.id)
            return nil
        }
        return await addLocation(path: ScanConfiguration.wholeVolumeRoot)
    }

    func removeLocation(_ location: AuthorizedLocation) async {
        access.remove(location)
        await audit(AuditEvent(operationId: nil, eventType: "access.removed", severity: .info,
                               message: "Folder access removed: \(location.displayPath)"))
        if selectedLocationID == location.id { await selectLocation(access.locations.first?.id) }
    }

    func startScan() {
        guard !isScanning, let location = selectedLocation else { return }
        lastWarnings = []
        // Enter the running state synchronously so a second request before the task starts is refused.
        scanPhase = .running(locationID: location.id, progress: ScanProgress())
        scanTask = Task { [weak self] in
            await self?.performScan(location, display: true)
        }
    }

    /// Runs one read-only scan and records it. Returns true when the scan ran (any outcome but failure).
    @discardableResult
    private func performScan(_ location: AuthorizedLocation, display: Bool) async -> Bool {
        guard let store else { return false }
        let scoped: ScopedAccess
        switch access.beginAccess(location) {
        case .failure(let status):
            scanPhase = .failed(status == .needsReselection
                ? "Access to \(location.displayPath) has expired. Choose the folder again to continue."
                : "\(location.displayPath) is not available. It may have been moved, renamed or its volume ejected.")
            return false
        case .success(let value):
            scoped = value
        }
        defer { scoped.stop() }

        // A whole-Mac scan must skip /System/Volumes, or the Data volume would be counted twice.
        var config = ScanConfiguration(
            rootPath: location.path,
            exclusions: settings.exclusions + ScanConfiguration.implicitExclusions(forRoot: location.path),
            largeFileThresholdBytes: settings.largeFileThresholdBytes
        )
        config.crossMountPoints = settings.crossMountPoints

        let service = ScanService(store: store)
        let locationID = location.id
        scanPhase = .running(locationID: locationID, progress: ScanProgress())
        let onProgress: @Sendable (ScanProgress) async -> Void = { [weak self] progress in
            await self?.applyProgress(progress, locationID: locationID)
        }

        do {
            if AppEnvironment.uiTestScanDelay > 0 {
                // UI tests only (see AppEnvironment): hold the running state so it can be captured.
                try? await Task.sleep(for: .seconds(AppEnvironment.uiTestScanDelay))
            }
            let outcome = try await service.runScan(configuration: config, scopeDescription: location.displayPath,
                                                    onProgress: onProgress)
            _ = try? await store.pruneScans(keepLatest: settings.keepScans)
            lastWarnings += outcome.warnings
            scanPhase = outcome.failureMessage.map(ScanPhase.failed) ?? .idle
            await reloadScans()
            if display || locationID == selectedLocation?.id { await show(scanID: outcome.scanId) }
            await reloadActivity()
            await refreshVolumes()
            return outcome.failureMessage == nil
        } catch {
            scanPhase = .failed("The scan could not be recorded: \(error.localizedDescription)")
            await reloadActivity()
            return false
        }
    }

    private func applyProgress(_ progress: ScanProgress, locationID: UUID) {
        guard case .running = scanPhase else { return }
        scanPhase = .running(locationID: locationID, progress: progress)
    }

    /// Cooperative: the scanner stops at its next check and the session is recorded as Cancelled.
    func cancelScan() {
        scanTask?.cancel()
    }

    func dismissScanError() {
        if case .failed = scanPhase { scanPhase = .idle }
    }

    // MARK: Activity

    func reloadActivity(search: String? = nil, minimumSeverity: AuditSeverity? = nil) async {
        guard let store else { return }
        recentEvents = (try? await store.auditEvents(limit: 500, search: search, minimumSeverity: minimumSeverity)) ?? []
    }

    func audit(_ event: AuditEvent) async {
        guard let store else { return }
        do {
            try await store.appendAudit(event)
        } catch {
            lastWarnings.append("Activity log entry could not be written: \(error.localizedDescription)")
        }
        await reloadActivity()
    }

    // MARK: Data management

    func applyRetention() async -> Int? {
        guard let store else { return nil }
        let removed = try? await store.pruneScans(keepLatest: settings.keepScans)
        if let removed, removed > 0 {
            await audit(AuditEvent(operationId: nil, eventType: "retention.pruned", severity: .info,
                                   message: "Removed \(removed) older scan records (keeping the newest \(settings.keepScans))"))
        }
        await reloadScans()
        return removed
    }

    func deleteScanHistory() async {
        guard let store, !isScanning else { return }
        do {
            try await store.deleteScanHistory()
            await audit(AuditEvent(operationId: nil, eventType: "data.historyDeleted", severity: .notice,
                                   message: "Scan history, findings and storage snapshots were deleted by the user. No files on disk were changed."))
        } catch {
            lastWarnings.append("Scan history could not be deleted: \(error.localizedDescription)")
        }
        clearDisplayedScan()
        history = [:]
        await reloadScans()
    }

    // MARK: Monitoring

    /// While MacVault is open: refreshes capacity, warns about low space, and runs scheduled read-only scans.
    private func startMonitoring() {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(600))
                guard let self, !Task.isCancelled else { return }
                await self.monitorTick()
            }
        }
        Task { await evaluateLowStorage() }
    }

    func monitorTick() async {
        await refreshVolumes()
        await evaluateLowStorage()
        if settings.scanSchedule.isDue(lastRun: settings.lastScheduledScan, now: Date()), !isScanning,
           !access.locations.isEmpty {
            await runScheduledScans()
        }
    }

    /// Scans every accessible folder in turn. Read-only; a summary notification is posted when allowed.
    func runScheduledScans() async {
        guard !isScanning, !operations.isExecuting else { return }
        scheduledRunActive = true
        defer { scheduledRunActive = false }
        settings.lastScheduledScan = Date()
        lastWarnings = []
        let locations = access.locations.filter { access.status(of: $0) == .available }
        await audit(AuditEvent(operationId: nil, eventType: "schedule.started", severity: .info,
                               message: "Scheduled scan started for \(locations.count) folder(s)"))
        let task = Task { [weak self] () -> Int in
            var completed = 0
            for location in locations {
                guard let self, !Task.isCancelled else { break }
                if await self.performScan(location, display: false) { completed += 1 }
            }
            return completed
        }
        scanTask = Task {
            await withTaskCancellationHandler { _ = await task.value } onCancel: { task.cancel() }
        }
        let completed = await task.value
        lastScheduledRun = Date()
        if settings.notifyScheduledScans {
            Notifier.post(id: "scheduled-scan", title: "Scheduled scan finished",
                          body: "\(completed) of \(locations.count) folder(s) scanned. Nothing was changed.")
        }
    }

    func evaluateLowStorage() async {
        guard settings.lowStorageAlerts else { return }
        let monitor = LowStorageMonitor(thresholdFraction: Double(settings.lowStorageThresholdPercent) / 100)
        var warned = Set(settings.lowStorageWarnedVolumes)
        for volume in volumes where volume.isReadOnly != true {
            switch monitor.evaluate(volume, alreadyWarned: warned.contains(volume.id)) {
            case .warn(let fraction):
                warned.insert(volume.id)
                let percent = (fraction * 100).formatted(.number.precision(.fractionLength(0...1)))
                await audit(AuditEvent(operationId: nil, eventType: "storage.low", severity: .warning,
                                       message: "\(volume.displayName) has \(bytes(volume.availableBytes)) available (\(percent)%)",
                                       details: ["volumeId": volume.id]))
                Notifier.post(id: "low-\(volume.id)", title: "\(volume.displayName) is low on space",
                              body: "\(bytes(volume.availableBytes)) available (\(percent)%). Open MacVault to see what takes space.")
            case .rearm:
                warned.remove(volume.id)
            case .none:
                break
            }
        }
        settings.lowStorageWarnedVolumes = Array(warned).sorted()
    }

    // MARK: Export

    func exportActivity(format: ActivityExporter.Format, redaction: ActivityExporter.Redaction, to url: URL) async -> String? {
        guard let store else { return "The activity log is unavailable." }
        do {
            let events = try await store.auditEvents(limit: 100_000)
            let data = try ActivityExporter.export(events, format: format, redaction: redaction)
            try data.write(to: url, options: .atomic)
            await audit(AuditEvent(operationId: nil, eventType: "activity.exported", severity: .info,
                                   message: "Activity exported: \(events.count) event(s) as \(format.rawValue.uppercased())",
                                   details: ["redaction": redaction.rawValue]))
            return nil
        } catch {
            return "Export failed: \(error.localizedDescription)"
        }
    }
}
