# Security

AppAttic is a local CLI and desktop utility. It runs as the OS user who launched it, with no login, remote API, or network listener. Cleanup and package operations can permanently remove data; some package-manager commands request elevated privileges through polkit or sudo.

No dedicated disclosure contact, supported-version list, or vulnerability-response process is published in this repository. Do not include private paths, settings, or unredacted scan exports in a public report.

## Before running an action

- Review the selected paths and generated script. An orphaned classification or a package's presence does not prove it is safe to remove. Container volumes reported as dangling may still contain valuable data.
- UI delete, update, and mark-manual actions ask for confirmation by default. The `confirmDelete` setting can disable that dialog. The Linux disk page has its own Trash confirmation and no packaged-path protection.
- CLI scan commands report findings; `--dry-run` prints a script. `appattic update` executes upgrades after a terminal prompt, or with explicit `--yes` for unattended use. Without a terminal or `--yes`, it exits 2.
- `appattic erase` deletes only the saved scan snapshot, without confirmation. `appattic restore` validates and restores the settings backup without confirmation. Both work before settings are loaded. Erase leaves settings and backups alone; restore can overwrite `settings.json.bad` from an earlier restore.

## Trust and confinement

The macOS app is ad-hoc signed and has no App Sandbox entitlement. AppImage runs with the user's normal permissions. Flatpak grants broad read-only host filesystem access, but queries and generated scripts run on the host through `flatpak-spawn --host`; its sandbox does not confine those scripts.

Swift script runners replace `PATH` with a fixed list of system and Homebrew directories. Qt scripts use an augmented user `PATH`. Trust the binaries in those directories, package-manager output, and the WASM module directory: plugins are not signed, and the Qt host loads matching `.wasm` files from that directory. Query allowlisting does not validate plugin-generated cleanup commands.

State files and scripts are written owner-only. These permissions protect against other OS accounts, not another process running as you. Scan exports contain full paths; `appattic config` prints full ignored paths and environment values. Review either before sharing.

See the [threat model](docs/THREAT_MODEL.md) for controls and remaining risks, [privacy guide](docs/privacy.md) for retained data, and [state recovery guide](docs/runbooks/state-recovery.md) for recovery steps. Build dependency pins and the release SBOM are maintained by `scripts/deps.sh`; they do not cover every library supplied by the build host.
