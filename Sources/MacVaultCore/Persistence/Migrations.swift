import Foundation

public struct Migration: Sendable {
    public let version: Int
    public let name: String
    public let sql: String

    public init(version: Int, name: String, sql: String) {
        self.version = version
        self.name = name
        self.sql = sql
    }
}

public enum Migrations {
    /// v1 is the initial schema, unchanged.
    public static let v1 = Migration(version: 1, name: "initial_schema", sql: """
    CREATE TABLE volumes (
        id TEXT PRIMARY KEY,
        display_name TEXT NOT NULL,
        mount_path TEXT,
        total_bytes INTEGER,
        available_bytes INTEGER,
        capacity_bytes INTEGER,
        is_removable INTEGER,
        is_read_only INTEGER,
        last_observed_at TEXT NOT NULL
    );

    CREATE TABLE scan_sessions (
        id TEXT PRIMARY KEY,
        volume_id TEXT REFERENCES volumes(id),
        scope_description TEXT NOT NULL,
        status TEXT NOT NULL,
        started_at TEXT NOT NULL,
        completed_at TEXT,
        files_visited INTEGER NOT NULL DEFAULT 0,
        directories_visited INTEGER NOT NULL DEFAULT 0,
        bytes_observed INTEGER NOT NULL DEFAULT 0,
        inaccessible_items INTEGER NOT NULL DEFAULT 0,
        error_count INTEGER NOT NULL DEFAULT 0
    );

    CREATE TABLE file_findings (
        id TEXT PRIMARY KEY,
        scan_id TEXT NOT NULL REFERENCES scan_sessions(id),
        path TEXT NOT NULL,
        resource_identifier TEXT,
        category TEXT NOT NULL,
        logical_size_bytes INTEGER,
        allocated_size_bytes INTEGER,
        modified_at TEXT,
        rule_id TEXT,
        risk_level TEXT NOT NULL,
        eligibility_status TEXT NOT NULL,
        observed_at TEXT NOT NULL
    );

    CREATE INDEX idx_findings_scan ON file_findings(scan_id);
    CREATE INDEX idx_findings_category_size ON file_findings(category, logical_size_bytes);

    CREATE TABLE applications (
        id TEXT PRIMARY KEY,
        bundle_id TEXT,
        display_name TEXT NOT NULL,
        version TEXT,
        bundle_path TEXT NOT NULL,
        bundle_size_bytes INTEGER,
        discovered_at TEXT NOT NULL,
        last_seen_at TEXT NOT NULL
    );

    CREATE TABLE operation_manifests (
        id TEXT PRIMARY KEY,
        operation_type TEXT NOT NULL,
        status TEXT NOT NULL,
        created_at TEXT NOT NULL,
        approved_at TEXT,
        completed_at TEXT,
        rule_version TEXT,
        estimated_bytes INTEGER,
        measured_bytes_delta INTEGER,
        recovery_supported INTEGER NOT NULL DEFAULT 0
    );

    CREATE TABLE operation_items (
        id TEXT PRIMARY KEY,
        manifest_id TEXT NOT NULL REFERENCES operation_manifests(id),
        original_path TEXT NOT NULL,
        resulting_path TEXT,
        resource_identifier TEXT,
        expected_size_bytes INTEGER,
        action TEXT NOT NULL,
        status TEXT NOT NULL,
        error_domain TEXT,
        error_code INTEGER,
        started_at TEXT,
        completed_at TEXT
    );

    CREATE TABLE audit_events (
        id TEXT PRIMARY KEY,
        operation_id TEXT,
        event_type TEXT NOT NULL,
        severity TEXT NOT NULL,
        message TEXT NOT NULL,
        details_json TEXT,
        created_at TEXT NOT NULL
    );

    CREATE INDEX idx_audit_created ON audit_events(created_at);
    CREATE INDEX idx_audit_operation ON audit_events(operation_id);

    CREATE TABLE storage_snapshots (
        id TEXT PRIMARY KEY,
        volume_id TEXT NOT NULL REFERENCES volumes(id),
        observed_at TEXT NOT NULL,
        total_bytes INTEGER,
        available_bytes INTEGER,
        scanned_scope_bytes INTEGER,
        scan_id TEXT REFERENCES scan_sessions(id)
    );
    """)

