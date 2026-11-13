# Recovering AppAttic state

AppAttic has no server-side copy of your state or deleted file contents. Close the UI before repairing files so it cannot save over your changes.

## Locate the files

State normally lives in:

- Linux: `$XDG_DATA_HOME/appattic`, or `~/.local/share/appattic` when unset.
- macOS: `~/Library/Application Support/AppAttic`.
- Flatpak: its redirected app-specific data home; run recovery tools in the same environment to address the same state.

`appattic config` prints resolved settings/cache paths and backup availability. It loads settings first, so malformed settings cause exit 2 instead of a config report. In that case, use the locations above, including any XDG override you set.

| File | Recovery value |
|---|---|
| `settings.json` | Confirmation/system toggles and ignored paths. A scan cannot reconstruct your ignore choices. |
| `settings.json.bak` | Previous differing settings bytes, if backup creation succeeded. Repeated unchanged saves leave it alone. |
| `settings.json.bad` | Readable, nonempty differing bytes replaced by a settings restore. May contain invalid JSON. |
| `last-scan.json` | Rebuildable scan snapshot. The Qt UI does not persist its own scan snapshot. |

The Linux UI deletes its legacy `QSettings` file only after migration succeeds. Preserve a surviving legacy file if it might hold the only copy of your ignore list.

## Restore settings from the backup

```bash
appattic restore
```

This command runs before settings load, so broken `settings.json` does not prevent recovery. It validates `settings.json.bak` with the settings loader before writing anything. A missing or invalid backup exits 1 without replacing settings. A readable, nonempty current file that differs from the restored settings is saved as `settings.json.bad` first. Existing `.bad` recovery material can be overwritten: copy it elsewhere first if you need it.

Both UIs offer **Restore settings from backup** in Settings; the macOS settings-error screen also offers it. These use the same validation and preservation rules in their respective implementations. `--json FILE` on the CLI exports the restore result, including real paths and restored values.

After restoring, run `appattic config` and check the ignore list and confirmation setting before cleaning anything.

## If the backup is missing or invalid

Preserve the surviving files before editing. A malformed backup does not by itself establish disk failure: it may have been edited or damaged in another way. Keep it for inspection rather than overwriting the only other copy.

If `settings.json.bad` holds the wanted values, inspect it and copy only valid settings into `settings.json`. Do not assume `.bad` is parseable; it exists precisely to preserve replaced bytes. To reset to defaults, replace settings with `{}` after keeping a copy of the old file. Defaults enable confirmation, exclude system entries, and use an empty ignore list.

The loader rejects an empty file, unknown keys, wrong types, and ignored paths that are not normalized absolute paths. A minimal settings file is:

```json
{
  "confirmDelete": true,
  "includeSystem": false,
  "ignoredLeftoverPaths": []
}
```

Keep repaired settings owner-only (`chmod 600` on the file and `chmod 700` on AppAttic's state directory). Run `appattic config` to validate the result. If it still fails, preserve the error and files for diagnosis; do not run cleanup while the ignore list is uncertain.

## Rebuild the scan snapshot

```bash
appattic erase
appattic report
```

`erase` removes only the fixed scan-cache file without reading it or loading settings. The report still needs valid settings. `--fresh` skips cache reuse and may write a replacement; it does not disable storage. The Qt UI always scans live.

## Recovery limits

- The settings backup is one previous change, stored beside the current file. It is not protection against disk loss. Swift treats backup creation as best effort, so a successful settings save does not guarantee a new backup exists.
- Swift writes private temporary files, syncs file contents, and renames them into place. Qt uses `QSaveFile`, then syncs the committed file; on a reported sync failure it attempts to remove that file. Both attempt directory sync without propagating its failure. These mechanisms reduce torn writes but do not guarantee survival of every filesystem or power failure.
- AppAttic has no transaction spanning settings and backup files. A failure can leave generations out of step. Check which copies exist rather than assuming the latest save or restore completed.
- Cleanup scripts do not back up deleted contents or roll back partial package operations. Recover user data from your own backups. Disk-page Trash recovery depends on the desktop and filesystem; verify the item is present there before relying on it.
- Temporary action scripts are not a durable audit trail. Crashes or failed cleanup can leave them on disk; see [privacy](../privacy.md) for retention and disclosure.
