# MacVault

Native macOS storage intelligence. **Milestone 1:** volume capacity, read-only folder scanning with cancellation, honest partial-scan reporting, SQLite history and an audit log. Nothing in this version deletes, moves or modifies your files.

See `FEATURE_STATUS.md` for verified status. It is the source of truth.

## Layout
```
Package.swift                 SwiftPM: MacVaultCore (all platforms) + MacVault app (macOS only)
Sources/CSQLite/              system SQLite module map
Sources/MacVaultCore/
  Domain/                     typed models, statuses, errors
  Filesystem/                 FileSystemProbe (read-only), FilesystemScanner
  Volume/                     VolumeInfoService (URLResourceValues, statvfs fallback)
  Persistence/                SQLite wrapper, migrations v1–v2, Store actor
  Services/                   ScanService (use case), LaunchReconciler
  Logging/ Support/           OSLog categories, byte/time/path helpers
Sources/MacVaultApp/          SwiftUI app (App, DesignSystem, Features)
Tests/MacVaultCoreTests/      unit, isolated-filesystem integration, safety, perf smoke
Config/                       entitlements per edition, PrivacyInfo.xcprivacy
project.yml                   XcodeGen spec: MacVault-Direct and MacVault-AppStore schemes
Documentation/                decisions (ADRs), capability matrix
```

## Run on a Mac (Xcode 15.3+ / Swift 5.10+, macOS 14+)
```bash
swift test                       # core test suite
swift run MacVault               # launches the app (unbundled, Direct-edition behavior)
```
For a proper bundled, signed app with both editions:
```bash
brew install xcodegen
xcodegen generate
open MacVault.xcodeproj          # schemes: MacVault-Direct, MacVault-AppStore
```

Optional performance smoke test (read-only):
```bash
MACVAULT_PERF_ROOT=/Applications swift test -c release --filter PerformanceSmoke
```

## Run the core on Linux (CI)
Requires `libsqlite3-dev`. `swift test` builds and tests `MacVaultCore`; the app target is skipped automatically.

## Milestone 1 report

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
