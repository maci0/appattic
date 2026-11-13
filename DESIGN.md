---
name: AppAttic
description: Native cleanup utility for leftovers, unused apps, and outdated packages
colors:
  bg: "#ffffff"
  chrome: "#e6e6e6"
  darkBg: "#1e1e1e"
  darkChrome: "#2e2e2e"
  text: "#1f1f1f"
  darkText: "#f5f5f5"
  dim: "#525252"
  darkDim: "#adadad"
  hairline: "#c2c2c2"
  darkHairline: "#4c4c4c"
  blue: "#0a84ff"
  red: "#ff453a"
  yellow: "#ffd60a"
  green: "#30d158"
  greenLight: "#1c6e30"
  redLight: "#c01c28"
  yellowLight: "#9e6600"
typography:
  body:
    fontFamily: "system-ui, -apple-system, sans-serif"
    fontSize: "13px"
    fontWeight: 400
    lineHeight: 1.35
  small:
    fontFamily: "system-ui, -apple-system, sans-serif"
    fontSize: "11px"
    fontWeight: 400
    lineHeight: 1.2
  title:
    fontFamily: "system-ui, -apple-system, sans-serif"
    fontSize: "13px"
    fontWeight: 600
    lineHeight: 1.2
  label:
    fontFamily: "system-ui, -apple-system, sans-serif"
    fontSize: "11px"
    fontWeight: 600
    lineHeight: 1.2
    transform: "uppercase"
    letterSpacing: "1.15px (Qt absolute spacing; macOS uppercases only)"
  value:
    fontFamily: "system-ui, -apple-system, sans-serif"
    fontSize: "15px"
    fontWeight: 600
    lineHeight: 1.2
    fontFeature: "tnum"
  mono:
    fontFamily: "ui-monospace, SFMono-Regular, monospace"
    fontSize: "13px"
    fontWeight: 400
    lineHeight: 1.35
  display:
    fontFamily: "Michroma"
    fontSize: "body + 4pt"
    fontWeight: 400
    letterSpacing: "102% (Qt page title; Linux shell only)"
  displaySection:
    fontFamily: "Michroma"
    fontSize: "body + 2pt"
    fontWeight: 400
    letterSpacing: "102% (Qt section title; Linux shell only)"
spacing:
  tight: "2px"
  xs: "4px"
  sm: "8px"
  md: "12px"
  lg: "16px"
rounded:
  sm: "4px"
  md: "6px"
components:
  sidebar:
    textColor: "{colors.text}"
    width: "220px"
  detail:
    backgroundColor: "{colors.bg}"
    textColor: "{colors.text}"
    padding: "16px"
---

# Design System: AppAttic

## Overview

AppAttic is a native utility. Linux Qt follows the TMOG cockpit rules in [`docs/tmog-design-language.md`](docs/tmog-design-language.md): summary first, dense type, label/value/accent hierarchy, missing values stay on screen, one hue per concept, brightness on live data. Tree actions apply to a parent or to one selected child. Installed software sorts by size, and uninstall is a verb on that list. Phosphor palettes, VFD seven-segment meters, and bloom stay Dave's personal chrome.

Two scan stacks ship. They are not one shared core.

| Surface | UI | Scan |
|---------|----|------|
| macOS | SwiftCrossUI `DefaultBackend` (AppKit), `Sources/AppAttic` | Swift `AppAtticScan` |
| Linux | C++ Qt 6 Widgets, `ui/linux-qt` | Zig WASM plugins. Native code keeps windows, lists, the inspector, buttons, and system alerts |
| Windows | Not shipped. `Package.swift` has no WinUI target | None |

The Swift CLI (`appattic`) uses `AppAtticScan` and does not load the WASM core. Direction for the Linux core: [`docs/specs/2026-08-26-zig-wasm-core-design.md`](docs/specs/2026-08-26-zig-wasm-core-design.md). Build on the distro you run (Arch, Fedora, Debian/Ubuntu, openSUSE). An Ubuntu-built binary is not assumed to start on Arch. Pacman and apt are the same job through different plugins.

Brand is the product language (leftovers, stale, outdated).

## Colors

List and inspector fill is white in light mode and `#1e1e1e` in dark mode. The sidebar has no solid fill: AppKit uses the split-view sidebar material, and Qt uses a source-list `QListWidget`. The status bar uses window chrome gray. Secondary text is `Color(white: 0.32)` in light mode so 11pt counts stay readable on white and on the sidebar material. Qt secondary text is `#525252` in light mode and `#aeaeae` in dark mode (`toneFrom` in `ui/linux-qt/main.cpp`). The front-matter `darkDim` (`#adadad`) is the dark secondary token. It is one step off the Qt byte.

Interactive accent is system blue. Status colors: red for orphaned and REMOVE, amber for REVIEW, shadow, and an outdated version, green for KEEP. Rows also carry a text status.

