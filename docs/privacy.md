# What AppAttic reads, stores, and sends

AppAttic runs locally as your OS user. It has no account system, telemetry, analytics SDK, or automatic crash reporting. Scans can contact package repositories and Apple's lookup service; local operation does not mean offline operation.

## What a scan reads

Scans read directory entries and metadata such as paths, sizes, modification times, permissions, and symlink targets. They also inspect installed apps, desktop entries, package-manager output, running processes, and existing usage metadata: Spotlight last-used dates, XDG recently-used files, preference timestamps, and shell history.

History parsing extracts recognized command names and usage times. Raw history lines are read to parse them, but arguments and complete command lines are not stored in the scan cache or exported. The in-memory history index keeps tool names, last-seen times, and the oldest timestamp used to estimate the history span.

Disk Usage walks the selected root; the Linux UI can also start at `/` or a mounted network folder. Directory symlinks are not followed, and walks stay on one filesystem unless requested otherwise. Other scans may read beyond home, including system app directories and absolute XDG overrides.

## What stays on disk

| File | Contents and retention |
|---|---|
| `last-scan.json` | Scan results, including app/leftover paths, versions, sizes, and usage metadata. Replaced by a cacheable scan, invalidated after actions, or removed by `appattic erase`. Entries older than 24 hours are not reused; expiry removal happens when the cache is checked, not on a background timer. |
| `settings.json` | `confirmDelete`, `includeSystem`, and ignored leftover paths. Kept until changed or removed. |
| `settings.json.bak` | Previous differing settings bytes, when the backup succeeds. Unchanged saves preserve the older backup. |
| `settings.json.bad` | Readable, nonempty differing settings bytes preserved before a restore. Kept until a later restore replaces them. |
| Temporary scripts and stderr files | Action commands and error output. Removed after the run, including ordinary failure; a crash or cleanup failure can leave them behind. |
| Files you export with `--json FILE` | Command results at the path you choose. AppAttic does not expire or erase these copies. |

State lives in `$XDG_DATA_HOME/appattic` on Linux (normally `~/.local/share/appattic`) and `~/Library/Application Support/AppAttic` on macOS. Flatpak redirects its data home into its app-specific area. `appattic config` prints resolved paths when settings load successfully.

The Swift CLI and macOS UI reuse the scan snapshot. The Linux Qt UI scans live and invalidates the shared snapshot after actions; it does not save its own scan cache.

Private files are written with owner-only permissions: state and exports use `0600`, while Qt action scripts also receive owner execute permission (`0700`). AppAttic's state directory is restricted to `0700`. Swift uses private temporary files and rename; Qt uses `QSaveFile` for settings and `QTemporaryFile` for scripts. These permissions do not prevent access by another process running as you, root, or your backup software.

The Linux UI migrates a legacy `QSettings` file, restricts its permissions, and deletes it after a successful migration. A failed migration can leave that additional copy of ignored paths.

## What reaches the network

- Homebrew and installed package managers can contact their configured services or mirrors for metadata. Queries differ by platform; for example, pacman uses `-Qu`, not an index-refreshing `-Sy` scan.
- On macOS, the App Store check sends track IDs and, for fallback lookups, bundle IDs of apps carrying App Store receipts to `https://itunes.apple.com/lookup`. Those identifiers reveal which apps are being checked. This is a direct HTTPS request from AppAttic.
- The Linux container plugin queries Podman when available, otherwise Docker: one engine per scan. Whether that reaches a local or remote engine depends on the tool's configuration.
- Requested upgrades and removals invoke the relevant tools, which may contact their services according to their own configuration.

Remote services can see the connection's IP address and request metadata. AppAttic does not upload the complete scan or shell history to a project server. Under Flatpak, package queries and action scripts run on the host through `flatpak-spawn --host`.

## Sharing output

Diagnostic and subprocess text uses home-path replacement where implemented, including NFC/NFD spellings. This does not remove every identifying path or value. Scan reports and JSON exports can contain real paths, package names, versions, and usage times.

`appattic config` deliberately prints full state paths, every ignored path, and relevant environment values without home-path redaction. Review all output before attaching it to a public issue. Debug Qt screenshot mode also captures the displayed data without redaction.

## Viewing and removing retained data

Use `--json FILE` on scan commands to export the scan, or on `disk`, `config`, `erase`, and `restore` for their command-specific results. `schema` prints the CLI specification instead.

`appattic erase` removes only `last-scan.json`, without a prompt and before settings are loaded. It leaves settings, backups, legacy settings, exports, and any surviving temporary files. `--fresh` bypasses cache reuse but still writes a new cacheable scan; it is not a no-storage mode. Erase after a scan if you do not want that snapshot retained.

To remove settings too, close the UI and remove the state directory after copying any ignore list you want to keep. Later settings changes or scans can recreate state. Remove exports and external backup copies separately. Deleting local files does not remove filesystem snapshots or backups, and AppAttic cannot recover the contents of files its cleanup scripts deleted.

See [state recovery](runbooks/state-recovery.md) for restoring settings, and the [threat model](THREAT_MODEL.md) for execution and access risks.
