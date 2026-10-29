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

    /// Not implemented in this milestone; shown as "Planned" with no functional controls.
    var isPlanned: Bool {
        switch self {
        case .cleaner, .applications, .duplicates, .developer: return true
        default: return false
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
    private(set) var reconciledOnLaunch = 0
    private var scanTask: Task<Void, Never>?

    var selectedLocationID: UUID?
    private(set) var displayedScan: ScanSessionRecord?
    private(set) var displayedFindings: [FileFinding] = []
    private(set) var displayedAggregates: [DirectoryAggregate] = []
    private(set) var displayedIssues: [ScanIssue] = []

    // Activity
    private(set) var recentEvents: [AuditEvent] = []

    var isScanning: Bool {
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
            let url = try Store.defaultURL()
            let store = try Store(path: url.path)
            self.store = store
            reconciledOnLaunch = try await LaunchReconciler.run(store: store)
        } catch {
            startupError = "MacVault could not open its local database. Scan history and the activity log are unavailable. (\(error.localizedDescription))"
            Log.app.error("Store open failed")
        }
        selectedLocationID = access.locations.first?.id
        await refreshVolumes()
        await reloadScans()
        await reloadActivity()
        if let latest = latestScan(for: selectedLocation) { await show(scanID: latest.id) }
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

    func removeLocation(_ location: AuthorizedLocation) async {
        access.remove(location)
        await audit(AuditEvent(operationId: nil, eventType: "access.removed", severity: .info,
                               message: "Folder access removed: \(location.displayPath)"))
        if selectedLocationID == location.id { await selectLocation(access.locations.first?.id) }
    }

    func startScan() {
        guard !isScanning, let store, let location = selectedLocation else { return }
        lastWarnings = []

        let scoped: ScopedAccess
        switch access.beginAccess(location) {
        case .failure(let status):
            scanPhase = .failed(status == .needsReselection
                ? "Access to \(location.displayPath) has expired. Choose the folder again to continue."
                : "\(location.displayPath) is not available. It may have been moved, renamed or its volume ejected.")
            return
        case .success(let value):
            scoped = value
        }

        var config = ScanConfiguration(
            rootPath: location.path,
            exclusions: settings.exclusions,
            largeFileThresholdBytes: settings.largeFileThresholdBytes
        )
        config.crossMountPoints = settings.crossMountPoints

        let service = ScanService(store: store)
        let locationID = location.id
        let scope = location.displayPath
        let keep = settings.keepScans
        scanPhase = .running(locationID: locationID, progress: ScanProgress())

        scanTask = Task { [weak self] in
            defer { scoped.stop() }
            do {
                let outcome = try await service.runScan(configuration: config, scopeDescription: scope) { progress in
                    await MainActor.run { [weak self] in
                        guard let self, case .running = self.scanPhase else { return }
                        self.scanPhase = .running(locationID: locationID, progress: progress)
                    }
                }
                _ = try? await store.pruneScans(keepLatest: keep)
                guard let self else { return }
                self.lastWarnings = outcome.warnings
                self.scanPhase = outcome.failureMessage.map(ScanPhase.failed) ?? .idle
                await self.reloadScans()
                await self.show(scanID: outcome.scanId)
                await self.reloadActivity()
                await self.refreshVolumes()
            } catch {
                guard let self else { return }
                self.scanPhase = .failed("The scan could not be recorded: \(error.localizedDescription)")
                await self.reloadActivity()
            }
        }
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
}
