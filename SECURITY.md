# Security

No dedicated disclosure contact, supported-version list, or vulnerability-response process is published for this repository.

The living attack-surface model is [`docs/THREAT_MODEL.md`](docs/THREAT_MODEL.md). Claims below are checked against the code as of that document's last-reviewed date.

## What this software is

AppAttic is a local CLI and desktop UI. It does not listen on a network port, authenticate users, or accept untrusted remote clients. It runs as the OS user who launched it and can generate `/bin/sh` scripts that delete leftover files or uninstall/upgrade packages.

## What the code actually does

- **Leftovers, stale, outdated (report), and packages CLI** print a report. They do not delete. `--dry-run` prints a script for the operator to review and run themselves (`Sources/AppAtticCLI/main.swift`, `Sources/AppAtticScan/Cleanup.swift`).
- **CLI `update` without `--dry-run`** prompts before writing and running a temp `/bin/sh` script when stdin is a TTY. Non-interactive invocations proceed without a prompt. It upgrades Homebrew formulas/casks and Flatpak apps only (`confirmLiveUpdate` in `Sources/AppAtticCLI/main.swift`; `updateScript` in `Sources/AppAtticScan/Outdated.swift`).
- **macOS and Linux UIs** run delete, update, and mark-manual scripts after a confirm dialog when `confirmDelete` is true (the default). The operator can turn that setting off in the UI or in `settings.json`.
- **Untrusted Homebrew casks** stay listed and are not updated (`Sources/AppAtticScan/BrewInfo.swift`, `Outdated.swift`). App Store, apt, pacman, dnf, zypper, and Snap upgrades are report-only.
- **WASM `host.exec`** (Linux Qt core) allowlists read-only package-manager queries and denies destructive argv (`core/host/hostexec.c`). Cleanup still happens in a host `/bin/sh` script the UI runs, not through `host.exec`.
- **Generated scripts** quote paths and names (`shellQuote` in `Sources/AppAtticScan/Util.swift`). Quoting is not a substitute for a wrong leftover classification.

## Out of scope for this file

Individual vulnerability fixes, CVE/dependency inventory, and PII mapping live elsewhere. This file must not claim a mitigation the code does not implement.
