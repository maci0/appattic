---
name: AppAttic
description: Native cleanup utility for leftovers, unused apps, and outdated packages
colors:
  bg: "#ffffff"
  chrome: "#e6e6e6"
  text: "#1f1f1f"
  dim: "#525252"
  blue: "#0a84ff"
  red: "#ff453a"
  yellow: "#ffd60a"
  green: "#30d158"
typography:
  body:
    fontFamily: "system-ui, -apple-system, sans-serif"
    fontSize: "13px"
    fontWeight: 400
    lineHeight: 1.35
  title:
    fontFamily: "system-ui, -apple-system, sans-serif"
    fontSize: "13px"
    fontWeight: 700
    lineHeight: 1.2
  label:
    fontFamily: "system-ui, -apple-system, sans-serif"
    fontSize: "11px"
    fontWeight: 400
    lineHeight: 1.2
rounded:
  sm: "4px"
  md: "6px"
spacing:
  sm: "8px"
  md: "12px"
  lg: "16px"
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

AppAttic is a native utility (Finder / Activity Monitor / GNOME Settings density), not a web dashboard. Same design principles as [TMOG](https://tmog.org), documented from Dave Plummer's Dave's Attic walkthrough in [`docs/tmog-design-language.md`](docs/tmog-design-language.md) ([Shop Talk #91](https://www.youtube.com/watch?v=c3EEs-O3bGE)). Native chrome on each OS, one shared core, system-specific helpers, summary first then deeper lists, tree actions on a parent or one child, installed software sortable by size with uninstall as a first-class verb. Missing platform data stays on screen (empty or "unknown"), it is not hidden. Phosphor / VFD / saturation-11 is Dave's personal chrome, not AppAttic.

Software stack follows that native-per-OS split. macOS: SwiftCrossUI `DefaultBackend` (AppKit) in `src/macos`. Windows: WinUI via SwiftCrossUI if present. Linux: Native Zig application in `src/linux` sharing the Zig core & WASM plugin engine (`src/core`). Shared core: `src/core` with `src/core/scan` Foundation engine and Zig WASM core loader + plugins in `src/core/src` & `src/core/plugins`. Native code keeps windows, lists, inspector, buttons, and system alerts. Current tree still ships `AppAtticScan` in Swift until that port lands. Direction: [`docs/superpowers/specs/2026-08-26-zig-wasm-core-design.md`](docs/superpowers/specs/2026-08-26-zig-wasm-core-design.md). Build on the distro you run (Arch, Fedora, Debian/Ubuntu, openSUSE). An Ubuntu-built binary is not assumed to start on Arch. Pacman vs apt is the same job through different plugins.

Brand is the product language (leftovers, stale, outdated), not a split wordmark or GitHub-canvas chrome.

## Colors

List and inspector fill is white in light mode, `#1e1e1e` in dark mode. Sidebar has no solid fill: AppKit uses the split-view sidebar material, Qt uses a source-list `QListWidget`. Status bar uses window chrome gray. Secondary text is darker gray in light mode (`Color(white: 0.32)`) so 11pt counts stay readable on white and on the sidebar material.

Interactive accent is system blue. Status: system red (orphaned / REMOVE), amber (REVIEW / outdated version; darker than system yellow in light mode), green (KEEP). Never use color alone. Rows keep a text status.

## Typography

Platform UI stack. 13pt body, 13pt bold section titles, 11pt secondary columns (kind, location, modified, size). No marketing display face. No oversized metric numerals.

## Layout

`NavigationSplitView`: source-list sidebar (min width ~220) plus detail. Detail is a compact toolbar of tools (search, Select All, Rescan), then content, then a Finder-style status bar when something is checked. The page name lives in the sidebar, not as a second title in the toolbar. Content insets ~16.

Sidebar items: Overview, Leftovers, Stale Apps, Outdated, Packages, Settings.

Lists are compact table-style rows with a header and secondary columns, sorted by size. Empty, scanning, and error states are short copy. Delete uses a system alert. Script preview is a sheet.

Packages follows TMOG installed-apps plus process tree: one dense list of installed packages, default sort by size, manager and kind columns. Kind is Orphan (distro auto, nothing still needs it) or Global (npm/pnpm/bun -g, pipx, uv tool). Filter chips or a segmented control: All, Leaves, Globals. Expand a row to see dependency children when the manager gives a tree. Remove the parent the way TMOG kills a process tree (unused deps go with it). Remove one child only when that node is selected alone. Mark as manually installed is a keep verb for apt/pacman/dnf/zypper only. Same confirm + `sh` preview as leftover cleanup. Outdated stays version skew. Packages is keep-or-drop.

Overview: compact totals (label column + value), then one scrolling pair of equal lists (largest leftovers, largest stale). Tapping a row opens that list with the item selected.

Selected list row uses system blue with on-accent (white) text, including secondary columns. Gray secondary text is not used on the selected row.

Cleanup membership is an `in` mark in the first column, plus the inspector toggle and toolbar Select All.

Do not rebuild leftover/stale/outdated lists on every scan progress tick. Progress is a status string only.

AppKit `List` selection is unreliable (re-selects the current row and can eat clicks). Sidebar and leftover/stale/outdated rows are tappable `ScrollView` rows, not selectable `List`s.

Include-in-cleanup is the inspector toggle plus toolbar Select All. Leftover inspector also has Ignore leftover, which hides that path on later scans until Settings clears the ignore list. Leftovers also lists user overlays (`~/.local/bin`, `~/bin`, `~/.cargo/bin`, `~/.local/share/applications`) that hide a same-named file from a package manager. Those rows use status `shadow` (amber), show the packaged path in the inspector, and cleanup only removes the overlay.

## Elevation & Depth

Flat native window. No GitHub card stacks. Sidebar uses the platform source-list material (AppKit NSVisualEffectView sidebar, Qt `QListWidget`). Do not paint a solid fill over it. Detail and inspector share the list fill. The selection bar is window chrome, like Finder's status bar.

## Shapes

Platform controls. No custom pills or metric cards.

## Components

### Sidebar

Tappable source-list rows (`ScrollView` + `onTapGesture`). Changing selection switches the detail pane. Do not use AppKit `List` for this sidebar.

Toolbar: tools only. Rescan always. Search on Leftovers, Stale Apps, Outdated, and Packages. Select All on leftover, stale, outdated, and packages lists (updatable Homebrew/Flatpak only on Outdated). Count of visible rows sits on the leading edge in 11pt secondary text. Scan age (cached or live) sits next to the count when a scan is not running. Destructive delete, package remove, mark-manual, and package update only after confirm when Settings says so.

### Tables / rows

Header plus name and secondary columns (location, modified, size for leftovers; status, last used, size for stale; manager, current → latest for outdated; manager, kind, size for packages). Native checkboxes are not used inside the list on AppKit. The first column shows `in` when the item is in the cleanup, update, remove, or mark-manual set.

### Alerts and sheets

Delete and Update: system alert. Script preview: sheet with copyable `sh`. Never auto-run upgrades or `rm`. Untrusted Homebrew casks are listed and are not updated.

## Do's and Don'ts

### Do

- Do keep density at native utility scale (13/11pt, compact rows).
- Do use system semantic colors with a text label.
- Do keep scan and `rm` off the main thread.
- Do pin sidebar items to the top of the pane (`Spacer` under the rows).

### Don't

- Don't revive the GitHub-dark web dashboard (metric cards, underline tabs, sticky 44px marketing header).
- Don't import AppKit-only types in SwiftCrossUI sources (no `NSImage`, no SF Symbols, no materials).
- Don't use Gtk, Electron, or a web view for the Linux UI. TMOG Linux is Qt 6. AppAttic Linux is `src/linux`.
- Don't `rm` Flatpak or Snap wrapper binaries (`/usr/bin/flatpak`, `/usr/bin/snap`). Uninstall through `flatpak uninstall` / `snap remove`.
- Don't put KEEP or system items in generated cleanup scripts.
- Don't treat outdated (newer version) as unused (stale) or as a package leaf. They are separate lists.
- Don't copy TMOG VFD meters, bloom, or saturation-11 chrome. Native system appearance only.
