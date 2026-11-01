# Security Policy

## Reporting a vulnerability

Please report security problems privately, not in a public issue. On GitHub, open the repository's **Security** tab and choose **Report a vulnerability**.

Include the steps to reproduce the problem, the MacVault and macOS versions, and what an attacker or a bug could do as a result.

## What counts

The most serious problems are ones that break MacVault's safety guarantees:

- An item moves without being reviewed and approved, or a different item moves than the one approved.
- A protected path, such as a system folder, credentials or Git data, can be moved.
- Anything is deleted outright rather than moved to the Trash.
- A test hook takes effect in a Release build.
- Data leaves the Mac, or a redacted Activity export still contains the home folder or account name.

## Supported versions

Only the latest release is supported. Builds aren't notarized yet, so check that you downloaded yours from this repository's Releases page.
