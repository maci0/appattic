# What AppAttic reads, stores, and sends

AppAttic is a local tool. It runs as the user, reads that user's own files, and
has no account, no server, and no analytics. This page is the record of what it
touches, so the answer to "where did my data go" is in the repository instead of
in a support answer.

## Nothing is collected about you

There is no telemetry, no crash reporting, no analytics SDK, no user ID, and no
third-party script. Nothing about a scan leaves the machine unless the scan runs
a network command, which is listed under "What reaches the network" below.

## What a scan reads

A scan reads the file tree and the metadata the operating system already keeps:

- Directory entries under the scan roots: names, sizes, mtimes, symlink targets,
  permissions.
- Installed software: `/Applications`, `~/Applications`, the XDG `.desktop`
  entries, and what `brew`, `flatpak`, `snap`, `apt`, `pacman`, `aur`, `dnf`,
  `zypper`, and `mas` report.
- Running processes, to tell software in use from software that is not.
- Usage metadata that already exists on the machine: Spotlight last-used dates
  (macOS), `~/.local/share/recently-used.xbel` (XDG), preferences mtimes, and
  the shell history files `~/.zsh_history`, `~/.bash_history`, `~/.histfile`,
  and the fish history files.

The shell history is read for the first word of each command and nothing else.
The command line, its arguments, the working directory, and the timestamps of
commands that name no tool the scan knows are not kept, not cached, and not
exported. What a history read leaves in memory is a `HistoryIndex`: lowercased
tool names, the last time each was seen, and the oldest timestamp in the file.

`Disk Usage` walks only the tree you name (home by default) and reads the same
fields. Directory symlinks are not followed, and other file systems are not
descended into unless you ask for them.

## What is stored on disk

| Path | Contents | Mode | Kept |
|------|----------|------|-------|
| `<data dir>/last-scan.json` | The whole scan result: every app path and leftover path under the home directory | `0600`, in a `0700` directory | Until the next scan, until a run that removes or updates something, or `appattic erase`; a snapshot older than 24 hours is deleted and never served |
| `<data dir>/settings.json` | `confirmDelete`, `includeSystem`, and the leftover paths you chose to ignore | `0600`, in a `0700` directory | Until you change it |
| `<data dir>/settings.json.bak` | The settings file from before the last change, kept so an emptied or mangled `settings.json` can be put back | `0600`, in a `0700` directory | Until a settings change that differs from the current file. A save that changed nothing leaves it as it was. Nothing reads it while the app runs; `docs/runbooks/state-recovery.md` is what says how to use it |
| `<data dir>/settings.json.bad` | The settings file a restore replaced, kept so a restore that turns out to be the wrong one can be undone. Written by `appattic restore` and by either window when "Restore settings from backup" puts the backup back | `0600`, in a `0700` directory | Until the next restore that changes the file again. A restore that changed nothing leaves it as it was. Nothing reads it while the app runs |
| `$TMPDIR/appattic-script-*.sh`, `*.err` | The generated cleanup or update script and the tail of its stderr | `0600` | Deleted when the run ends, including when it fails |

`<data dir>` is `$XDG_DATA_HOME/appattic` on Linux (usually
`~/.local/share/appattic`) and `~/Library/Application Support/AppAttic` on
macOS. `appattic config` prints the resolved path on this machine.

No file is written at the umask default: every private file is created through
`mkstemp` and renamed into place, so there is no window in which another local
account can read it. The Qt window narrows a legacy `QSettings` file the same
way when it carries the old ignore list over, and deletes that file once the
list is in `settings.json`; a migration that could not be written keeps it,
because then it is the only copy of those paths.

## What leaves the machine

Only the package-manager and store lookups a scan already needs, and each sends
identifiers of packages, not of you:

- `brew outdated`, `brew info`, and Homebrew's own API, reached by Homebrew.
- `flatpak remote-ls`, `snap refresh --list`, `apt-get -s upgrade`, `pacman -Sy`,
  AUR helpers, `dnf`, and `zypper`: the package index of the distribution's own
  mirrors.
- The App Store check: App Store track IDs and bundle IDs, to Apple's iTunes
  lookup API. Which apps you have installed is not sent; the identifiers of the
  ones that carry an App Store receipt are.
- `docker` and `podman`, when installed, for the containers and images list. The
  Linux window runs these; the CLI and the macOS window have no container scan,
  so on those the list is empty. Under Flatpak the query goes to the host
  engine through `flatpak-spawn --host`.

AppAttic opens no socket of its own. The lookups above are the ones the
installed tools make, and the check that reaches Apple runs only for apps
carrying an App Store receipt.

## Error text and paths

Errors, warnings, and progress lines are written to stderr with the account's
home directory rewritten to `~/` (`redactHomePaths` in `Paths.swift`, and
`redactHomePaths` in `ui/linux-qt/finding.cpp` for the Linux window). The
subprocess output the CLI and both windows show is redacted the same way, in both
NFC and NFD spellings. `appattic config` is the one command that prints real
paths, unredacted, because its job is to name the files to edit.

## Your data, on request

- See it: every command takes `--json FILE` and writes its result there, mode
  `0600`, at a path you name. The scan commands write the whole scan; `disk`
  writes the disk tree; `config`, `erase`, and `restore` write what that command reported.
- Erase it: `appattic erase` deletes the stored scan snapshot whatever its age,
  without reading it first. It runs before settings are loaded, so it works on
  a machine whose `settings.json` no longer parses. The scan snapshot is the
  only copy AppAttic keeps of the paths a scan found; `settings.json` and its
  backup hold the paths you typed, and `appattic erase` leaves both alone
  because they are yours to edit.
- Stop keeping it: delete `<data dir>` and use `--fresh`; a scan with no snapshot
  to serve rescans and writes a new one, so pair it with `appattic erase`. The
  settings backup goes with the directory, so copy
  `<data dir>/settings.json.bak` (and `<data dir>/settings.json.bad`, if a
  restore left one) somewhere first if the ignore list matters.
- Keep your ignore list: `settings.json` is yours, and its entries are the only
  paths you typed. Edit or delete the file; AppAttic does not rewrite it behind
  your back. A file that no longer loads is not repaired or overwritten,
  `settings.json.bak` holds the state before the last change that differed, and
  `settings.json.bad` holds the state a restore replaced. `appattic erase`
  removes none of the three: it takes the scan snapshot and nothing else.

## Deletion is a local action

Deleting a file does not reach backups or a snapshot you took of the disk. The
snapshot only ever held paths and sizes, not file contents, so the exposure of
losing the machine's backup history is small, but it is the one thing this
document cannot do for you.
