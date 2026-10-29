import Foundation
import Observation
import MacVaultCore

/// Evaluates a set of cleanup rules (Cleaner and Developer Tools global caches). Read-only.
@MainActor
@Observable
final class RuleScanModel {
    let rules: [CleanupRule]
    let operationType: OperationType

    private(set) var findings: [RuleFindings] = []
    private(set) var isScanning = false
    private(set) var currentRule: String?
    private(set) var error: String?
    private(set) var lastScanned: Date?
    var selection: Set<String> = []
    private var task: Task<Void, Never>?

    init(rules: [CleanupRule], operationType: OperationType) {
        self.rules = rules
        self.operationType = operationType
    }

    var allCandidates: [RemovalCandidate] { findings.flatMap(\.candidates) }
    var selectedCandidates: [RemovalCandidate] { allCandidates.filter { selection.contains($0.id) } }
    var selectedBytes: Int64 { selectedCandidates.reduce(0) { $0 + ($1.logicalBytes ?? 0) } }

    func scan(policy: SafetyPolicy) {
        guard !isScanning else { return }
        isScanning = true
        error = nil
        let rules = self.rules
        let finder = CleanupCandidateFinder(home: policy.home, policy: policy)
        let report: @Sendable (CleanupRule) async -> Void = { [weak self] rule in
            await self?.setCurrent(rule.title)
        }
        task = Task { [weak self] in
            do {
                let results = try await offMain { try await finder.evaluate(rules, progress: report) }
                guard let self else { return }
                self.findings = results
                self.selection = Set(results.flatMap(\.candidates).filter(\.selectedByDefault).map(\.id))
                self.lastScanned = Date()
            } catch is CancellationError {
                // Keep the previous results; nothing was changed.
            } catch {
                self?.error = error.localizedDescription
            }
            self?.isScanning = false
            self?.currentRule = nil
        }
    }

    private func setCurrent(_ title: String) { currentRule = title }

    func cancel() { task?.cancel() }

    /// Drops candidates that were just processed so the list reflects what is left.
    func removeProcessed(_ manifest: OperationManifest) {
        let gone = Set(manifest.items.filter { $0.status == .trashed }.map(\.originalPath))
        findings = findings.map { f in
            RuleFindings(rule: f.rule, candidates: f.candidates.filter { !gone.contains($0.path) },
                         locationMissing: f.locationMissing, locationError: f.locationError,
                         protectedCount: f.protectedCount, tooRecentCount: f.tooRecentCount)
        }
        selection.subtract(gone)
    }
}

/// Per-project build artifacts inside a folder the user authorized.
@MainActor
@Observable
final class ProjectArtifactsModel {
    var locationID: UUID?
    private(set) var candidates: [RemovalCandidate] = []
    private(set) var isScanning = false
    private(set) var error: String?
    private(set) var scannedPath: String?
    var selection: Set<String> = []
    private var task: Task<Void, Never>?

    var selectedCandidates: [RemovalCandidate] { candidates.filter { selection.contains($0.id) } }
    var selectedBytes: Int64 { selectedCandidates.reduce(0) { $0 + ($1.logicalBytes ?? 0) } }

    func scan(location: AuthorizedLocation, access: AccessCoordinator, policy: SafetyPolicy) {
        guard !isScanning else { return }
        let scoped: ScopedAccess
        switch access.beginAccess(location) {
        case .failure:
            error = "\(location.displayPath) is not available. Choose the folder again in Settings."
            return
        case .success(let value):
            scoped = value
        }
        isScanning = true
        error = nil
        let finder = ProjectArtifactFinder(policy: policy)
        let root = location.path
        task = Task { [weak self] in
            defer { scoped.stop() }
            do {
                let found = try await offMain { try await finder.find(in: root) }
                guard let self else { return }
                self.candidates = found
                self.selection = Set(found.filter(\.selectedByDefault).map(\.id))
                self.scannedPath = root
            } catch is CancellationError {
            } catch {
                self?.error = error.localizedDescription
            }
            self?.isScanning = false
        }
    }

