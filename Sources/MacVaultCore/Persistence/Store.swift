import Foundation

/// The only component that touches SQLite. All access is serialized by the actor.
public actor Store {
    private let db: SQLiteConnection
    public nonisolated let path: String

    public init(path: String) throws {
        self.path = path
        if path != ":memory:" {
            let directory = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        db = try SQLiteConnection(path: path)
        try Migrations.migrate(db)
    }

    public static func inMemory() throws -> Store { try Store(path: ":memory:") }

    /// ~/Library/Application Support/MacVault/macvault.sqlite (inside the container when sandboxed).
    public static func defaultURL() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        return base.appendingPathComponent("MacVault", isDirectory: true)
            .appendingPathComponent("macvault.sqlite")
    }

    public func schemaVersion() throws -> Int { try Migrations.currentVersion(db) }

    public func foreignKeysEnabled() throws -> Bool {
        try db.query("PRAGMA foreign_keys") { $0.int(0) ?? 0 }.first == 1
    }

    // MARK: Volumes & snapshots

    public func upsertVolume(_ v: VolumeObservation) throws {
        try db.run("""
        INSERT INTO volumes (id, display_name, mount_path, total_bytes, available_bytes, capacity_bytes,
                             is_removable, is_read_only, last_observed_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            display_name = excluded.display_name,
            mount_path = excluded.mount_path,
            total_bytes = excluded.total_bytes,
            available_bytes = excluded.available_bytes,
            capacity_bytes = excluded.capacity_bytes,
            is_removable = excluded.is_removable,
            is_read_only = excluded.is_read_only,
            last_observed_at = excluded.last_observed_at
        """, [.text(v.id), .text(v.displayName), .string(v.mountPath), .int(v.totalBytes), .int(v.availableBytes),
              .int(v.totalBytes), .bool(v.isRemovable), .bool(v.isReadOnly), .date(v.observedAt)])
    }

    public func insertSnapshot(volume: VolumeObservation, scannedScopeBytes: Int64?, scanId: String?) throws {
        try upsertVolume(volume)
        try db.run("""
        INSERT INTO storage_snapshots (id, volume_id, observed_at, total_bytes, available_bytes, scanned_scope_bytes, scan_id)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """, [.text(UUID().uuidString), .text(volume.id), .date(volume.observedAt), .int(volume.totalBytes),
              .int(volume.availableBytes), .int(scannedScopeBytes), .string(scanId)])
    }

    /// Records a volume-only snapshot unless one was recorded for this volume within `minimumInterval`.
    /// Returns true when a snapshot was written.
    @discardableResult
    public func recordVolumeSnapshotIfDue(_ volume: VolumeObservation, minimumInterval: TimeInterval) throws -> Bool {
        let threshold = volume.observedAt.addingTimeInterval(-minimumInterval)
        let recent = try db.query("""
        SELECT COUNT(*) FROM storage_snapshots WHERE volume_id = ? AND observed_at > ?
        """, [.text(volume.id), .date(threshold)]) { $0.int(0) ?? 0 }.first ?? 0
        guard recent == 0 else {
            try upsertVolume(volume)
            return false
        }
        try insertSnapshot(volume: volume, scannedScopeBytes: nil, scanId: nil)
        return true
    }

    public func snapshots(volumeId: String, limit: Int = 500) throws -> [StorageSnapshot] {
        let newestFirst = try db.query("""
        SELECT id, volume_id, observed_at, total_bytes, available_bytes, scanned_scope_bytes, scan_id
        FROM storage_snapshots WHERE volume_id = ? ORDER BY observed_at DESC LIMIT ?
        """, [.text(volumeId), .integer(Int64(limit))]) { row in
            StorageSnapshot(id: try row.requiredString(0, "id"), volumeId: try row.requiredString(1, "volume_id"),
                            observedAt: try row.requiredDate(2, "observed_at"), totalBytes: row.int64(3),
                            availableBytes: row.int64(4), scannedScopeBytes: row.int64(5), scanId: row.string(6))
        }
        return Array(newestFirst.reversed())
    }

    // MARK: Scan sessions

    public func createScanSession(id: String, volumeId: String?, scopeDescription: String, rootPath: String,
                                  startedAt: Date) throws {
        try db.run("""
        INSERT INTO scan_sessions (id, volume_id, scope_description, root_path, status, started_at)
        VALUES (?, ?, ?, ?, ?, ?)
        """, [.text(id), .string(volumeId), .text(scopeDescription), .text(rootPath),
              .text(ScanStatus.running.rawValue), .date(startedAt)])
    }

    public func updateScanProgress(id: String, progress: ScanProgress) throws {
        try db.run("""
        UPDATE scan_sessions SET files_visited = ?, directories_visited = ?, bytes_observed = ?, inaccessible_items = ?
        WHERE id = ? AND status = 'running'
        """, [.integer(Int64(progress.filesVisited)), .integer(Int64(progress.directoriesVisited)),
              .integer(progress.logicalBytes), .integer(Int64(progress.inaccessibleItems)), .text(id)])
    }

    /// Persists the final scan state, findings, breakdown and issues atomically.
    public func finishScan(id: String, result: ScanResult) throws {
        let c = result.counters
        try db.transaction {
            try db.run("""
            UPDATE scan_sessions SET status = ?, completed_at = ?, files_visited = ?, directories_visited = ?,
                bytes_observed = ?, allocated_bytes_observed = ?, inaccessible_items = ?, error_count = ?,
                symlinks_skipped = ?, excluded_items = ?, mount_points_skipped = ?
            WHERE id = ?
            """, [.text(result.status.rawValue), .date(result.finishedAt), .integer(Int64(c.filesVisited)),
                  .integer(Int64(c.directoriesVisited)), .integer(c.logicalBytes), .integer(c.allocatedBytes),
                  .integer(Int64(c.inaccessibleItems)), .integer(Int64(c.otherErrors)),
                  .integer(Int64(c.symlinksSkipped)), .integer(Int64(c.excludedItems)),
                  .integer(Int64(c.mountPointsSkipped)), .text(id)])

            let finding = try db.prepare("""
            INSERT INTO file_findings (id, scan_id, path, resource_identifier, category, logical_size_bytes,
                allocated_size_bytes, modified_at, rule_id, risk_level, eligibility_status, observed_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
            for file in result.largeFiles {
                try finding.bind([.text(UUID().uuidString), .text(id), .text(file.path), .string(file.resourceIdentifier),
                                  .text(FindingCategory.largeFile.rawValue), .integer(file.logicalSizeBytes),
                                  .int(file.allocatedSizeBytes), .date(file.modifiedAt), .null,
                                  .text(RiskLevel.notAssessed.rawValue), .text(EligibilityStatus.reviewOnly.rawValue),
                                  .date(result.finishedAt)])
                _ = try finding.step()
            }

            let aggregate = try db.prepare("""
            INSERT INTO scan_directory_aggregates (scan_id, name, path, is_directory, logical_bytes, allocated_bytes,
                file_count, inaccessible_items) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """)
            for entry in result.topLevel {
                try aggregate.bind([.text(id), .text(entry.name), .text(entry.path), .bool(entry.isDirectory),
                                    .integer(entry.logicalBytes), .integer(entry.allocatedBytes),
                                    .integer(Int64(entry.fileCount)), .integer(Int64(entry.inaccessibleItems))])
                _ = try aggregate.step()
            }

            let issue = try db.prepare("INSERT INTO scan_issues (scan_id, path, kind, error_code) VALUES (?, ?, ?, ?)")
            for item in result.issues {
                try issue.bind([.text(id), .text(item.path), .text(item.kind.rawValue),
                                item.errorCode.map { .integer(Int64($0)) } ?? .null])
                _ = try issue.step()
            }
        }
    }

    public func failScan(id: String, reason: String, at date: Date) throws {
        try db.run("UPDATE scan_sessions SET status = ?, completed_at = ?, failure_reason = ? WHERE id = ?",
                   [.text(ScanStatus.failed.rawValue), .date(date), .text(reason), .text(id)])
    }

    /// Marks sessions left `running` by a previous process as `interrupted`. Returns their IDs.
    public func reconcileInterruptedScans(now: Date = Date()) throws -> [String] {
        try db.transaction {
            let ids = try db.query("SELECT id FROM scan_sessions WHERE status = 'running'") { try $0.requiredString(0, "id") }
            for id in ids {
                try db.run("""
                UPDATE scan_sessions SET status = ?, completed_at = ?,
                    failure_reason = 'The app stopped before this scan finished. Counts reflect the last saved progress.'
                WHERE id = ?
                """, [.text(ScanStatus.interrupted.rawValue), .date(now), .text(id)])
            }
            return ids
        }
    }

    private static let sessionColumns = """
    id, volume_id, scope_description, root_path, status, started_at, completed_at, files_visited,
    directories_visited, bytes_observed, allocated_bytes_observed, inaccessible_items, error_count,
    symlinks_skipped, excluded_items, mount_points_skipped, failure_reason
    """

    private static func session(_ row: Row) throws -> ScanSessionRecord {
        guard let status = ScanStatus(rawValue: try row.requiredString(4, "status")) else {
            throw DatabaseError.invalidValue(column: "scan_sessions.status")
        }
        return ScanSessionRecord(
            id: try row.requiredString(0, "id"), volumeId: row.string(1),
            scopeDescription: try row.requiredString(2, "scope_description"), rootPath: row.string(3),
            status: status, startedAt: try row.requiredDate(5, "started_at"), completedAt: row.date(6),
            filesVisited: row.int(7) ?? 0, directoriesVisited: row.int(8) ?? 0, bytesObserved: row.int64(9) ?? 0,
            allocatedBytesObserved: row.int64(10), inaccessibleItems: row.int(11) ?? 0, errorCount: row.int(12) ?? 0,
            symlinksSkipped: row.int(13) ?? 0, excludedItems: row.int(14) ?? 0, mountPointsSkipped: row.int(15) ?? 0,
            failureReason: row.string(16))
    }

    public func scanSession(id: String) throws -> ScanSessionRecord? {
        try db.query("SELECT \(Self.sessionColumns) FROM scan_sessions WHERE id = ?", [.text(id)], map: Self.session).first
    }

    public func recentScans(limit: Int = 20) throws -> [ScanSessionRecord] {
        try db.query("SELECT \(Self.sessionColumns) FROM scan_sessions ORDER BY started_at DESC, rowid DESC LIMIT ?",
                     [.integer(Int64(limit))], map: Self.session)
    }

    public func findings(scanId: String) throws -> [FileFinding] {
        try db.query("""
        SELECT id, scan_id, path, resource_identifier, category, logical_size_bytes, allocated_size_bytes,
               modified_at, rule_id, risk_level, eligibility_status, observed_at
        FROM file_findings WHERE scan_id = ? ORDER BY logical_size_bytes DESC
        """, [.text(scanId)]) { row in
            guard let category = FindingCategory(rawValue: try row.requiredString(4, "category")),
                  let risk = RiskLevel(rawValue: try row.requiredString(9, "risk_level")),
                  let eligibility = EligibilityStatus(rawValue: try row.requiredString(10, "eligibility_status")) else {
                throw DatabaseError.invalidValue(column: "file_findings")
            }
            return FileFinding(id: try row.requiredString(0, "id"), scanId: try row.requiredString(1, "scan_id"),
                               path: try row.requiredString(2, "path"), resourceIdentifier: row.string(3),
                               category: category, logicalSizeBytes: row.int64(5), allocatedSizeBytes: row.int64(6),
                               modifiedAt: row.date(7), ruleId: row.string(8), riskLevel: risk,
                               eligibility: eligibility, observedAt: try row.requiredDate(11, "observed_at"))
        }
    }

    public func aggregates(scanId: String) throws -> [DirectoryAggregate] {
        try db.query("""
        SELECT name, path, is_directory, logical_bytes, allocated_bytes, file_count, inaccessible_items
        FROM scan_directory_aggregates WHERE scan_id = ? ORDER BY logical_bytes DESC
        """, [.text(scanId)]) { row in
            DirectoryAggregate(name: try row.requiredString(0, "name"), path: try row.requiredString(1, "path"),
                               isDirectory: row.bool(2) ?? false, logicalBytes: row.int64(3) ?? 0,
                               allocatedBytes: row.int64(4) ?? 0, fileCount: row.int(5) ?? 0,
                               inaccessibleItems: row.int(6) ?? 0)
        }
    }

    public func issues(scanId: String) throws -> [ScanIssue] {
        try db.query("SELECT path, kind, error_code FROM scan_issues WHERE scan_id = ? ORDER BY id",
                     [.text(scanId)]) { row in
            guard let kind = ScanIssueKind(rawValue: try row.requiredString(1, "kind")) else {
                throw DatabaseError.invalidValue(column: "scan_issues.kind")
            }
            return ScanIssue(path: try row.requiredString(0, "path"), kind: kind, errorCode: row.int64(2).map(Int32.init))
        }
    }

    // MARK: Retention

    /// Deletes all but the newest `keepLatest` finished scans (running scans are never pruned).
    /// Snapshots keep their volume data; their scan reference is cleared. Returns the number removed.
    @discardableResult
    public func pruneScans(keepLatest: Int) throws -> Int {
        try db.transaction {
            let ids = try db.query("""
            SELECT id FROM scan_sessions WHERE status != 'running'
            ORDER BY started_at DESC, rowid DESC LIMIT -1 OFFSET ?
            """, [.integer(Int64(max(0, keepLatest)))]) { try $0.requiredString(0, "id") }
            for id in ids { try deleteScanRows(id) }
            return ids.count
        }
    }

    private func deleteScanRows(_ id: String) throws {
        try db.run("DELETE FROM file_findings WHERE scan_id = ?", [.text(id)])
        try db.run("DELETE FROM scan_directory_aggregates WHERE scan_id = ?", [.text(id)])
        try db.run("DELETE FROM scan_issues WHERE scan_id = ?", [.text(id)])
        try db.run("UPDATE storage_snapshots SET scan_id = NULL, scanned_scope_bytes = NULL WHERE scan_id = ?", [.text(id)])
        try db.run("DELETE FROM scan_sessions WHERE id = ?", [.text(id)])
    }

    /// Removes scan history, findings and snapshots. The audit trail is kept and records the reset.
    public func deleteScanHistory() throws {
        try db.transaction {
            try db.execute("""
            DELETE FROM file_findings;
            DELETE FROM scan_directory_aggregates;
            DELETE FROM scan_issues;
            DELETE FROM storage_snapshots;
            DELETE FROM scan_sessions;
            """)
        }
    }

    // MARK: Audit

    public func appendAudit(_ event: AuditEvent) throws {
        try db.run("""
        INSERT INTO audit_events (id, operation_id, event_type, severity, message, details_json, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """, [.text(event.id), .string(event.operationId), .text(event.eventType), .text(event.severity.rawValue),
              .text(event.message), .string(event.detailsJSON), .date(event.createdAt)])
    }

    public func auditEvents(limit: Int = 500, search: String? = nil, minimumSeverity: AuditSeverity? = nil) throws -> [AuditEvent] {
        var clauses: [String] = []
        var values: [SQLValue] = []
        if let search, !search.trimmingCharacters(in: .whitespaces).isEmpty {
            clauses.append("(message LIKE ? ESCAPE '\\' OR event_type LIKE ? ESCAPE '\\' OR operation_id LIKE ? ESCAPE '\\')")
            let escaped = search.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
            let pattern = "%\(escaped)%"
            values += [.text(pattern), .text(pattern), .text(pattern)]
        }
        if let minimumSeverity {
            let all = AuditSeverity.allCases
            let allowed = all[all.firstIndex(of: minimumSeverity)!...]
            clauses.append("severity IN (\(allowed.map { _ in "?" }.joined(separator: ",")))")
            values += allowed.map { .text($0.rawValue) }
        }
        let whereClause = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        values.append(.integer(Int64(limit)))
        return try db.query("""
        SELECT id, operation_id, event_type, severity, message, details_json, created_at
        FROM audit_events \(whereClause) ORDER BY created_at DESC, rowid DESC LIMIT ?
        """, values) { row in
            guard let severity = AuditSeverity(rawValue: try row.requiredString(3, "severity")) else {
                throw DatabaseError.invalidValue(column: "audit_events.severity")
            }
            return AuditEvent(id: try row.requiredString(0, "id"), operationId: row.string(1),
                              eventType: try row.requiredString(2, "event_type"), severity: severity,
                              message: try row.requiredString(4, "message"), detailsJSON: row.string(5),
                              createdAt: try row.requiredDate(6, "created_at"))
        }
    }
}
