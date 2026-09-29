# Recovering AppAttic state

AppAttic runs on the user's machine, as the user, with no account and no
server. There is nothing to fail over and no remote copy of anything. This
page is the record of what the app keeps, what is worth keeping, and what to
do when a file is lost, emptied, or mangled, so the answer is in the repository
rather than in someone's head.

## What state exists

| File | Contents | Rebuildable | How it is protected |
|------|----------|-------------|---------------------|
| `<data dir>/settings.json` | `confirmDelete`, `includeSystem`, and the leftover paths the user chose to ignore | No. The ignore list is paths the user typed, and no scan can recover them | Written whole: the scanner and the CLI through `mkstemp` at `0600`, `fsync`, `rename`, and a parent-directory `fsync`; the Linux window through `QSaveFile`. The file it replaces is kept as `settings.json.bak` |
| `<data dir>/settings.json.bak` | The last settings file the app wrote, kept by `saveSettings` and by the Linux window's `persistSettings` | It is itself a copy of the above, one save older | Written the same owner-only way, never read at run time |
| `<data dir>/last-scan.json` | The whole last scan: every app path and leftover path under the home directory | Yes. A rescan rebuilds it, at the cost of one run | Written the same way. Deleted when it is stale, after a run that changes the machine, and by `appattic erase` |
| `$TMPDIR/appattic-script-*.sh`, `*.err` | A generated cleanup or update script and the tail of its stderr | Yes, the run regenerates it | `0600`, removed when the run ends, including when it fails |

`<data dir>` is `$XDG_DATA_HOME/appattic` on Linux (usually
`~/.local/share/appattic`) and `~/Library/Application Support/AppAttic` on
macOS. `appattic config` prints the resolved paths and says whether the backup
is there.

The Qt window on Linux keeps no scan snapshot of its own: it scans live and
deletes the shared `last-scan.json` after a run that removes files or changes
package state. The legacy `QSettings` file it migrates from is deleted only
after the values are in `settings.json`, so a migration that could not be
written leaves the old file as the only copy of those paths.

## RPO and RTO

- `settings.json`: RPO is one save. A change the app has written is on disk
  before the window reports it. RTO is one `cp`.
- `last-scan.json`: RPO is one scan. It is a cache, so losing it costs a rescan
  and nothing else. RTO is the length of one scan.
- User data (the files AppAttic reports and, on request, deletes): RPO and RTO
  are the machine's own backup's, not AppAttic's. AppAttic keeps no copy of any
  file's contents, and cannot recover a deleted one. Disk Usage moves to Trash
  rather than unlinking, so that path has the trash as its undo window; the
  cleanup scripts `rm` what the user confirms after reading them.

## Restoring settings

1. Find the files:

   ```bash
   appattic config
   ```

   `settings file:` and `settings backup:` name both paths, and the backup line
   says `(missing)` when there is nothing to restore from. `config` loads
   `settings.json` first, so on a machine whose settings file no longer parses
   it exits 2 and prints nothing: the paths are then the defaults above,
   `~/.local/share/appattic/` on Linux and
   `~/Library/Application Support/AppAttic/` on macOS.

2. If the backup is there, put it back:

   ```bash
   cp ~/.local/share/appattic/settings.json.bak ~/.local/share/appattic/settings.json
   ```

   macOS: the same two paths under `~/Library/Application Support/AppAttic`.
   Then `appattic config` again: the file it prints is the one the app will
   read, and it reports the file values it found.

3. If the backup is missing, the settings file has been saved once, or the
   copy of the earlier one did not land. Recreate it by hand: a file holding
   `{}` is valid and means defaults, and
   `ignoredLeftoverPaths` takes absolute paths, the ones a report prints. An
   empty file, an unknown key, a wrong type, a relative path, or a trailing
   slash is refused by the loader with the reason named, and the app will not
   overwrite the file until the user saves settings.

## Restoring the scan snapshot

There is nothing to restore. Delete it and rescan:

```bash
appattic erase
appattic report
```

`appattic erase` runs before settings are loaded, so it works on a machine
whose `settings.json` no longer parses. `--fresh` on any scan command ignores
the snapshot without deleting it.

## What is deliberately not protected

- No remote copy of any of it. Nothing here leaves the machine, so nothing can
  be restored from anywhere but this disk and the user's own backups.
- No version history. `settings.json.bak` is one generation old, on purpose:
  it holds the account's own paths, and a second copy of those is already the
  standing state. Anything older would be more of the same, unread by anything.
- No backup of a file's contents. AppAttic reports paths and sizes; it does
  not store what is in them, so a deleted file is not recoverable from it.
- A crash between the write of the new settings and the copy that keeps the
  old one leaves the new settings in place and the backup one generation
  further back. A file is written whole or not at all: the Swift scanner and
  the CLI go through `mkstemp`, `fsync`, `rename`, and a directory `fsync`
  after the rename, so a crash cannot leave a file that is half of one
  generation and half of the next. The Linux window writes through
  `QSaveFile`, which replaces by rename but leaves the flush to Qt.
