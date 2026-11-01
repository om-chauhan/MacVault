# Capability Matrix by Edition

Both editions share `MacVaultCore`. The `APPSTORE` compilation condition selects edition behavior.
Nothing in this table has been verified on a signed build yet.

| Capability | Direct (Developer ID) | Mac App Store |
|---|---|---|
| Sandbox | No (hardened runtime) | Yes |
| Folders it can scan | The whole startup disk (“Whole Mac”), or any folder chosen in the open panel or typed as a path; TCC-protected locations need Full Disk Access granted by you | Only folders you choose in the open panel (read-only, security-scoped bookmarks); “Whole Mac” and typed paths work only after choosing the startup disk or that folder in the panel |
| Remembering folder access across launches | Plain bookmark (security-scoped when available) | Security-scoped bookmark is required; stale → “Choose Again” |
| “Open Full Disk Access Settings” shortcut | Shown | Hidden |
| Permissions sheet (one consent for everything) | Full Disk Access (status probed; granted in System Settings), Desktop/Documents/Downloads (macOS dialogs triggered once), Whole Mac scope, notifications | Desktop/Documents/Downloads, chosen folders (open panel), notifications; no Full Disk Access row |
| Volume capacity | `URLResourceValues` | `URLResourceValues` (expected to work in sandbox — verify) |
| Scan history / audit log location | `~/Library/Application Support/MacVault/` | App container |
| Privileged helper / root escalation | Never | Never |
| Cleaner, Developer Tools, app removal, duplicates | Review **and** move approved items to the Trash | Review only (read-only entitlement): items can be revealed in Finder, not moved |
| App leftovers in ~/Library | Real ~/Library | Container ~/Library only — not meaningful; review-only |
| Scheduled scans, low-storage alerts, menu bar | Yes (while the app is open) | Yes (while the app is open) |
| Activity export | Yes | Yes (save panel grants write access to the chosen file) |
