import Foundation

public struct ScanRunOutcome: Sendable {
    public let scanId: String
    public let result: ScanResult?
    /// Set when the scan could not run (e.g. the root is unreadable).
    public let failureMessage: String?
    /// Non-fatal problems, e.g. an audit or snapshot write that failed. Always shown to the user.
    public let warnings: [String]
}

/// Use case: run a read-only scan and record it.
///
/// Flow: observe volume → create running session → audit start → scan (progress persisted, awaited)
/// → persist findings atomically → record volume snapshot → audit outcome.
public final class ScanService: Sendable {
    private let store: Store
    private let scanner: FilesystemScanner
    private let volumes: VolumeInfoService

    public init(store: Store, scanner: FilesystemScanner = FilesystemScanner(), volumes: VolumeInfoService = VolumeInfoService()) {
        self.store = store
        self.scanner = scanner
        self.volumes = volumes
    }

    public func runScan(
        configuration: ScanConfiguration,
        scopeDescription: String,
        onProgress: @escaping @Sendable (ScanProgress) async -> Void = { _ in }
    ) async throws -> ScanRunOutcome {
        let scanId = UUID().uuidString
        var warnings: [String] = []
        let root = configuration.rootPath

        let volume = try? volumes.observeVolume(containing: root)
        if let volume {
            do { try await store.upsertVolume(volume) } catch { warnings.append("Volume details were not saved: \(error.localizedDescription)") }
        }

        // The session must exist before any work starts so an interruption is detectable on next launch.
        try await store.createScanSession(id: scanId, volumeId: volume?.id, scopeDescription: scopeDescription,
                                          rootPath: root, startedAt: Date())
        await audit(AuditEvent(operationId: scanId, eventType: "scan.started", severity: .info,
                               message: "Scan started: \(scopeDescription)",
                               details: ["exclusions": "\(configuration.exclusions.count)",
                                         "largeFileThresholdBytes": "\(configuration.largeFileThresholdBytes)"]),
                    warnings: &warnings)

        let store = self.store
        let result: ScanResult
        do {
            result = try await scanner.scan(configuration) { progress in
                try? await store.updateScanProgress(id: scanId, progress: progress)
                await onProgress(progress)
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            try? await store.failScan(id: scanId, reason: message, at: Date())
            await audit(AuditEvent(operationId: scanId, eventType: "scan.failed", severity: .error,
                                   message: "Scan failed: \(message)"), warnings: &warnings)
            return ScanRunOutcome(scanId: scanId, result: nil, failureMessage: message, warnings: warnings)
        }

        do {
            try await store.finishScan(id: scanId, result: result)
        } catch {
            // The session stays "running" in the DB and will be reconciled as interrupted; report it now.
            warnings.append("Scan results could not be saved: \(error.localizedDescription)")
        }

        // Volume capacity observed after the scan; scope bytes only for scans that reached the end.
        if let after = try? volumes.observeVolume(containing: root) {
            let scopeBytes: Int64? = (result.status == .completed || result.status == .partial) ? result.counters.logicalBytes : nil
            do { try await store.insertSnapshot(volume: after, scannedScopeBytes: scopeBytes, scanId: scanId) }
            catch { warnings.append("Storage snapshot was not saved: \(error.localizedDescription)") }
        }

        let c = result.counters
        let details: [String: String] = [
            "filesVisited": "\(c.filesVisited)",
            "directoriesVisited": "\(c.directoriesVisited)",
            "logicalBytes": "\(c.logicalBytes)",
            "inaccessibleItems": "\(c.inaccessibleItems)",
            "symlinksSkipped": "\(c.symlinksSkipped)",
            "excludedItems": "\(c.excludedItems)",
            "mountPointsSkipped": "\(c.mountPointsSkipped)",
            "largeFileFindings": "\(result.largeFiles.count)",
        ]
        let event: AuditEvent
        switch result.status {
        case .completed:
            event = AuditEvent(operationId: scanId, eventType: "scan.completed", severity: .info,
                               message: "Scan completed: \(c.filesVisited) files, \(ByteFormat.string(c.logicalBytes)) observed",
                               details: details)
        case .partial:
            event = AuditEvent(operationId: scanId, eventType: "scan.partial", severity: .warning,
                               message: "Scan incomplete: \(c.inaccessibleItems + c.otherErrors) items could not be read",
                               details: details)
        case .cancelled:
            event = AuditEvent(operationId: scanId, eventType: "scan.cancelled", severity: .notice,
                               message: "Scan cancelled after \(c.filesVisited) files", details: details)
        default:
            event = AuditEvent(operationId: scanId, eventType: "scan.\(result.status.rawValue)", severity: .warning,
                               message: "Scan ended with status \(result.status.rawValue)", details: details)
        }
        await audit(event, warnings: &warnings)

        return ScanRunOutcome(scanId: scanId, result: result, failureMessage: nil, warnings: warnings)
    }

    /// Audit failures are never swallowed: they become user-visible warnings.
    private func audit(_ event: AuditEvent, warnings: inout [String]) async {
        do { try await store.appendAudit(event) }
        catch { warnings.append("Activity log entry could not be written: \(error.localizedDescription)") }
    }
}

/// Startup reconciliation: scans left `running` by a previous process become `interrupted`.
public enum LaunchReconciler {
    @discardableResult
    public static func run(store: Store) async throws -> Int {
        let ids = try await store.reconcileInterruptedScans()
        for id in ids {
            try await store.appendAudit(AuditEvent(
                operationId: id, eventType: "scan.reconciled", severity: .warning,
                message: "A scan was interrupted before it finished and has been marked Interrupted"))
        }
        return ids.count
    }
}
