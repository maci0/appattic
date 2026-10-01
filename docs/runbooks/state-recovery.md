# Recovering AppAttic state

AppAttic runs on the user's machine, as the user, with no account and no
server. There is nothing to fail over and no remote copy of anything. This
page is the record of what the app keeps, what is worth keeping, and what to
do when a file is lost, emptied, or mangled, so the answer is in the repository
rather than in someone's head.

## What state exists

| File | Contents | Rebuildable | How it is protected |
|------|----------|-------------|---------------------|
| `<data dir>/settings.json` | `confirmDelete`, `includeSystem`, and the leftover paths the user chose to ignore | No. The ignore list is paths the user typed, and no scan can recover them | Written whole and flushed before the save reports success: the scanner and the CLI through `mkstemp` at `0600`, `fsync`, `rename`, and a parent-directory `fsync`; the Linux window through `QSaveFile` at `0600`, `rename`, and the same two `fsync` calls in `writeDurableFile`. The file it replaces is kept as `settings.json.bak` |
| `<data dir>/settings.json.bak` | The last settings file the app wrote that differs from the current one, kept by `saveSettings` and by the Linux window's `persistSettings` | It is a copy of the above, one change older. A save that changed nothing leaves it alone, so a repeated save cannot overwrite it with a copy of the current file | Written the same owner-only way, never read at run time |
| `<data dir>/settings.json.bad` | The settings file a restore replaced, kept by `restoreSettingsBackup` so a restore that turns out to be the wrong one is not a second loss | It is a copy of whatever was in `settings.json` before the restore, so it is one restore older | Written the same owner-only way, never read at run time |
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

   `settings file:`, `settings backup:`, and `settings replaced by a
   restore:` name all three paths, and each says `(missing)` when there
   is nothing to restore from. `config` loads
   `settings.json` first, so on a machine whose settings file no longer parses
   it exits 2 and prints nothing: the paths are then the defaults above,
   `~/.local/share/appattic/` on Linux and
   `~/Library/Application Support/AppAttic/` on macOS.

2. **In the window: press "Restore settings from backup"**, on the Settings
   page under Ignored leftovers. It is the checked restore: the backup is read
   with the same loader the window reads settings with, and nothing on disk
   changes if the backup does not read. The macOS window offers the same button
   on its settings error screen, which is where a settings file that does not
   parse leaves you. The button is disabled, with the reason on its tooltip,
   when there is no backup.

   By hand, if the window is not what you have, the same restore is three
   steps. The check comes first, because a copy overwrites the file it replaces
   and cannot tell a backup that still reads from one that was truncated by a
   failing disk: on a machine whose settings file is already unreadable it can
   trade a file you can still read by hand for one you cannot.

   `appattic config` is the check, but it reads `settings.json` first and so
   exits 2 on exactly the machine that needs it. Point it at the backup instead,
   which touches nothing:

   ```bash
   mkdir -p /tmp/check/appattic
   cp ~/.local/share/appattic/settings.json.bak /tmp/check/appattic/settings.json
   XDG_DATA_HOME=/tmp/check appattic config
   rm -rf /tmp/check
   ```

   The path under `XDG_DATA_HOME` is `appattic/settings.json`, which is why the
   copy goes there and not at the root. A config block means the backup is a
   file the app will read. Any error, or an exit code other than 0, means it is
   not: the three cases below.

   - **The backup reads as settings.** Copy it in, but keep what was there
     first, so a restore that turns out to be the wrong state is not a second
     loss on a machine that already lost the first:

     ```bash
     d=~/.local/share/appattic
     cp "$d/settings.json" "$d/settings.json.bad" 2>/dev/null || true
     cp "$d/settings.json.bak" "$d/settings.json"
     ```

     macOS: the same directory under `~/Library/Application Support/AppAttic`.
     Then `appattic config` again: the file it prints is the one the app will
     read, and it reports the file values it found.

   - **The backup does not.** Stop. It was written by the same durable write as
     `settings.json`, so a backup that is truncated or emptied means the disk
     was already failing, and putting it over the only other copy loses the
     state for good. Nothing has been changed on disk. Copy
     `settings.json.bak` aside and leave it where it is until the disk is
     healthy.

   - **There is no backup**, but `settings.json.bad` is there from an earlier
     restore: the same two commands with `.bad` in place of `.bak`, and move
     the current file aside as `settings.json.bak` rather than `.bad`, so the
     one-generation chain still holds.

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
- No version history. `settings.json.bak` is one change old, on purpose:
  it holds the account's own paths, and a second copy of those is already the
  standing state. Anything older would be more of the same, unread by anything.
  It is not rewritten by a save that changed nothing, so saving the same
  settings again leaves the earlier state in place instead of replacing it
  with a copy of the file that is already there.
- No backup of a file's contents. AppAttic reports paths and sizes; it does
  not store what is in them, so a deleted file is not recoverable from it.
- A crash between the write of the new settings and the copy that keeps the
  old one leaves the new settings in place and the backup one generation
  further back. A file is written whole or not at all: the Swift scanner and
  the CLI go through `mkstemp`, `fsync`, `rename`, and a directory `fsync`
  after the rename, and the Linux window does the same through `QSaveFile` and
  `writeDurableFile`, so a crash cannot leave a file that is half of one
  generation and half of the next, and neither shell reports a save that is
  only in the page cache. A file that cannot be made durable is removed rather
  than published: the save is reported as failed, and what is left on disk is
  the copy the write took of the state it replaced, which is
  `settings.json.bak`.
