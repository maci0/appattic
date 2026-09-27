# Security

No dedicated disclosure contact, supported-version list, or vulnerability-response process is published for this repository.

The living attack-surface model is [`docs/THREAT_MODEL.md`](docs/THREAT_MODEL.md). Claims below are checked against the code as of that document's last-reviewed date.

## What this software is

AppAttic is a local CLI and desktop UI. It does not listen on a network port, authenticate users, or accept untrusted remote clients. It runs as the OS user who launched it and can generate `/bin/sh` scripts that delete leftover files or uninstall/upgrade packages.

## What the code actually does

- **Leftovers, stale, outdated (report), and packages CLI** print a report. They do not delete. `--dry-run` prints a script for the operator to review and run themselves (`Sources/AppAtticCLI/main.swift`, `Sources/AppAtticScan/Cleanup.swift`).
- **CLI `update` without `--dry-run`** prompts before writing and running a temp `/bin/sh` script when stdin is a TTY. Without a TTY it refuses with exit 2 unless `--yes` is passed, so an unattended run is an explicit choice; `--dry-run` is the review-only path. It upgrades Homebrew formulas/casks and Flatpak apps only (`confirmUpdate` in `Sources/AppAtticCLI/main.swift`; `updateScript` in `Sources/AppAtticScan/Outdated.swift`).
- **macOS and Linux UIs** run delete, update, and mark-manual scripts after a confirm dialog when `confirmDelete` is true (the default). The operator can turn that setting off in the UI or in `settings.json`.
- **Untrusted Homebrew casks** stay listed and are not updated (`Sources/AppAtticScan/BrewInfo.swift`, `Outdated.swift`). Named apt/pacman/AUR/dnf/yum/zypper upgrades run only after confirm, as a reviewed `/bin/sh` script, never through `host.exec`. Distro lines use `pkexec` or `sudo` (`rootcmd`). App Store, Snap, pip, gem, and composer stay report-only.
- **WASM `host.exec`** (Linux Qt core) allowlists read-only package-manager queries and denies destructive argv (`core/host/hostexec.c`). Cleanup still happens in a host `/bin/sh` script the UI runs, not through `host.exec`.
- **WASM modules** in the core-out directory are loaded by `*.wasm` glob and checked for ABI version 1 only. They are not signed and there is no filename allowlist, so anyone who can write into that directory controls what the core loads (`ui/linux-qt/corehost.cpp`).
- **Local state and generated scripts** are owner-only: `settings.json` and `last-scan.json` are written atomically then `0600` (`FilePermissions.swift` `restrictPrivateDataFile`), and each generated script is `0600` (`writeOwnerOnlyFile`) or created exclusively (`QTemporaryFile`). The temp directory itself is the shared world-writable one, so the mode and the exclusive create are the whole control.
- **Generated scripts** quote paths and names (`shellQuote` in `Sources/AppAtticScan/ShellScript.swift`). Quoting is not a substitute for a wrong leftover classification.

## Out of scope for this file

Individual vulnerability fixes, CVE/dependency inventory, and PII mapping live elsewhere. The third-party inventory is `scripts/deps.sh`: `check` gates the pins in `scripts/lint.sh`, `sbom` writes the CycloneDX file shipped next to each release artifact. This file must not claim a mitigation the code does not implement.
