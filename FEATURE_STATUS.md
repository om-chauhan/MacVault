# MacVault — Feature Status

Status labels: **Implemented** (real behavior exists *and* is covered by tests that were run), **Partial**, **Planned**, **Blocked**.

Last verified: 2026-10-29, milestone 1. Verification environment: Linux x86_64, Swift 6.0.3, SQLite 3.45.1.
The SwiftUI app target **has not been compiled** (needs macOS + Xcode). Anything that depends on it is at most **Partial** until it is built and exercised on a Mac.

| Capability | Status | Evidence / notes |
|---|---|---|
| Read-only filesystem scanner (bounded traversal, lstat, no symlink following) | **Implemented** | `FilesystemScanner`; 18 scanner tests |
| Cooperative cancellation with partial results | **Implemented** | Cancelled scans return `.cancelled` and are never marked complete; tested |
| Inaccessible-item counting and partial-scan state | **Implemented** | Injected EACCES/EPERM/ENOENT tests; real `chmod 000` test passes as a non-root user (skipped as root) |
| Exclusions (component-aware) | **Implemented** | Tested, incl. prefix-collision case |
| Mount-point boundary (don't enter other volumes by default) | **Implemented** | Tested via injected device IDs; real external-volume test still to run on a Mac |
| Hard links counted once | **Implemented** | Tested |
| Large-file findings (bounded) | **Implemented** | Threshold and cap tested |
| Per-entry breakdown of the scan root, with “lower bound” flag | **Implemented** | Tested |
| Throttled, awaited progress (backpressure) | **Implemented** | Monotonic progress test |
| Volume capacity (system-reported, with source + timestamp) | **Partial** | Linux `statvfs` path tested. macOS `URLResourceValues` path written, **not run** |
| SQLite store: versioned migrations, FKs, transactions | **Implemented** | v1 = spec schema; v2 adds coverage columns, breakdown, issues. Upgrade + rollback tested |
| Scan sessions, findings, issues, snapshots persisted | **Implemented** | Integration tests through `ScanService` |
| Audit log (append-only, searchable, severity filter) | **Implemented** | Core tested; audit write failures surface as warnings |
| Interrupted-scan reconciliation on launch | **Implemented** | `running` → `interrupted` + audit event; tested |
| Scan history retention | **Implemented** | Never prunes a running scan; tested |
| Storage history snapshots (rate-limited, no invented points) | **Implemented** (core) / **Partial** (chart UI) | Chart written, not rendered |
| Native app shell + sidebar navigation | **Partial** | Written in SwiftUI; not compiled here |
| Overview dashboard (real data only) | **Partial** | Not compiled here |
| Storage Analyzer (scan, cancel, progress, largest files table, breakdown, Finder reveal) | **Partial** | Not compiled here |
| Activity screen (search, severity filter, details) | **Partial** | Not compiled here |
| Settings (threshold, exclusions, access, retention, delete history) | **Partial** | Not compiled here |
| Folder access via bookmarks (security-scoped in App Store edition) | **Partial** | Written; needs on-device verification in both editions |
| Activity export (JSON/CSV, redacted) | **Planned** | Button shown disabled with “Planned” tooltip |
| Treemap / drill-down navigation | **Planned** | Breakdown list ships instead |
| Cleaner (rules, manifest, Trash) | **Planned** | Screen shows “Planned”; no deletion code exists |
| Application inventory / uninstaller | **Planned** | |
| Duplicate finder | **Planned** | |
| Developer cleanup | **Planned** | |
| Menu bar, scheduled read-only scans, notifications | **Planned** | |
| App Store build / Direct build signing & notarization | **Blocked** | Requires a Mac, Apple Developer account and signing identities |

## Safety invariants held by this milestone
- There is **no code path that deletes, moves or writes user files.** `FileSystemProbe` exposes only `stat` and `list`.
- The only data MacVault deletes is from its own database, and only when you approve it in the Delete Scan History dialog.
- Scans with unreadable items are `partial`, never `completed`.