The three status colors are the same bytes in the AppKit window (`Theme.swift`), the Qt window (`toneFrom`), and the CLI (`CliTone` in `CLIParse.swift`). Light: REMOVE `#c01c28`, REVIEW `#9e6600`, KEEP `#1c6e30`. Dark: REMOVE `#ff453a`, REVIEW `#ffd60a`, KEEP `#30d158`. Light KEEP used to be `#248a3d` in the AppKit window and the CLI (4.40:1 on white). It now matches the Qt green. `testLightTonesClearTheContrastFloor` in `tests/AppAtticScanTests/CLIParseTests.swift` measures the light CLI tones against 4.5:1 on white. The CLI reads `COLORFGBG` and falls back to the light set.

Row and pane separators are the hairline pair (`#c2c2c2`, `#4c4c4c`). `appHairline` in `Theme.swift` is `Color(white: 0.76)` and `Color(white: 0.30)`, the same bytes. `aaHairlineColor` in `uistyle.h` paints `QColor(194, 194, 194)` and `QColor(76, 76, 76)`.

The product mark (`packaging/appattic.svg`) uses dark fill `#1e1e1e`, dark chrome `#2e2e2e`, accent `#0a84ff`, KEEP `#30d158`, and REMOVE `#ff453a`.

## Typography

macOS uses 13pt body and 11pt secondary columns on the system UI face. Linux Qt uses Selawik when it is installed, otherwise Segoe UI, Segoe UI Variable, or the desktop UI font (`aaLoadAppFonts`). Page and section titles use bundled Michroma (OFL). If Michroma did not load, those titles fall back to the DemiBold application font. Instrument and inspector labels are small and uppercase. Qt also tracks labels at 1.15px absolute spacing. Values sit under those labels at body size plus two points, DemiBold, with tabular figures on sizes (Qt 6.7 and later). Paths and scripts use the desktop fixed-width font.

`TypeScale` in `Sources/AppAttic/Theme.swift` and the `aa*Font` functions in `ui/linux-qt/uistyle.h` name the same roles: body, small, title, label, value, mono. macOS sizes are fixed points (body 13, small 11, title 13, value 15). Qt derives each role from the desktop application font. `aaSmallFont` steps one point down when the application font is at least 12pt. The two display steps (`aaPageFont` at plus four points, `aaSectionFont` at plus two) exist only on Qt, with letter spacing at 102 percent. A desktop set to a large text size keeps those titles above the body text they label.

`Metrics` in `Theme.swift` and `kSpaceTight`, `kSpaceXs`, `kSpaceSm`, `kSpaceMd`, `kSpaceLg` in `uistyle.h` are one scale: 2, 4, 8, 12, 16. A gap, margin, or padding is a step on it. A wider gap, such as 32 between the settings columns, is a step times a count.

The Linux sidebar is a source list (window fill, theme icons, style-drawn rows) with Settings pinned at the bottom. The detail pane carries a Michroma page title. Toolbars are `QToolBar`.

## Layout

`NavigationSplitView`: a source-list sidebar (min width about 220, max 220) plus detail. Detail is a compact toolbar (search, Select All, Rescan), then content, then a status bar when something is checked. On macOS the page name lives in the sidebar selection. The detail toolbar holds the item count, status, search, and verbs. Linux puts the page name in the Michroma title. Content insets are 16.

Overview is one row of instruments (uppercase label, value, semantic color on leftovers), then three dense lists. The Linux Installed instrument stays "Not scanned" (`linuxInstalledInstrumentText` in `ui/linux-qt/finding.cpp`). Empty structure stays visible while a scan runs. While a scan is running and that page has no rows yet, totals read as in progress and lists show the current plugin plus N/M.

Sidebar items: Overview, Leftovers, Stale Apps, Outdated, Packages, Disk Usage, Settings. Disk Usage is a device list plus a scan view (tree, rings or treemap, allocated vs apparent, this-file-system-only). Charts are native Qt painting on Linux (`DiskChart` in `ui/linux-qt/diskchart.cpp`). Fills scale value and saturation from the window palette, the highlight color marks the selection, and each cell label uses the better of black or white. macOS shows the tree and the devices. Delete from Disk Usage is Move to Trash after its own confirm, on both shells (`DiskUsageView.swift`, `DiskPage::trashSelected`). That confirm is separate from `confirmDelete`.

Lists are compact rows with a header and secondary columns, sorted by size. Empty, scanning, and error states use short copy. The cleanup script preview is a sheet.

Packages is one dense list, default sort by size, with manager and kind columns. Kind is Orphan (distro auto, nothing still needs it, including dpkg `rc` config remnants) or Global (npm/pnpm/bun `-g`, top-level pip user-site, pipx, uv tool, Deno `~/.deno/bin`). AUR outdated uses paru, yay, or pikaur (`-Qua`). Named distro upgrades and package removes run through `pkexec` or `sudo` when the script needs root (`rootcmd` in `Cleanup.swift` and `ui/linux-qt/finding.cpp`). yum is the dnf plugin when `dnf` is missing. PPA source files under `/etc/apt/sources.list.d` show on Leftovers as review. Removing one is `rm` of that file. Filter chips (macOS) or a combo (Linux): All, Leaves, Globals. Expand a row to see dependency children when the manager gives a tree. Remove the parent and its unused deps, or remove one child when that node is selected alone. Mark as manually installed is a keep verb for apt, pacman, dnf, and zypper. Outdated stays version skew.

