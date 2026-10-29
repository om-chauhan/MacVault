# Architecture Decisions (milestone 1)

ADR-001…005 from the product pack are accepted unchanged (SwiftUI, local-first, review-first, one core/two editions, SQLite).

## ADR-006: Swift package with a platform-neutral core
**Decision:** `MacVaultCore` (domain, scanner, persistence, services) is a SwiftPM library that builds on macOS **and Linux**; the SwiftUI app is a separate macOS-only target that depends on it.
**Reason:** Lets the safety-critical logic be compiled and tested in CI without a Mac, and makes it hard for UI code to reach the filesystem directly.
**Trade-off:** Volume APIs need a `statvfs` fallback for Linux; the macOS-specific path must still be tested on a Mac.

## ADR-007: POSIX `lstat`/`opendir` instead of `FileManager.enumerator`
**Decision:** The scanner uses an explicit-stack traversal over `lstat` and `readdir`.
**Reason:** Exact `errno` for every failure (so inaccessible items are counted, not silently skipped), guaranteed non-following of symlinks, device ID for mount boundaries, inode for hard-link de-duplication, and `st_blocks` for allocated size. Behavior is identical on macOS and Linux.
**Trade-off:** Doesn't use APFS-specific resource values (e.g. `totalFileAllocatedSize`, clone awareness). Allocated sizes may overstate physical usage for cloned files; the UI says so.

## ADR-008: Injected read-only `FileSystemProbe`
**Decision:** The scanner receives a struct of two closures (`stat`, `list`). There are no mutating operations on it.
**Reason:** Deterministic tests for permission denial, vanished files, undecodable names and mount boundaries (also works when tests run as root). It's also a structural guarantee that the scanner can't modify files.

## ADR-009: Cancellation returns a result, not an error
**Decision:** A cancelled scan returns `ScanResult(status: .cancelled)` with everything observed so far.
**Reason:** Partial observations are recorded and labelled, never lost or promoted to complete.

## ADR-010: Store as a Swift actor over one SQLite connection
**Decision:** `Store` is an actor with direct prepared statements over the C API (no third-party ORM). WAL mode, foreign keys on, migrations transactional with a `schema_migrations` table.
**Trade-off:** Hand-written SQL; mitigated by round-trip tests.

## ADR-011: v1 schema kept verbatim, extensions in v2
**Decision:** Migration 1 is exactly the schema in `06_DATA_MODEL_AND_SQLITE_SCHEMA.md`. Migration 2 adds scan-coverage columns (`root_path`, `allocated_bytes_observed`, `symlinks_skipped`, `excluded_items`, `mount_points_skipped`, `failure_reason`) plus `scan_directory_aggregates` and `scan_issues`.
**Reason:** Exercises the migration path from day one.

## ADR-012: Persist top-N, not every file
**Decision:** Only large-file findings (capped, default 500), the root's immediate-child breakdown, and the first 200 issues are persisted. Totals are always exact counts.
**Reason:** Matches "avoid storing every file on disk" and bounds memory and database growth.

## ADR-013: Progress is awaited
**Decision:** Progress callbacks are `async` and awaited by the scanner, at most every 250 ms.
**Reason:** Natural backpressure, and session counters are persisted at the same cadence. If the app crashes, the interrupted session keeps its last saved counts.

## Working assumptions for open questions (change any of these freely)
| # | Question | Assumption used |
|---|---|---|
| 1 | Minimum macOS | **macOS 14 Sonoma** (Observation framework, `ContentUnavailableView`, `@Bindable`) |
| 2 | Apple Silicon / Intel | Both (no architecture-specific code) |
| 3 | First-release priority | Direct download first; App Store edition kept buildable |
| 4 | Quarantine vs Trash | Finder Trash (for the cleaner milestone) |
| 5 | Retention | Keep newest 20 scans by default (user-configurable); snapshots kept |
| 6 | Telemetry | None |
| 7 | Docker | Read-only inspection only, later milestone |
| 8 | Palette | System accent color + semantic colors |
| 9–12 | Pricing, updates, similarity, perf targets | Not decided; measured baseline: ~72k files/s on Linux (release build, `/usr`, 135k files) |
