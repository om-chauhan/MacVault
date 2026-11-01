# Contributing to MacVault

Bug reports, fixes and new cleanup rules are all welcome. MacVault handles people's files, so changes that affect removal get extra care.

## Set up

You need macOS 14 or later and Xcode 16 or later.

```bash
git clone https://github.com/om-chauhan/MacVault.git
cd MacVault
swift test                # core test suite
swift run MacVaultApp     # launches the app, unbundled
```

For the bundled app and the UI tests, generate the Xcode project. It's gitignored, so regenerate it after adding or moving files.

```bash
brew install xcodegen
xcodegen generate
open MacVault.xcodeproj   # schemes: MacVault-Direct, MacVault-AppStore
```

## Before you open a pull request

Run these and make sure they pass:

```bash
swift build
swift test
xcodebuild -project MacVault.xcodeproj -scheme MacVault-Direct -configuration Debug CODE_SIGNING_ALLOWED=NO build
xcodebuild -project MacVault.xcodeproj -scheme MacVault-AppStore -configuration Debug-AppStore CODE_SIGNING_ALLOWED=NO build
```

If you changed a screen, also run the UI tests. They take over the mouse and keyboard for several minutes.

```bash
xcodebuild -project MacVault.xcodeproj -scheme MacVault-Direct CODE_SIGN_IDENTITY=- test
```

Pull requests run `swift test` and a Release build of the Direct edition in CI. CI doesn't run the UI tests or build the App Store edition.

## Safety rules

These are what make MacVault trustworthy, so pull requests that weaken them won't be accepted:

- **One code path changes files.** Only `OperationExecutor`, through `FileTrasher`, may change anything on disk, and it can only move items to the Trash. Nothing is ever deleted outright.
- **Nothing moves without approval.** Features build candidate lists. They never bypass the review and approval sheet.
- **Check twice.** `SafetyPolicy` runs when candidates are produced and again right before each item moves. Each item is also revalidated at that point.
- **Scans stay read-only.** A scan that couldn't read everything is reported as partial, never as complete.
- **Test hooks stay out of releases.** Anything that exists only for tests goes behind `#if DEBUG`.
- **No network.** No telemetry, accounts or calls to outside services.
- **Honest numbers.** Show only measured or system-reported values, and show unknown as unknown. Never claim "space freed".

Any change to removal logic needs a test in `Tests/MacVaultCoreTests`. New cleanup rules go in `Sources/MacVaultCore/Cleanup/CleanupRules.swift`, and their targets must pass the safety policy tests.

## Where things live

- [ARCHITECTURE.md](Documentation/ARCHITECTURE.md) explains how the system fits together.
- [DECISIONS.md](Documentation/DECISIONS.md) records why it's built this way. Add an entry for any significant design decision.
- [DESIGN.md](Documentation/DESIGN.md) describes the visual language. Reuse the tokens and components in `DesignSystem.swift` rather than one-off values.
- [FEATURE_STATUS.md](Documentation/FEATURE_STATUS.md) tracks what's verified. Mark a feature as verified only if you saw it pass.

`MacVaultCore` is written to also build and test on Linux (it needs `libsqlite3-dev`), so keep AppKit and SwiftUI out of it. This isn't checked in CI and was last confirmed at milestone 1.

The README's images are in `Documentation/Images`. To capture new ones, run `Scripts/ui-screenshots.sh <output folder>`, which drives the app on sample data. Stay off the mouse and keyboard while it runs, because a click can bring another window forward and fail the run. Check every image before you commit it: the Overview shows your Mac's real disk numbers, and the output folder can contain recordings of your whole screen from failed tests.

## Releases

Every push to `master` that passes CI tags its commit and publishes a GitHub Release with `MacVault.dmg` and `MacVault.zip`. Versions look like `v0.1.37`. `MARKETING_VERSION` in `project.yml` sets the first two numbers, so change it there to start a new series. The last number is the CI run number, and gaps are normal because pull request runs use the same counter.

Pull request builds aren't released. Download them from **Artifacts** on the run's page in the **Actions** tab, where they're kept for 90 days by default.

## Reporting problems

Use [GitHub Issues](https://github.com/om-chauhan/MacVault/issues) for bugs. Include your macOS version, what you expected, what happened, and an export from the Activity screen if it's relevant. Choose the redacted option when exporting, and check the file before you attach it.

For anything that could let MacVault touch a file it shouldn't, please follow [SECURITY.md](SECURITY.md) instead of opening a public issue.
