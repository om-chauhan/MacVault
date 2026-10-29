import Foundation

public enum OperationStoreError: Error, Sendable, Equatable, LocalizedError {
    case manifestNotFound(String)
    case invalidTransition(id: String, from: ManifestStatus?, to: ManifestStatus)
    case emptyManifest

    public var errorDescription: String? {
        switch self {
        case .manifestNotFound: return "The reviewed list could not be found."
        case let .invalidTransition(_, from, to):
            return "The reviewed list is \(from?.displayName.lowercased() ?? "missing") and cannot become \(to.displayName.lowercased())."
        case .emptyManifest: return "Nothing was selected."
        }
    }
}

extension Store {
    // MARK: Manifests

    /// Saves a reviewed list as a draft. Nothing is approved or executed here.
    public func createManifest(_ manifest: OperationManifest) throws {
        guard !manifest.items.isEmpty else { throw OperationStoreError.emptyManifest }
        try db.transaction {
            try db.run("""
            INSERT INTO operation_manifests (id, operation_type, status, created_at, approved_at, completed_at, rule_version,
                estimated_bytes, measured_bytes_delta, recovery_supported, title, failure_reason)
            VALUES (?, ?, ?, ?, NULL, NULL, ?, ?, NULL, ?, ?, NULL)
            """, [.text(manifest.id), .text(manifest.type.rawValue), .text(ManifestStatus.draft.rawValue),
                  .date(manifest.createdAt), .string(manifest.ruleVersion), .int(manifest.estimatedBytes),
                  .bool(manifest.recoverySupported), .text(manifest.title)])
            let insert = try db.prepare("""
            INSERT INTO operation_items (id, manifest_id, original_path, resulting_path, resource_identifier,
                expected_size_bytes, action, status, error_domain, error_code, started_at, completed_at, rule_id,
                risk_level, reason, scope_root, content_hash, keeper_path, message, position)
            VALUES (?, ?, ?, NULL, ?, ?, ?, ?, NULL, NULL, NULL, NULL, ?, ?, ?, ?, ?, ?, NULL, ?)
            """)
            for (position, item) in manifest.items.enumerated() {
                try insert.bind([.text(item.id), .text(manifest.id), .text(item.originalPath), .string(item.resourceIdentifier),
                                 .int(item.expectedSizeBytes), .text(item.action.rawValue),
                                 .text(OperationItemStatus.pending.rawValue), .string(item.ruleId),
                                 .text(item.riskLevel.rawValue), .text(item.reason), .string(item.scopeRoot),
                                 .string(item.contentHash), .string(item.keeperPath), .integer(Int64(position))])
                _ = try insert.step()
            }
        }
    }

    /// draft → approved. Fails for any other current status, so a list can be approved only once.
    public func approveManifest(id: String, at date: Date = Date()) throws {
        try transition(id: id, from: .draft, to: .approved, set: "approved_at = ?", [.date(date)])
    }

    /// draft → discarded.
    public func discardManifest(id: String, at date: Date = Date()) throws {
        try transition(id: id, from: .draft, to: .discarded, set: "completed_at = ?", [.date(date)])
    }

    /// approved → executing. Atomic, so the same list cannot be executed twice.
    public func beginExecution(id: String) throws {
        try transition(id: id, from: .approved, to: .executing, set: nil, [])
    }

    /// executing → a terminal status.
    public func finishExecution(id: String, status: ManifestStatus, at date: Date = Date(), failureReason: String?) throws {
        precondition(status.isTerminal && status != .discarded, "finishExecution needs an execution outcome")
        try transition(id: id, from: .executing, to: status, set: "completed_at = ?, failure_reason = ?",
                       [.date(date), .string(failureReason)])
    }

