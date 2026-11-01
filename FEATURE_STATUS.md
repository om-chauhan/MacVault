# MacVault — Feature Status

Status labels: **Implemented** (real behavior exists *and* is covered by tests that were run), **Partial**, **Planned**, **Blocked**.

Last verified: 2026-10-30, milestone 2 (all planned phases). Verification environment: macOS 27.0.1 (Apple silicon), Xcode 27.1, Swift 6.4.

**What was verified for the app:** both Xcode schemes (`MacVault-Direct`, `MacVault-AppStore`) and `swift build` compile with zero warnings; the bundled Direct build launches, creates its database at schema v3 and stays running. **What was not verified:** the screens have not been exercised interactively or visually (this session had no screen-recording or accessibility permission). Every app-only row below is therefore at most **Partial** until it is clicked through on a Mac. The safety-critical logic behind every screen lives in `MacVaultCore` and is fully tested.

## Core (tested: 115 tests, 1 opt-in perf test skipped, 0 failures)

| Capability | Status | Evidence / notes |
|---|---|---|
| Read-only filesystem scanner (bounded traversal, lstat, no symlink following) | **Implemented** | `FilesystemScanner`; 18 scanner tests |
| Cooperative cancellation with partial results | **Implemented** | Cancelled scans return `.cancelled`; tested |
| Inaccessible-item counting and partial-scan state | **Implemented** | Injected EACCES/EPERM/ENOENT; real `chmod 000` test |
| Exclusions, mount boundaries, hard links counted once | **Implemented** | Tested |
| Large-file findings; root breakdown with “lower bound” flag | **Implemented** | Tested |
| Drill-down tree (directories ≤ 4 levels, largest 4,000 kept with all ancestors) | **Implemented** | `ScannerTreeTests`: rollup, depth limit, pruning keeps ancestors, unreadable propagation, persistence. No throughput change: 42.1k vs 41.6k files/s on `/Applications` (297k files), same machine |
| Treemap layout (squarified) | **Implemented** | `TreemapLayoutTests`: proportional areas, in bounds, no overlap |
| Volume capacity | **Implemented** | `URLResourceValues` path now runs in tests on macOS |
| SQLite store: migrations v1→v3, FKs, transactions | **Implemented** | v3 adds tree nodes and operation review detail; v2→v3 upgrade tested |
| Audit log; interrupted-scan **and interrupted-operation** reconciliation | **Implemented** | Tested |
| Activity export (JSON/CSV, home-folder redaction, CSV formula neutralisation) | **Implemented** | `ActivityExporterTests` |
| Safety policy (protected locations, credentials, packages, scopes) | **Implemented** | `SafetyPolicyTests` (19) run against the real default system roots |
| Operation manifests: draft → approved → executing → outcome; approve once, execute once | **Implemented** | `OperationExecutorTests` |
| Trash execution with per-item revalidation | **Implemented** | Tested: missing, replaced (inode), symlink swap, parent-folder symlink swap, protected path in a tampered list, in use, Trash error, cancellation, failure to record an outcome |
| Cleanup rules (caches, logs) | **Implemented** | `CleanupCandidateFinderTests`; rule catalog `2026.10.1` |
| Developer caches (DerivedData, Simulator, npm, DeviceSupport, Gradle, pub, Archives) | **Implemented** | Every rule target is policy-checked in tests |
| Project build folders (node_modules, Flutter/Gradle build, .dart_tool, .gradle, Rust target) | **Implemented** | `ProjectArtifactFinderTests`: marker required, symlinks and VCS-containing folders never offered |
| Application inventory, protected Apple apps and MacVault itself | **Implemented** | `ApplicationInventoryTests` |
| App leftovers (separate review, confidence-rated, never login items or keychains) | **Implemented** | Tested; removing an app keeps its data |
| Duplicate finder (size → 64 KiB prefix → full SHA-256; hard links never offered) | **Implemented** | `DuplicateFinderTests`; SHA-256 checked against FIPS vectors |
| Duplicate removal re-verifies both copies' hashes before moving | **Implemented** | Tested: kept copy changed or missing, item edited in place, hard link |
| Scheduled scan logic; low-storage warning with hysteresis | **Implemented** | `MonitoringTests` |

## App (compiled in both editions and launched; not yet exercised interactively)

| Capability | Status | Notes |
|---|---|---|
| Overview, Storage Analyzer, Activity, Settings | **Partial** | Compiled and launched |
| Analyzer drill-down list and treemap with breadcrumbs | **Partial** | Compiled |
| Permissions sheet: first-launch consent that lists Full Disk Access, Desktop/Documents/Downloads, scan scope and notifications with probed status and one “Allow All” | **Partial** | Compiled; UI test covers open, rows, Not Now and reopening. Full Disk Access can only be granted in System Settings (opened for the user); its state is probed by listing a protected folder |
| Analyzer scope: Whole Mac (startup disk), chosen folder, or typed path | **Partial** | Compiled. Whole-Mac scan of `/` skips `/System/Volumes` so the Data volume is not counted twice; verified with a real read-only scan of this Mac (3.4M files, status Partial because of TCC-protected folders) |
| Activity export menu (save panel) | **Partial** | Compiled |
| Cleaner, Developer Tools, Applications, Duplicates screens | **Partial** | Compiled. Shared approval sheet; high-risk items need an explicit acknowledgement |
| In-use checks before moving (running app, Xcode/Simulator for their caches) | **Partial** | Compiled; uses `NSRunningApplication` |
| Menu bar extra; scheduled read-only scans while open; low-storage notifications | **Partial** | Compiled. Notifications need the bundled app; under `swift run` they are skipped and events still go to Activity |
| Folder access via bookmarks (security-scoped in App Store edition) | **Partial** | Needs on-device verification in both editions |
| UI tests (XCUITest) | **Planned** | Not written: needs a Mac session with accessibility permission to run |
| App Store build / Direct build signing & notarization | **Blocked** | Requires an Apple Developer account and signing identities |

## Safety invariants
- Exactly one code path changes user files: `OperationExecutor`, through an injected `FileTrasher` that can only move items to the Trash. Nothing is ever deleted outright.
- Nothing runs without an approved manifest. Approval is a separate, explicit step in the UI (the approval sheet), and a manifest can be approved once and executed once.
- `SafetyPolicy` is applied when candidates are produced **and again** right before each item moves. Each item is also revalidated (same device:inode, not a symlink, parent folders unchanged, not in use; duplicates re-hashed).
- Every item outcome is saved before the next item starts. If an outcome cannot be saved, execution stops.
- The App Store edition keeps its read-only entitlement: it can review but never move items.
- MacVault deletes data only from its own database (Delete Scan History), only after confirmation.
- Scans with unreadable items are `partial`, never `completed`.
