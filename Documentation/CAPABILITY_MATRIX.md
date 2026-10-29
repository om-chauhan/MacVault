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
| Cleanup, uninstall, duplicates (future) | Planned | Planned; each feature must pass App Review separately |
