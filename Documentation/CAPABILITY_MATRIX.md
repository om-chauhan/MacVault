# Capability Matrix by Edition

Both editions share `MacVaultCore`. The `APPSTORE` compilation condition selects edition behavior.
Nothing in this table has been verified on a signed build yet.

| Capability | Direct (Developer ID) | Mac App Store |
|---|---|---|
| Sandbox | No (hardened runtime) | Yes |
| Folders it can scan | Folders you choose; TCC-protected locations need Full Disk Access granted by you | Only folders you choose (read-only, security-scoped bookmarks) |
| Remembering folder access across launches | Plain bookmark (security-scoped when available) | Security-scoped bookmark is required; stale → “Choose Again” |
| “Open Full Disk Access Settings” shortcut | Shown | Hidden |
| Volume capacity | `URLResourceValues` | `URLResourceValues` (expected to work in sandbox — verify) |
| Scan history / audit log location | `~/Library/Application Support/MacVault/` | App container |
| Privileged helper / root escalation | Never | Never |
| Cleaner, Developer Tools, app removal, duplicates | Review **and** move approved items to the Trash | Review only (read-only entitlement): items can be revealed in Finder, not moved |
| App leftovers in ~/Library | Real ~/Library | Container ~/Library only — not meaningful; review-only |
| Scheduled scans, low-storage alerts, menu bar | Yes (while the app is open) | Yes (while the app is open) |
| Activity export | Yes | Yes (save panel grants write access to the chosen file) |