    func cancel() { task?.cancel() }

    func removeProcessed(_ manifest: OperationManifest) {
        let gone = Set(manifest.items.filter { $0.status == .trashed }.map(\.originalPath))
        candidates.removeAll { gone.contains($0.path) }
        selection.subtract(gone)
    }
}

/// Installed applications and, for the selected app, its probable data in ~/Library.
@MainActor
@Observable
final class ApplicationsModel {
    private(set) var apps: [ApplicationRecord] = []
    private(set) var isScanning = false
    private(set) var progress: (done: Int, total: Int) = (0, 0)
    private(set) var error: String?
    private(set) var lastScanned: Date?
    var selectedAppID: ApplicationRecord.ID?
    private(set) var associated: [AssociatedItem] = []
    private(set) var isLoadingAssociated = false
    var leftoverSelection: Set<String> = []
    private var task: Task<Void, Never>?

    var selectedApp: ApplicationRecord? { apps.first { $0.id == selectedAppID } }

    func inventory(policy: SafetyPolicy) -> ApplicationInventory {
        ApplicationInventory(policy: policy, ownBundleId: Bundle.main.bundleIdentifier)
    }

    func scan(policy: SafetyPolicy, store: Store?) {
        guard !isScanning else { return }
        isScanning = true
        error = nil
        let inventory = inventory(policy: policy)
        let report: @Sendable (Int, Int) async -> Void = { [weak self] done, total in
            await self?.setProgress(done, total)
        }
        task = Task { [weak self] in
            do {
                let found = try await offMain { try await inventory.scan(progress: report) }
                try? await store?.replaceApplications(found)
                guard let self else { return }
                self.apps = found
                self.lastScanned = Date()
                if let id = self.selectedAppID, !found.contains(where: { $0.id == id }) { self.selectedAppID = nil }
                await self.loadAssociated(policy: policy)
            } catch is CancellationError {
            } catch {
                self?.error = error.localizedDescription
            }
            self?.isScanning = false
        }
    }

    private func setProgress(_ done: Int, _ total: Int) { progress = (done, total) }

    func cancel() { task?.cancel() }

    @ObservationIgnored private var loadToken = UUID()

    func loadAssociated(policy: SafetyPolicy) async {
        let token = UUID()
        loadToken = token
        associated = []
        leftoverSelection = []
        guard let app = selectedApp else { isLoadingAssociated = false; return }
        isLoadingAssociated = true
        // Only the latest request may clear the flag; earlier ones finish silently.
        defer { if loadToken == token { isLoadingAssociated = false } }
        let inventory = inventory(policy: policy)
        let items = (try? await offMain { inventory.associatedItems(for: app) }) ?? []
        guard loadToken == token, selectedApp == app else { return }
        associated = items
        leftoverSelection = Set(items.filter(\.candidate.selectedByDefault).map(\.id))
    }

    /// Bundles moved to the Trash this session. They stay selectable so their leftovers can still be reviewed.
    private(set) var removedBundles: Set<String> = []

    func isRemoved(_ app: ApplicationRecord) -> Bool { removedBundles.contains(app.bundlePath) }

    func removeProcessed(_ manifest: OperationManifest) {
        let gone = Set(manifest.items.filter { $0.status == .trashed }.map(\.originalPath))
        removedBundles.formUnion(gone.filter { path in apps.contains { $0.bundlePath == path } })
        associated.removeAll { gone.contains($0.candidate.path) }
        leftoverSelection.subtract(gone)
    }
}

/// Files with identical content inside a folder the user authorized.
@MainActor
@Observable
final class DuplicatesModel {
    var locationID: UUID?
    var minimumSizeMB = 1
    private(set) var result: DuplicateScanResult?
    private(set) var isScanning = false
    private(set) var progress: DuplicateProgress?
    private(set) var error: String?
    /// Content hash → path of the copy to keep.
    var keepers: [String: String] = [:]
    /// Paths selected for removal.
    var selection: Set<String> = []
    private var task: Task<Void, Never>?

