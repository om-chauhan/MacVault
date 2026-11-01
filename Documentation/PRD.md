# MacVault — Product Requirements

> This PRD was reconstructed on 2026-10-31 from the implemented product, the architecture decisions and the milestone reports. Treat it as the current baseline.

## 1. Problem

Mac users run out of disk space and can't easily tell why. The tools that "clean" a Mac often delete things without showing what, overstate savings, or ask for broad system access. Developers lose tens of gigabytes to build caches they don't know about. People are rightly afraid that a cleaner will remove something they needed.

## 2. Product

MacVault is a native, local-only macOS app. It shows what uses space, and helps remove what isn't needed. It shows exactly what it would do, does it only after you approve, and is always reversible.

### Principles
1. **Read first, change last.** Everything starts read-only. Nothing changes without an explicit, itemised approval.
2. **Reversible only.** MacVault never deletes. Approved items go to the Trash.
3. **Honest numbers.** Every value is measured or system-reported, with its source. Unknown is shown as unknown, never as zero. "Space freed" is never claimed (Trash still uses space; APFS clones share storage).
4. **Least access.** Scan only folders the user chooses. Never ask the user to disable system security. No privileged helper.
5. **Local and private.** No telemetry, no network, no accounts.
6. **Accessible and native.** Follows system appearance and Reduce Motion; status is never shown by color alone; full VoiceOver labels.

## 3. Users

| Persona | Need |
|---|---|
| Everyday Mac user | "My disk is full — what's taking space, and what can I safely remove?" |
| Developer (Xcode, Flutter, Node, Gradle, Rust) | Reclaim caches and build folders without risking source, Git data or signing assets |
| Careful power user | Full detail and an audit trail of everything the app did |

## 4. Goals and non-goals

**Goals:** explain disk usage; offer safe, reviewable removal for caches, logs, developer files, apps and duplicates; keep a complete local history.

**Non-goals (for now):** publishing — App Store submission, Developer ID signing and notarization are deferred by decision. Also out of scope: automatic or unattended removal; "speed up your Mac" features; cloud sync; deleting anything outright; system-wide cleanup outside the user's home.

## 5. Functional requirements

Each area lists requirements (R) and acceptance criteria (AC). Status is tracked in [FEATURE_STATUS.md](FEATURE_STATUS.md).

### 5.1 Overview
- R: Show each mounted volume's capacity, used and available space (system-reported, with source and time), and the history of available space.
- R: Show recommendations derived only from real observations (low space, stale folder access, incomplete last scan).
- AC: An unknown value reads "Unknown". History plots only recorded observations.

### 5.2 Storage Analyzer
- R: Scan a folder the user chose: read-only, cancellable, with live progress.
- R: Show the largest files, a breakdown of the folder's contents, and drill-down (list and treemap) up to four levels.
- R: Report coverage honestly: unreadable items, excluded items, symbolic links not followed, other volumes not entered.
- AC: A scan with any unreadable item is "Scan incomplete", never "Completed". Sizes containing unreadable items are marked "lower bound". A cancelled scan shows only what was read.

### 5.3 Cleaner (caches and logs)
- R: Find app caches (`~/Library/Caches`) and logs older than 7 days (`~/Library/Logs`) using a versioned rule catalog.
- R: Each item shows its exact path, measured size, risk, why it is offered and what happens after removal.
- AC: Apple and system caches are never offered. Caches of a running app are skipped at execution time.

### 5.4 Developer Tools
- R: Global caches — Xcode DerivedData, Simulator caches, npm, iOS DeviceSupport, Gradle, Dart/Flutter packages, Xcode Archives — each with a risk level and a rebuild cost.
- R: Project build folders inside a chosen folder (node_modules, Flutter/Gradle build, .dart_tool, .gradle, Rust target), offered only next to their project files.
- AC: Source code, Git data, credentials, signing assets and simulator devices are never offered. Archives are high risk and never pre-selected. Xcode/Simulator caches are skipped while those tools run.

### 5.5 Applications
- R: List installed apps (/Applications, ~/Applications) with version and bundle size.
- R: App removal and app-data removal are separate, separately approved actions.
- R: Associated data is found by bundle identifier (high confidence) or app name (medium confidence), with the reason shown.
- AC: Apple apps and MacVault itself can't be removed. Running apps are skipped. Login items and keychains are never listed. Data that may contain documents (Application Support, Containers) is never pre-selected.

### 5.6 Duplicates
- R: Find files with identical content in a chosen folder, above a minimum size.
- R: The user chooses which copy to keep; the suggestion is the oldest copy.
- AC: Duplicates are verified with a full SHA-256. Hard-linked files are never offered. Before moving, both the kept copy and the copy to move are re-hashed; if either changed, the item is skipped. App libraries, packages, Git data and ~/Library are never searched.

### 5.7 Review and approval (all removal features)
- R: One approval sheet for every removal: the exact items, sizes and risks, and that items go to the Trash.
- R: High-risk items need an extra acknowledgement.
- R: Execution can be stopped; remaining items are untouched.
- R: Afterwards, show what moved, what was skipped or failed and why, plus a history with "Show in Trash".
- AC: Nothing moves without approval. A list can be approved and executed only once. Changed, missing, protected or in-use items are skipped with a reason. If the app stops mid-run, the next launch reports it.

### 5.8 Activity
- R: An append-only log of scans, access changes, reviews, approvals and each item's outcome, searchable and filterable by severity.
- R: Export as JSON or CSV, optionally with the home folder and account name redacted.
- AC: CSV cells can't be interpreted as spreadsheet formulas. Redaction never alters other users' paths.

### 5.9 Monitoring
- R: Optional scheduled read-only scans (daily or weekly), low-storage warnings with a threshold, and a menu bar item with capacity, last scan and quick actions.
- AC: These run only while MacVault is open and never remove anything. A low-space warning fires once per drop and re-arms only after recovery. Every warning is also recorded in Activity.

### 5.10 Settings and data
- R: Large-file threshold, exclusions, whether to enter other volumes, folder access (add/remove/renew), retention, monitoring options, and deleting MacVault's own scan history (confirmed; files untouched).

## 6. Non-functional requirements

| Area | Requirement | Current measurement |
|---|---|---|
| Performance | Scanning must not block the UI; progress at least every 250 ms; memory bounded regardless of tree size | ~42k files/s on APFS (`/Applications`, 297k files, release build) |
| Reliability | Interrupted scans and operations are detected and labelled on next launch; database migrations are transactional | Tested |
| Privacy | No network access, no telemetry; logs redact paths | By construction |
| Security | Hardened runtime (Direct); sandbox with read-only user-selected access (App Store); no privileged helper | Entitlements in `Config/` |
| Accessibility | VoiceOver labels on every control; no color-only status; Reduce Motion respected | Partly covered by UI tests |
| Compatibility | macOS 14 Sonoma or later, Apple silicon and Intel | Built on macOS 27 / Xcode 27 |

## 7. Editions

| | Direct | App Store |
|---|---|---|
| Distribution | Developer ID download (deferred) | Mac App Store (deferred) |
| Removal | Review and move to Trash | Review only |

## 8. Open questions

Carried over from [DECISIONS.md](DECISIONS.md) (working assumptions): pricing, update mechanism, similar-image (non-identical) duplicates, Docker image inspection, formal performance targets, and whether the App Store edition should gain removal (needs read-write folder access).
