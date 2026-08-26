# TMOG design patterns (Dave's Attic, Shop Talk #91)

Source: [Windows Task Manager's Creator Rebuilt It 30 Years Later | Shop Talk #91](https://www.youtube.com/watch?v=c3EEs-O3bGE)
Channel: Dave's Attic (`@davepl`). Captions: `tmog-shoptalk-91.en.srt`.
Dave Plummer walking through Task Manager OG (TMOG) with Glenn. Quotes below are cleaned from auto-captions (rolling duplicates removed). Not a full episode transcript.

## Native per OS, one core

Glenn: how can Task Manager OG feel native on Windows, Mac, and Linux without becoming three unrelated products? How do you vary them to make them fit in each system, but keep them all the same or similar?

Dave: It's kind of a weird architecture. At the top, you've got the user interfaces, and so that's written in Direct 2D for Windows, and as I mentioned, UI kit for Mac and then QT for Linux. And then they all talk to a common C++ core and then that core branches out to system specific helpers for things like stuff that you can only do on a Mac or getting the process information is different on Windows, Mac and Linux.

Earlier, same stack in fewer words: I'm using Direct 2D, Direct Composition on Windows, and I'm using Swift UI Kit on Mac and QT on Linux.

## Summary first, then tabs that go deeper

Dave: This is the main page of the task manager and it boots up to a summary view which gives you meters for your CPU, clock, temperature, GPU.

Then separate surfaces: performance, processes, system info, startup apps, users, services, installed apps, disk.

## Process tree: act on the parent or one child

Dave: It's tree view though. So you can go so you kill this and it'll kill everything that Google has started. Or you can go in and kill one window.

## Installed apps: size sort, uninstall is a first-class verb

Dave: What else we got? We got installed apps. You can go through and figure out what apps are using up the most space. Sort by app size. Uninstall apps pretty trivially.

Disk space is a second mode (circle packing / old-defrag blocks). That is TMOG's disk toy, not the installed-apps table.

## Missing platform data stays on screen

Clock-speed meter: on this machine, it just says it's auto. We don't tell you.

The control does not disappear because macOS hid the number.

## Distro package managers are different tools, same job

On compiling TMOG on Arch after Debian:

Dave: I thought Arch is going to be significantly different than Debian, but I had to figure out how to use Pac-Man instead of apt. But Pac-Man is the package manager. Let you like install your compiler and install git and install the tools.

## Color / phosphor is personal, not the product contract

Dave: This is probably a little colorful for a lot of folks. I tend to like really intense colors and I like a lot of contrast, but I realize not everybody wants that. So if you go to the colors picker here, you can actually adjust the amount of saturation in the user interface.

AppAttic follows the architecture, density, tree actions, and installed-apps table. It does not copy VFD meters, bloom, or saturation-11 chrome. Finder / Activity Monitor / GNOME Settings density stays. Full design language: [`docs/tmog-design-language.md`](../tmog-design-language.md).

## How AppAttic maps this

| TMOG | AppAttic |
|------|----------|
| Native UI + shared core + OS helpers | AppKit on macOS, Qt 6 on Linux (`ui/linux-qt`), WinUI on Windows. WASM core + per-manager plugins |
| Summary, then tabs | Overview, then Leftovers / Stale / Outdated / Packages / Settings |
| Process tree: kill parent or one node | Package tree: remove leaf/parent plus unused deps, or one package |
| Installed apps: sort by size, uninstall | Packages page: installed packages, size column, script-preview uninstall |
| Clock stays visible when unknown | Missing managers: empty copy, no hidden sidebar item |
| pacman vs apt | Native query per family (`pacman -Qdt`, apt autoremove, `dnf repoquery --unneeded`, npm/pnpm/bun/pipx/uv globals) |
| Phosphor / VFD | Not used |