    /// v2: scan coverage detail, per-root breakdown, recorded issues.
    public static let v2 = Migration(version: 2, name: "scan_coverage_detail", sql: """
    ALTER TABLE scan_sessions ADD COLUMN root_path TEXT;
    ALTER TABLE scan_sessions ADD COLUMN allocated_bytes_observed INTEGER;
    ALTER TABLE scan_sessions ADD COLUMN symlinks_skipped INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE scan_sessions ADD COLUMN excluded_items INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE scan_sessions ADD COLUMN mount_points_skipped INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE scan_sessions ADD COLUMN failure_reason TEXT;

    CREATE TABLE scan_directory_aggregates (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        scan_id TEXT NOT NULL REFERENCES scan_sessions(id) ON DELETE CASCADE,
        name TEXT NOT NULL,
        path TEXT NOT NULL,
        is_directory INTEGER NOT NULL,
        logical_bytes INTEGER NOT NULL,
        allocated_bytes INTEGER NOT NULL,
        file_count INTEGER NOT NULL,
        inaccessible_items INTEGER NOT NULL
    );
    CREATE INDEX idx_aggregates_scan ON scan_directory_aggregates(scan_id);

    CREATE TABLE scan_issues (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        scan_id TEXT NOT NULL REFERENCES scan_sessions(id) ON DELETE CASCADE,
        path TEXT NOT NULL,
        kind TEXT NOT NULL,
        error_code INTEGER
    );
    CREATE INDEX idx_issues_scan ON scan_issues(scan_id);

    CREATE INDEX idx_snapshots_volume ON storage_snapshots(volume_id, observed_at);
    CREATE INDEX idx_scans_started ON scan_sessions(started_at);
    """)

    /// v3: drill-down tree, review/approval detail for operations, application inventory keys.
    public static let v3 = Migration(version: 3, name: "operations_and_tree", sql: """
    CREATE TABLE scan_tree_nodes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        scan_id TEXT NOT NULL REFERENCES scan_sessions(id) ON DELETE CASCADE,
        path TEXT NOT NULL,
        parent_path TEXT,
        name TEXT NOT NULL,
        depth INTEGER NOT NULL,
        logical_bytes INTEGER NOT NULL,
        allocated_bytes INTEGER NOT NULL,
        file_count INTEGER NOT NULL,
        inaccessible_items INTEGER NOT NULL
    );
    CREATE INDEX idx_tree_scan_parent ON scan_tree_nodes(scan_id, parent_path);

    ALTER TABLE operation_manifests ADD COLUMN title TEXT;
    ALTER TABLE operation_manifests ADD COLUMN failure_reason TEXT;

    ALTER TABLE operation_items ADD COLUMN rule_id TEXT;
    ALTER TABLE operation_items ADD COLUMN risk_level TEXT;
    ALTER TABLE operation_items ADD COLUMN reason TEXT;
    ALTER TABLE operation_items ADD COLUMN scope_root TEXT;
    ALTER TABLE operation_items ADD COLUMN content_hash TEXT;
    ALTER TABLE operation_items ADD COLUMN keeper_path TEXT;
    ALTER TABLE operation_items ADD COLUMN message TEXT;
    ALTER TABLE operation_items ADD COLUMN position INTEGER NOT NULL DEFAULT 0;
    CREATE INDEX idx_operation_items_manifest ON operation_items(manifest_id, position);
    CREATE INDEX idx_manifests_created ON operation_manifests(created_at);

    ALTER TABLE applications ADD COLUMN is_protected INTEGER NOT NULL DEFAULT 0;
    CREATE UNIQUE INDEX idx_applications_path ON applications(bundle_path);
    """)

    public static let all: [Migration] = [v1, v2, v3]

    static func currentVersion(_ db: SQLiteConnection) throws -> Int {
        try db.execute("""
        CREATE TABLE IF NOT EXISTS schema_migrations (
            version INTEGER PRIMARY KEY,
            name TEXT NOT NULL,
            applied_at TEXT NOT NULL
        );
        """)
        return try db.query("SELECT COALESCE(MAX(version), 0) FROM schema_migrations") { $0.int(0) ?? 0 }.first ?? 0
    }

    /// Applies pending migrations, each in its own transaction. A failing migration rolls back
    /// completely and leaves the database at the previous version.
    @discardableResult
    static func migrate(_ db: SQLiteConnection, migrations: [Migration] = all) throws -> Int {
        var version = try currentVersion(db)
        for migration in migrations.sorted(by: { $0.version < $1.version }) where migration.version > version {
            do {
                try db.transaction {
                    try db.execute(migration.sql)
                    try db.run("INSERT INTO schema_migrations (version, name, applied_at) VALUES (?, ?, ?)",
                               [.integer(Int64(migration.version)), .text(migration.name), .date(Date())])
                }
                version = migration.version
                Log.persistence.info("Applied migration \(migration.version)")
            } catch {
                Log.persistence.error("Migration \(migration.version) failed")
                throw DatabaseError.migrationFailed(version: migration.version, message: "\(error)")
            }
        }
        return version
    }
}
