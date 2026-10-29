import Foundation
import AppKit
import Observation
import MacVaultCore

/// Drives every change MacVault makes to files: reviewed list (draft) → approval sheet → execution.
/// Feature screens only build candidate lists; they never call the executor directly.
@MainActor
@Observable
final class OperationsModel {
    enum Phase: Equatable {
        case idle
        case executing(ExecutionProgress)
        case finished(OperationManifest)
        case failed(String)
    }

    /// A draft awaiting the user's decision in the approval sheet.
    struct PendingReview: Identifiable {
        var id: String { manifest.id }
        let manifest: OperationManifest
        /// Extra check run immediately before each item is moved (e.g. "is the app running?").
        let inUseCheck: @Sendable (OperationItem) -> String?
        let onFinished: @MainActor () async -> Void
    }

    private(set) var phase: Phase = .idle
    private(set) var history: [OperationManifest] = []
    var pendingReview: PendingReview?

    @ObservationIgnored private var store: () -> Store? = { nil }
    @ObservationIgnored private var audit: (AuditEvent) async -> Void = { _ in }
    private var task: Task<Void, Never>?

    /// Connects the model to the database and activity log once they are open.
    func attach(store: @escaping () -> Store?, audit: @escaping (AuditEvent) async -> Void) {
        self.store = store
        self.audit = audit
    }

    /// The App Store edition has read-only folder access, so it can review but never move items.
    static var canModifyFiles: Bool {
        #if APPSTORE
        return false
        #else
        return true
        #endif
    }

    static let readOnlyExplanation = "This edition can read only the folders you choose. Review the items here and reveal them in Finder; moving them to the Trash is available in the Direct edition."

    var isExecuting: Bool {
        if case .executing = phase { return true }
        return false
    }

    var policy: SafetyPolicy {
        let own = (try? Store.defaultURL())?.deletingLastPathComponent().path
        return SafetyPolicy(ownDataDirectory: own)
    }

    // MARK: Review

    func review(_ type: OperationType, title: String, candidates: [RemovalCandidate],
                inUseCheck: @escaping @Sendable (OperationItem) -> String? = { _ in nil },
                onFinished: @escaping @MainActor () async -> Void) async {
        await review(type, title: title, estimatedBytes: candidates.reduce(0) { $0 + ($1.logicalBytes ?? 0) },
                     items: { id in candidates.map { $0.operationItem(manifestId: id) } },
                     inUseCheck: inUseCheck, onFinished: onFinished)
    }

    func review(_ type: OperationType, title: String, estimatedBytes: Int64, items: (String) -> [OperationItem],
                inUseCheck: @escaping @Sendable (OperationItem) -> String? = { _ in nil },
                onFinished: @escaping @MainActor () async -> Void) async {
        guard Self.canModifyFiles, !isExecuting, let store = store() else { return }
        let id = UUID().uuidString
        let manifest = OperationManifest(id: id, type: type, title: title, ruleVersion: RuleCatalog.version,
                                         estimatedBytes: estimatedBytes, items: items(id))
        guard !manifest.items.isEmpty else { return }
        do {
            try await store.createManifest(manifest)
            await audit(AuditEvent(operationId: id, eventType: "operation.reviewed", severity: .info,
                                   message: "\(type.displayName) list prepared for approval: \(manifest.items.count) item(s), \(ByteFormat.string(estimatedBytes))",
                                   details: ["title": title]))
            if case .finished = phase { phase = .idle }
            if case .failed = phase { phase = .idle }
            pendingReview = PendingReview(manifest: manifest, inUseCheck: inUseCheck, onFinished: onFinished)
        } catch {
            phase = .failed("The list could not be prepared: \(error.localizedDescription)")
        }
    }

    func discardPending() async {
        guard let pending = pendingReview, let store = store() else { pendingReview = nil; return }
        pendingReview = nil
        try? await store.discardManifest(id: pending.manifest.id)
        await audit(AuditEvent(operationId: pending.manifest.id, eventType: "operation.discarded", severity: .info,
                               message: "\(pending.manifest.type.displayName) list discarded without changes"))
        await reloadHistory()
    }

    // MARK: Execution

    func approvePending() async {
        guard let pending = pendingReview, let store = store(), Self.canModifyFiles else { return }
        pendingReview = nil
        let id = pending.manifest.id
        do {
            try await store.approveManifest(id: id)
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        await audit(AuditEvent(operationId: id, eventType: "operation.approved", severity: .notice,
                               message: "Approved: move \(pending.manifest.items.count) item(s) to the Trash"))

        let executor = OperationExecutor(store: store, policy: policy, inUseCheck: pending.inUseCheck)
        phase = .executing(ExecutionProgress(processed: 0, total: pending.manifest.items.count, currentPath: ""))
        let report: @Sendable (ExecutionProgress) async -> Void = { [weak self] progress in
            await self?.setProgress(progress)
        }
        task = Task { [weak self] in
            let outcome: Phase
            do {
                // Runs off the main actor; every item is revalidated right before it is moved.
                let result = try await offMain { try await executor.execute(manifestId: id, progress: report) }
                outcome = .finished(result)
            } catch {
                outcome = .failed(error.localizedDescription)
            }
            guard let self else { return }
            self.phase = outcome
            await self.reloadHistory()
            await pending.onFinished()
        }
    }

    private func setProgress(_ progress: ExecutionProgress) {
        if case .executing = phase { phase = .executing(progress) }
    }

    /// Stops after the current item. Items not yet processed are left untouched.
    func cancel() {
        task?.cancel()
    }

    func dismissResult() {
        if case .executing = phase { return }
        phase = .idle
    }

    func reloadHistory() async {
        guard let store = store() else { return }
        history = (try? await store.recentManifests(limit: 50)) ?? []
    }

    func history(for types: Set<OperationType>) -> [OperationManifest] {
        history.filter { types.contains($0.type) && $0.status != .draft }
    }
}

/// Runs file work off the main actor. Unlike a bare `Task.detached`, cancelling the caller
/// cancels the work too.
func offMain<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
    let task = Task.detached(priority: .userInitiated, operation: work)
    return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
}

/// Live checks against running applications, used right before an item is moved.
enum RunningApps {
    static func runningName(bundlePath: String) -> String? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleURL.map { PathUtilities.canonicalize($0.path) } == bundlePath
        }?.localizedName
    }

    static func isRunning(bundleId: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty
    }
}