The selected list row uses system blue with white text, including secondary columns.

Cleanup membership is a leftover tickbox on Linux (`listMarkUsesTickbox`) and an `in` mark on the other Linux lists and on AppKit. The inspector toggle and toolbar Select All stay in sync with it.

Do not rebuild leftover, stale, or outdated lists on every scan progress tick. Progress is a status string plus a determinate N/M bar. The string names the plugin that is running.

AppKit `List` selection re-selects the current row and can eat clicks. Sidebar and leftover, stale, and outdated rows are tappable `ScrollView` rows.

The leftover inspector has Ignore leftover, which hides that path on later scans until Settings clears the ignore list. Leftovers also lists user overlays (`~/.local/bin`, `~/bin`, `~/.cargo/bin`, `~/.local/share/applications`) that hide a same-named file from a package manager. Those rows use status `shadow` (amber), show the packaged path in the inspector, and cleanup removes only the overlay.

## Confirm

`confirmDelete` defaults to on (`Settings.swift`, `ui/linux-qt/settings.h`). Settings exposes it as "Confirm before running" on macOS and the matching checkbox on Linux. On means delete, package update, and mark-manual show the alert and the script before they run. Off runs that script immediately (`requestAction` in `ContentView.swift`, `confirmDelete` in `ui/linux-qt/main.cpp`). Disk Usage Move to Trash keeps its own alert either way.

## Scan cache

The Swift CLI and the macOS UI reuse a fresh scan cache. The toolbar status reads `cached · scanned <date>` when `from_cache` is set (`Scanner.swift`). `--fresh` bypasses the cache. The Linux Qt window has no scan cache. Each open scans live, and the toolbar count is the row total for the current run.

## Elevation and depth

Flat native window. The sidebar uses the platform source-list material (AppKit sidebar material, Qt `QListWidget`). Detail and inspector share the list fill. The selection bar is window chrome, like Finder's status bar.

## Shapes

Platform controls. No custom pills or metric cards.

## Components

### Sidebar

Tappable source-list rows. Changing selection switches the detail pane. Do not use AppKit `List` for this sidebar.

Toolbar tools: Rescan always. Search on Leftovers, Stale Apps, Outdated, and Packages. Select All on leftover, stale, outdated, and packages lists (updatable Homebrew, Flatpak, apt, pacman, AUR, dnf, yum, and zypper rows on Outdated). The count of visible rows sits on the leading edge in 11pt secondary text. On macOS, when a scan is not running, the status line next to that count can show the cache age above. A running scan replaces it with the current plugin and N/M, and a compact progress bar. Empty search results say what missed and offer Clear search. Action buttons stay disabled while a scan or a script is running.

### Tables and rows

Header plus name and secondary columns: location, modified, and size for leftovers; status, last used, and size for stale; manager and current to latest for outdated; manager, kind, and size for packages. AppKit does not put a native checkbox inside the list. The first column shows `in` when the item is in the cleanup, update, remove, or mark-manual set. Linux leftovers use a native tickbox in that column.

### Alerts and sheets

When `confirmDelete` is on, Delete and Update use a system alert, and the script preview is a sheet of copyable `sh`. Nothing auto-runs an upgrade or `rm`. Homebrew casks from an untrusted tap are report-only in the Swift scan (`BrewInfo.swift` reads Homebrew's "Refusing to load cask" error and sets kind `untrusted`). The Zig `brew` plugin does not read that error, so the Linux Qt list offers those casks for update like any other. See the core spec.

## Do

- Keep density at native utility scale: macOS 13/11pt, Linux Selawik or the desktop font, Michroma titles on Linux, compact rows.
- Let the Linux Qt style draw sidebar rows, toolbars, and table headers. Overlay only the count.
- Keep missing numbers on screen (`unknown`, `Not scanned`).
- Spend color on leftover and remove (red), review, shadow, and outdated (amber), and keep (green).
- Keep scan and `rm` off the main thread.
- Pin sidebar items to the top of the pane (`Spacer` under the rows on macOS, Settings pinned under the source list on Linux).

## Don't

- Don't import AppKit-only types in SwiftCrossUI sources (`NSImage`, SF Symbols, materials).
- Don't use Gtk, Electron, or a web view for the Linux UI. Linux is `ui/linux-qt`.
- Don't `rm` Flatpak or Snap wrapper binaries (`/usr/bin/flatpak`, `/usr/bin/snap`). Uninstall through `flatpak uninstall` or `snap remove`.
- Don't put KEEP or system items in generated cleanup scripts.
- Don't treat outdated (a newer version exists) as unused (stale) or as a package leaf. They are separate lists.
- Don't copy TMOG VFD meters, bloom, or saturation-11 chrome.
