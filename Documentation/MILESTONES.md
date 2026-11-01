# Milestone Reports

Historical snapshots, kept as written at the time. For the current state, see [FEATURE_STATUS.md](FEATURE_STATUS.md).

## Milestone 2 report (all planned phases)

**Built:** activity export; drill-down and treemap; a Cleaner with a versioned rule engine, safety policy, review/approval manifests and Trash execution with revalidation; application inventory with separate app and app-data removal; a duplicate finder; developer caches and project build folders; and a menu bar item with scheduled read-only scans and low-storage alerts.

**Commands run and results (macOS 27.0.1, Xcode 27.1, Swift 6.4):**
- `swift build` → succeeded, 0 warnings (core and app)
- `swift test` → 115 tests: 114 passed, 1 skipped (opt-in perf), 0 failures
- `xcodebuild` for `MacVault-Direct` and `MacVault-AppStore` (unsigned) → both succeeded, 0 warnings
- Bundled Direct build launched, created its database at schema v3, kept running
- Perf smoke on `/Applications` (297k files, release): 41.6k files/s, against 42.1k for milestone 1 on the same tree
- Code review of the full change: 10 findings, all fixed, each covered by a test where the logic is in the core

**Not verified:** screens have not been clicked through or viewed (no screen-recording or accessibility permission in the build session). No XCUITests exist yet. Signing and notarization still need an Apple Developer account.

**Next steps:**
1. Click through every screen on a Mac, especially the approval sheet and the Trash flow on a throwaway folder.
2. Add XCUITests for scan, cancel, review, approve and cancel-approval.
3. Verify App Store sandbox behaviour (security-scoped bookmarks, review-only mode).
4. Set up signing and notarization for the Direct edition.

## Milestone 1 report (historical)

**Implemented in core and tested:** a bounded, cancellable, symlink-safe scanner; inaccessible-item accounting; exclusions; mount boundaries; hard-link de-duplication; large-file findings; per-folder breakdown; versioned SQLite with migration upgrade and rollback; scan sessions, findings and issues; volume snapshots; audit log; reconciliation of interrupted scans; and retention.

**Written but not compiled:** the SwiftUI app — Overview, Storage Analyzer, Activity and Settings screens, plus "Planned" screens for Cleaner, Applications, Duplicates and Developer Tools. The files pass a Swift syntax check (`swiftc -parse`), but SwiftUI cannot be type-checked off macOS.

**Commands run and results (Linux, Swift 6.0.3):**
- `swift build` → succeeded, no warnings in MacVaultCore
- `swift test` → 42 tests: 40 passed, 2 skipped (real-permission test when running as root; perf test unless opted in), 0 failures
- The real `chmod 000` permission test was run again as an unprivileged user → passed
- Perf smoke test on `/usr` (release build): 135,219 files, 14,893 folders, 6.96 GB in 1.88 s (~72k files/s)

**Known limitations:**
- The macOS `URLResourceValues` volume path, bookmarks and all UI are untested.
- Allocated size uses `st_blocks` and can overstate usage for APFS clones.
- Breakdown covers only the root's immediate children; drill-down and treemap are planned.
- Activity export is not built yet.

**Next steps:**
1. Build on a Mac and fix any type-check errors in the app target.
2. Add UI tests for the scan, cancel and partial states.
3. Verify the App Store edition sandbox and bookmark flow.
4. Phase 2: cleanup rule engine, manifest and approval, and Trash execution with revalidation — gated by safety tests.
