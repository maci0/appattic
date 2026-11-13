# TMOG design language

Source: Dave Plummer, Dave's Attic, [Shop Talk #91](https://www.youtube.com/watch?v=c3EEs-O3bGE). Notes: [`docs/research/tmog-shoptalk-91-patterns.md`](research/tmog-shoptalk-91-patterns.md). Site copy on [tmog.org](https://tmog.org) uses the same language: native per OS, summary first, system light and dark, plus optional phosphor schemes.

This is the design language of Task Manager OG as Dave walked it in that episode. AppAttic takes the list and tree patterns. It does not take VFD meters, bloom, or saturation-11 chrome. The mapping is in [AppAttic adoption](#appattic-adoption).

## Intent

Dave's brief for the 1994 Task Manager was Unix `ps` and `top` on NT: a clean view of what is running, then verbs (end task, services). TMOG is that idea on current hardware: a couple percent of CPU, a reasonable amount of memory, the depth of Task Manager, and the clarity of Activity Monitor.

He described the look as his own specification, box by box and color by color, written as a cockpit.

## Principles

1. **Native per OS.** Direct2D and Direct Composition on Windows, UIKit on Mac, Qt on Linux. One shared C++ core in TMOG. OS helpers only where the platform API differs (process list, Mac-only metrics). Fit the chrome to the system.
2. **Summary first.** Open on one page that shows the machine. Graphs and top processes on that page were the strongest response he named.
3. **Depth is one click away.** Performance, processes, system info, startup, users, services, installed apps, disk. Same window.
4. **Keep the control when the number is missing.** The clock meter stays. On the Mac he showed, it reads as automatic because the OS owns frequency.
5. **Act on a tree or on one node.** Kill the parent (everything that parent started) or kill one window.
6. **Installed software is a table with a verb.** Sort by size. Uninstall sits on the table.
7. **Combine or split.** Disks and NICs can be one graph or every device. The default is the unified view.
8. **Applications and background are separate lists.** Same process-table language, two groups.
9. **Cheap to run.** A couple percent of CPU. History stays on screen by compressing older time, keeping the live edge.
10. **Personal chrome is a setting.** Intense color is his taste. The default follows the system. Saturation, bloom, and phosphor schemes are optional.

## Appearance

### Modes

Default follows system settings (Mac light or dark). An explicit light mode exists for people who do not want dark mode.

Optional palettes, his cockpit and not OS chrome:

| Scheme | Role |
|--------|------|
| Color | Default saturated cockpit |
| Mono | No hue |
| Green | Classic green phosphor |
| Amber | Classic amber phosphor |
| Blue | Midnight blue, matching the Visual Studio theme he uses |

Saturation is a slider. Seven is the default. His own setting goes to 11. Bloom is a separate toggle: off leaves crisp high-saturation lines, and bloom dims as saturation drops. Past seven, bloom shows.

AppAttic ships neither phosphor, bloom, nor a saturation slider. System light and dark only.

### Graph color roles (TMOG default scheme)

From the summary CPU overview he walked:

- Green: user CPU
- Red: kernel
- Orange: thermals

Rows that change get a green fill that fades. Live tables flash. They do not stay highlighted.

### Type and meters

A VFD (vacuum fluorescent) digit font draws live scores. Unlit segments stay as a grid so a dark digit still shows its place. Meter bars are hand-drawn rectangles with bloom inside and outside.

White trackers on the right of each small graph follow the original Star Trek sickbay heart-rate meters. He said he took that on purpose.

History graphs compress time toward the left (log2-style, adjustable in settings) so a long history fits while the right edge still scrolls quickly.

### Motion

- Green row flash on a list change, then a fade
- Graph scroll at display cadence
- Bloom as an optional glow
- Disk "balls" can be dragged. The block view fills like old defrag. Both are the disk page, not the software table

## Information architecture

Boot page: **Summary**. Meters for CPU, clock, temperature, GPU, then memory, disks, network, energy, GPU, NPU, thermals, plus the top processes that fit the window.

Then pages, not a web tab strip:

- Performance (one CPU graph, or a per-core split)
- GPU / NPU (he called the NPU data coarse: it jumps between a few levels)
- Disks (combine or split)
- Network (same combine or split)
- Thermals (scroll die sensors; relative share, such as Task Manager against Chrome)
- Processes (tree, apps vs background)
- System info (a slow fill is expected; he said it can take a minute)
- Startup apps (a checkbox disables an entry)
- Users (who runs what, with a jump to the process)
- Services (start, stop, kill)
- Installed apps (size sort, uninstall)
- Disk space (balls or block view)

Inspecting a process shows sockets, open files, and related detail.

Features he named as getting a response: blinking disk, palettes, block view, tear-off panels, long history, and especially the front summary as one view.

## Lists and trees

The process list should feel like a task manager, then add the tree. A parent action fans out. A child action is one node. The user should be able to tell whether End Task kills the family.

Startup is a checkbox list.

System info can fill in after the page is open. The page stays while data arrives.

## Installed software

One table. The question is what uses space. Sort by app size. Uninstall from the table.

Disk visualization is a second mode of the disk page (circle packing, then defrag blocks). It is not the installed-apps UI.

A portable `.exe` that you just run is not an installed application. Native installers and store packages are.

## Platform

Same job on each OS. Helpers differ:

- Process enumeration differs on Windows, Mac, and Linux
- Some meters cannot be filled (Mac clock rate)
- Distro package tools differ (pacman vs apt). The job is still "install the compiler and git"

He named the Windows build as Direct2D, Mac as Swift UIKit, and Linux as Qt. The Windows binary is portable, with no forced installer. Linux packaging follows the distro. He compiled on Arch after Debian.

## What not to copy

He called these personal taste in the episode:

- Saturation 11
- Visual bloom
- VFD font and the unlit-segment grid
- Sickbay side meters
- Phosphor green, amber, blue, or mono as the product identity
- Draggable disk balls as the way to manage software

Keep, from TMOG: a native toolkit, summary then depth, tree verbs, a size-sorted installed list, missing values still on screen, and system appearance as the default.

## AppAttic adoption

AppAttic does not share TMOG's one C++ core. Two scan stacks ship:

| Surface | UI | Scan |
|---------|----|------|
| macOS | SwiftCrossUI on AppKit (`Sources/AppAttic`) | Swift `AppAtticScan` |
| Linux | C++ Qt 6 Widgets (`ui/linux-qt`) | Zig WASM plugins through `core/host/embed.c` |
| Windows | None. WinUI via SwiftCrossUI is not a target in `Package.swift` | None |

| TMOG language | AppAttic |
|---------------|----------|
| Summary, then pages | Overview, then Leftovers, Stale Apps, Outdated, Packages, Disk Usage, Settings |
| Process tree: parent or one node | Package tree: remove unused deps with the parent, or one selected row |
| Installed apps: sort by size, uninstall | Packages: size column. Remove and mark-manual go through a reviewed `sh` script |
| Apps vs background | Orphan (distro auto, including dpkg `rc` remnants) vs Global (npm/pnpm/bun `-g`, top-level pip user-site, pipx, uv tool, Deno `~/.deno/bin`) |
| Checkbox keep/disable | Mark as manually installed, for apt, pacman, dnf, and zypper |
| Inspect sockets and files | Inspector: path, why, size, manager |
| Missing meter stays | An absent manager leaves its copy empty. The sidebar item stays. The Linux Installed instrument reads "Not scanned" (`linuxInstalledInstrumentText`) |
| pacman vs apt | One plugin per manager on Linux. The same families are parsed again in Swift for the CLI and the macOS UI |
| System light/dark | System appearance only |
| One status palette | Remove, review, and keep use the same three colors in the AppKit window (`Theme.swift`), the Qt window (`toneFrom` in `ui/linux-qt/main.cpp`), and the CLI (`CliTone` in `CLIParse.swift`). Light: `#c01c28`, `#9e6600`, `#1c6e30`. Dark: `#ff453a`, `#ffd60a`, `#30d158`. The CLI reads `COLORFGBG` and falls back to the light set |
| VFD, bloom, phosphor | Not used. Density follows Finder, Activity Monitor, and GNOME Settings |
| Uninstall in one gesture | Delete, package remove, mark-manual, and package update ask first when `confirmDelete` is on. The setting defaults to on and can be turned off in Settings, on both the AppKit window and the Qt window. Off runs the reviewed script without the alert. Disk Usage "Move to Trash" still asks in its own alert |

Product language is leftovers, stale, outdated, and packages.
