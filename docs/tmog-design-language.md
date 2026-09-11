# TMOG design language

Source: Dave Plummer, Dave's Attic, [Shop Talk #91](https://www.youtube.com/watch?v=c3EEs-O3bGE). Quote file: `docs/research/tmog-shoptalk-91-patterns.md`. Site copy on [tmog.org](https://tmog.org) matches the same language: native per OS, summary first, system light and dark plus phosphor schemes.

This is the design language of Task Manager OG as Dave walked it. AppAttic adopts the principles and list/tree patterns. It does not adopt VFD meters, bloom, or saturation-11 chrome. See [Adoption](#appattic-adoption).

## Intent

Dave's brief for the 1994 Task Manager was Unix `ps`/`top` on NT: a clean view of what is running, then verbs (end task, services). TMOG is that idea on current hardware: a couple percent of CPU, a reasonable amount of memory, the depth of Task Manager with the clarity of Activity Monitor.

The look is authored, not generated. Dave: "in terms of how it looks, that's 100% me. I didn't say vibe go to task manager. I said I want this box here and I want this color. I want round corners." Layout, color, and behavior are specified. The chrome is a cockpit, not a marketing site.

## Principles

1. **Native per OS, one product.** Direct2D / Direct Composition on Windows, UIKit on Mac, Qt on Linux. Shared core. OS helpers only where the platform API differs (process list, Mac-only metrics). Vary the chrome so it fits the system. Do not ship three unrelated apps.
2. **Summary first.** Boot to one page that shows the machine without tabbing. Graphs and top processes on that page were the strongest response.
3. **Depth is one click away.** Performance, processes, system info, startup, users, services, installed apps, disk. Same window, more surface.
4. **Show the control when the number is missing.** Clock meter stays. On that Mac it reads auto because the OS owns frequency. Do not hide the slot.
5. **Act on a tree or on one node.** Process view is a tree. Kill the parent (everything Google started) or kill one window.
6. **Installed software is a table with a verb.** Sort by size. Uninstall is first-class, not buried.
7. **Combine or split.** Disks and NICs can be one graph or every device. Default is the unified view.
8. **Applications and background are separate lists.** Same process table language, two groups.
9. **Cheap to run.** A couple percent of CPU. History stays on screen by compressing older time, not by dropping the live edge.
10. **Personal chrome is a setting.** Intense color is Dave's taste. Default follows the system. Saturation, bloom, and phosphor schemes are optional.

## Appearance

### Modes

Default: **use system settings** (Mac light or dark). Explicit light mode exists for people who are "not into dark mode."

Optional palettes (Dave's cockpit, not OS chrome):

| Scheme | Role |
|--------|------|
| Color | Default saturated cockpit |
| Mono | No hue |
| Green | Classic green phosphor |
| Amber | Classic amber phosphor |
| Blue | Midnight blue, "matches the Visual Studio theme I happen to use" |

Saturation is a slider. Seven is the default. Dave's personal setting goes to 11. Bloom is a separate toggle: off gives "really crisp high saturation lines." Bloom dims with lower saturation. Past seven, bloom shows up.

AppAttic does not ship phosphor, bloom, or a saturation slider. System light and dark only.

### Graph color roles (TMOG default scheme)

From the summary CPU overview:

- Green: user CPU
- Red: kernel
- Orange: thermals

Rows that change get a green fill that fades out. Live tables flash; they do not stay highlighted.

### Type and meters

VFD (vacuum fluorescent) digit font for live scores. Unlit segments stay as a grid "to show you when the bits aren't lit." Meter bars are hand-drawn rectangles with bloom inside and outside.

White "sick bay" trackers on the right of each small graph (original Star Trek sickbay heart-rate meters). Dave stole that on purpose.

Time in history graphs compresses toward the left (log2-style, adjustable in settings) so long history fits while the right edge still scrolls quickly.

### Motion

- Green row flash on list change, then fade
- Graph scroll at display cadence
- Bloom as optional glow, not as a required material
- Disk "balls" can be dragged; block view fills like old defrag. Entertainment, not the software table

## Information architecture

Boot: **Summary**. Meters for CPU, clock, temperature, GPU, then memory, disks, network, energy, GPU, NPU, thermals, plus top processes that fit the window.

Then pages (not a web tab strip as the product identity):

- Performance (one CPU graph or per-core split)
- GPU / NPU (honest about coarse data: NPU "kind of goes 0 50. It's not very granular")
- Disks (combine or split)
- Network (same combine/split)
- Thermals (scroll die sensors; relative share, e.g. Task Manager "like a 14 relative to Chrome")
- Processes (tree, apps vs background)
- System info (slow fill is OK: "can take a minute")
- Startup apps (checkbox to disable)
- Users (who runs what, jump to process)
- Services (start / stop / kill)
- Installed apps (size sort, uninstall)
- Disk space (balls or block view)

Inspect a process: sockets, open files, "a fair bit of detail."

Feature response he named: blinking disk, palettes, block view, tear-off panels, long history, and especially the front summary as a unified view.

## Lists and trees

Process list should feel like any task manager, then add the tree. Parent action fans out. Child action is precise. Do not make the user guess whether End Task kills the family.

Startup is a checkbox list, not a wizard.

System info can populate asynchronously. The page exists while data arrives.

## Installed software

One table. Primary question: what uses space. Sort by app size. Uninstall without a scavenger hunt.

Disk visualization is a second mode of the disk page (circle packing, then defrag blocks). It is not the installed-apps UI.

A portable `.exe` that you just run is not an "installed application." Native installers and store packages are.

## Platform

Same job on each OS. Helpers differ:

- Process enumeration is different on Windows, Mac, and Linux
- Some meters simply cannot be filled (Mac clock rate)
- Distro package tools differ (pacman vs apt) but the job is "install the compiler and git"

Windows build: Direct2D. Mac: Swift UIKit. Linux: Qt. Portable Windows binary, no forced installer. Linux packaging follows the distro (he compiled on Arch after Debian).

## What not to cargo-cult

These are TMOG's personal cockpit, called out in the episode as taste:

- Saturation 11
- Visual bloom
- VFD font and unlit-segment grid
- Sickbay side meters
- Phosphor green / amber / blue / mono as the product identity
- Draggable disk balls as the way to manage software

Keep: native toolkit, summary-then-depth, tree verbs, size-sorted installed list, missing values still on screen, system appearance as default.

## AppAttic adoption

| TMOG language | AppAttic |
|---------------|----------|
| Native UI + shared core + helpers | AppKit (SwiftCrossUI) on macOS, Qt 6 Widgets on Linux (`ui/linux-qt`), WinUI on Windows. Zig WASM core + plugins |
| Summary without tabbing | Overview: totals plus largest leftovers and stale |
| Deeper pages | Leftovers, Stale Apps, Outdated, Packages, Settings |
| Process tree: parent or one node | Package tree: remove unused deps with the parent, or one row |
| Installed apps: sort by size, uninstall | Packages: size column, script-preview remove / mark-manual |
| Apps vs background | Orphan (distro auto) vs Global (language tools) |
| Checkbox keep/disable | Mark as manually installed (apt/pacman/dnf/zypper) |
| Inspect sockets/files | Inspector: path, why, size, manager |
| Missing meter stays | Empty copy when a manager is absent. Sidebar item stays |
| pacman vs apt | Per-family queries, same scan |
| System light/dark | System appearance only |
| VFD / bloom / phosphor | Not used. Finder / Activity Monitor / GNOME Settings density |

AppAttic cleanup still requires confirm and a reviewed `sh` script. TMOG can "uninstall pretty trivially." AppAttic's product language is leftovers, stale, outdated, packages. Brand is those words, not a phosphor wordmark.