    private func transition(id: String, from: ManifestStatus, to: ManifestStatus, set: String?, _ values: [SQLValue]) throws {
        let assignments = ["status = ?"] + (set.map { [$0] } ?? [])
        try db.run("UPDATE operation_manifests SET \(assignments.joined(separator: ", ")) WHERE id = ? AND status = ?",
                   [.text(to.rawValue)] + values + [.text(id), .text(from.rawValue)])
        if db.changes == 0 {
            let current = try db.query("SELECT status FROM operation_manifests WHERE id = ?", [.text(id)]) {
                $0.string(0).flatMap(ManifestStatus.init(rawValue:))
            }.first
            if current == nil { throw OperationStoreError.manifestNotFound(id) }
            throw OperationStoreError.invalidTransition(id: id, from: current ?? nil, to: to)
        }
    }

    /// Persists one item's outcome. Called after every item so a crash leaves an accurate record.
    public func updateOperationItem(_ item: OperationItem) throws {
        try db.run("""
        UPDATE operation_items SET status = ?, resulting_path = ?, error_domain = ?, error_code = ?, message = ?,
            started_at = ?, completed_at = ?
        WHERE id = ? AND manifest_id = ?
        """, [.text(item.status.rawValue), .string(item.resultingPath), .string(item.errorDomain), .int(item.errorCode),
              .string(item.message), .date(item.startedAt), .date(item.completedAt), .text(item.id), .text(item.manifestId)])
    }

    public func manifest(id: String) throws -> OperationManifest? {
        guard var manifest = try db.query("SELECT \(Self.manifestColumns) FROM operation_manifests WHERE id = ?",
                                          [.text(id)], map: Self.manifestRow).first else { return nil }
        manifest.items = try items(manifestId: id)
        return manifest
    }

    /// Newest first, with items.
    public func recentManifests(limit: Int = 50, types: Set<OperationType>? = nil) throws -> [OperationManifest] {
        var clause = ""
        var values: [SQLValue] = []
        if let types, !types.isEmpty {
            clause = "WHERE operation_type IN (\(types.map { _ in "?" }.joined(separator: ",")))"
            values = types.sorted { $0.rawValue < $1.rawValue }.map { .text($0.rawValue) }
        }
        values.append(.integer(Int64(limit)))
        var manifests = try db.query("""
        SELECT \(Self.manifestColumns) FROM operation_manifests \(clause) ORDER BY created_at DESC, rowid DESC LIMIT ?
        """, values, map: Self.manifestRow)
        for index in manifests.indices { manifests[index].items = try items(manifestId: manifests[index].id) }
        return manifests
    }

    /// Manifests left `executing` by a previous process become `interrupted`. Their items keep the
    /// last recorded status; pending items were never touched. Returns their IDs.
    public func reconcileInterruptedOperations(now: Date = Date()) throws -> [String] {
        try db.transaction {
            let ids = try db.query("SELECT id FROM operation_manifests WHERE status = 'executing'") { try $0.requiredString(0, "id") }
            for id in ids {
                try db.run("""
                UPDATE operation_manifests SET status = ?, completed_at = ?,
                    failure_reason = 'The app stopped while this list was being processed. Items not marked as moved were not touched.'
                WHERE id = ?
                """, [.text(ManifestStatus.interrupted.rawValue), .date(now), .text(id)])
            }
            return ids
        }
    }

    private static let manifestColumns = """
    id, operation_type, status, title, created_at, approved_at, completed_at, rule_version, estimated_bytes,
    measured_bytes_delta, recovery_supported, failure_reason
    """

    private static func manifestRow(_ row: Row) throws -> OperationManifest {
        guard let type = OperationType(rawValue: try row.requiredString(1, "operation_type")),
              let status = ManifestStatus(rawValue: try row.requiredString(2, "status")) else {
            throw DatabaseError.invalidValue(column: "operation_manifests")
        }
        return OperationManifest(id: try row.requiredString(0, "id"), type: type, status: status,
                                 title: row.string(3) ?? type.displayName, createdAt: try row.requiredDate(4, "created_at"),
                                 approvedAt: row.date(5), completedAt: row.date(6), ruleVersion: row.string(7),
                                 estimatedBytes: row.int64(8), measuredBytesDelta: row.int64(9),
                                 recoverySupported: row.bool(10) ?? false, failureReason: row.string(11), items: [])
    }