    var groups: [DuplicateGroup] { result?.groups ?? [] }

    var selectedBytes: Int64 {
        groups.reduce(0) { sum, group in
            sum + group.sizeBytes * Int64(group.files.filter { selection.contains($0.path) && $0.path != keeper(for: group) }.count)
        }
    }

    var selectedCount: Int {
        groups.reduce(0) { sum, group in
            sum + group.files.filter { selection.contains($0.path) && $0.path != keeper(for: group) }.count
        }
    }

    func keeper(for group: DuplicateGroup) -> String { keepers[group.contentHash] ?? group.suggestedKeeper.path }

    /// Swaps roles: the previous keeper takes the new keeper's place in the selection, so a copy the
    /// user chose to keep (unselected) never becomes selected by changing the keeper.
    func setKeeper(_ path: String, for group: DuplicateGroup) {
        let old = keeper(for: group)
        guard old != path else { return }
        let newWasSelected = selection.contains(path)
        keepers[group.contentHash] = path
        selection.remove(path)
        if newWasSelected { selection.insert(old) }
    }

    func scan(location: AuthorizedLocation, access: AccessCoordinator, policy: SafetyPolicy, exclusions: [String]) {
        guard !isScanning else { return }
        let scoped: ScopedAccess
        switch access.beginAccess(location) {
        case .failure:
            error = "\(location.displayPath) is not available. Choose the folder again in Settings."
            return
        case .success(let value):
            scoped = value
        }
        isScanning = true
        error = nil
        progress = nil
        let finder = DuplicateFinder(policy: policy)
        let root = location.path
        let minimum = Int64(max(1, minimumSizeMB)) * 1_000_000
        let report: @Sendable (DuplicateProgress) async -> Void = { [weak self] p in await self?.setProgress(p) }
        task = Task { [weak self] in
            defer { scoped.stop() }
            do {
                let found = try await offMain {
                    try await finder.find(in: root, minimumSize: minimum, exclusions: exclusions, progress: report)
                }
                guard let self else { return }
                self.result = found
                self.keepers = Dictionary(uniqueKeysWithValues: found.groups.map { ($0.contentHash, $0.suggestedKeeper.path) })
                self.selection = Set(found.groups.flatMap { g in g.files.map(\.path).filter { $0 != g.suggestedKeeper.path } })
            } catch is CancellationError {
            } catch {
                self?.error = error.localizedDescription
            }
            self?.isScanning = false
            self?.progress = nil
        }
    }

    private func setProgress(_ p: DuplicateProgress) { progress = p }

    func cancel() { task?.cancel() }

    /// Removal items for the current selection; the keeper of each group is never included.
    func removalItems(manifestId: String) -> [OperationItem] {
        guard let result else { return [] }
        return groups.flatMap { group -> [OperationItem] in
            let keep = keeper(for: group)
            return group.removalItems(keeping: keep, manifestId: manifestId, scopeRoot: result.rootPath)
                .filter { selection.contains($0.originalPath) }
        }
    }

    func removeProcessed(_ manifest: OperationManifest) {
        guard let result else { return }
        let gone = Set(manifest.items.filter { $0.status == .trashed }.map(\.originalPath))
        let remaining = result.groups.compactMap { group -> DuplicateGroup? in
            let files = group.files.filter { !gone.contains($0.path) }
            return files.count > 1 ? DuplicateGroup(contentHash: group.contentHash, sizeBytes: group.sizeBytes, files: files) : nil
        }
        self.result = DuplicateScanResult(rootPath: result.rootPath, groups: remaining, filesConsidered: result.filesConsidered,
                                          bytesHashed: result.bytesHashed, inaccessibleItems: result.inaccessibleItems,
                                          hardLinksIgnored: result.hardLinksIgnored)
        selection.subtract(gone)
    }
}