    private func items(manifestId: String) throws -> [OperationItem] {
        try db.query("""
        SELECT id, manifest_id, original_path, resulting_path, resource_identifier, expected_size_bytes, action, status,
               rule_id, risk_level, reason, scope_root, content_hash, keeper_path, error_domain, error_code, message,
               started_at, completed_at
        FROM operation_items WHERE manifest_id = ? ORDER BY position, rowid
        """, [.text(manifestId)]) { row in
            guard let action = OperationAction(rawValue: try row.requiredString(6, "action")),
                  let status = OperationItemStatus(rawValue: try row.requiredString(7, "status")) else {
                throw DatabaseError.invalidValue(column: "operation_items")
            }
            return OperationItem(id: try row.requiredString(0, "id"), manifestId: try row.requiredString(1, "manifest_id"),
                                 originalPath: try row.requiredString(2, "original_path"), resultingPath: row.string(3),
                                 resourceIdentifier: row.string(4), expectedSizeBytes: row.int64(5), action: action,
                                 status: status, ruleId: row.string(8),
                                 riskLevel: row.string(9).flatMap(RiskLevel.init(rawValue:)) ?? .notAssessed,
                                 reason: row.string(10) ?? "", scopeRoot: row.string(11), contentHash: row.string(12),
                                 keeperPath: row.string(13), errorDomain: row.string(14), errorCode: row.int(15),
                                 message: row.string(16), startedAt: row.date(17), completedAt: row.date(18))
        }
    }

    // MARK: Applications

    /// Replaces the inventory with what was just observed. Apps no longer present are removed;
    /// `discovered_at` is kept for apps seen before.
    public func replaceApplications(_ apps: [ApplicationRecord]) throws {
        try db.transaction {
            let upsert = try db.prepare("""
            INSERT INTO applications (id, bundle_id, display_name, version, bundle_path, bundle_size_bytes, discovered_at,
                last_seen_at, is_protected)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(bundle_path) DO UPDATE SET bundle_id = excluded.bundle_id, display_name = excluded.display_name,
                version = excluded.version, bundle_size_bytes = excluded.bundle_size_bytes,
                last_seen_at = excluded.last_seen_at, is_protected = excluded.is_protected
            """)
            for app in apps {
                try upsert.bind([.text(UUID().uuidString), .string(app.bundleId), .text(app.displayName), .string(app.version),
                                 .text(app.bundlePath), .int(app.bundleSizeBytes), .date(app.observedAt), .date(app.observedAt),
                                 .bool(app.isProtected)])
                _ = try upsert.step()
            }
            let keep = Set(apps.map(\.bundlePath))
            let existing = try db.query("SELECT bundle_path FROM applications") { try $0.requiredString(0, "bundle_path") }
            for path in existing where !keep.contains(path) {
                try db.run("DELETE FROM applications WHERE bundle_path = ?", [.text(path)])
            }
        }
    }

    public func applications() throws -> [ApplicationRecord] {
        try db.query("""
        SELECT bundle_path, bundle_id, display_name, version, bundle_size_bytes, is_protected, last_seen_at
        FROM applications ORDER BY bundle_size_bytes DESC, display_name
        """) { row in
            ApplicationRecord(bundlePath: try row.requiredString(0, "bundle_path"), bundleId: row.string(1),
                              displayName: try row.requiredString(2, "display_name"), version: row.string(3),
                              bundleSizeBytes: row.int64(4), sizeIsLowerBound: false, isProtected: row.bool(5) ?? false,
                              protectionReason: nil, resourceIdentifier: nil,
                              observedAt: try row.requiredDate(6, "last_seen_at"))
        }
    }
}
