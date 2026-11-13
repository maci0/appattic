# TMOG design notes (Dave's Attic, Shop Talk #91)

Source: [Windows Task Manager's Creator Rebuilt It 30 Years Later | Shop Talk #91](https://www.youtube.com/watch?v=c3EEs-O3bGE) (Dave Plummer, `@davepl`, with Glenn).

Paraphrase of the product points Dave walked through. Captions were the source. These are not verbatim quotes. Full language: [`docs/tmog-design-language.md`](../tmog-design-language.md).

## What he described

- Three native shells over one C++ core, with OS helpers where the platform API differs. He named Direct2D and Direct Composition on Windows, Swift UIKit on Mac, and Qt on Linux.
- The window opens on a summary (CPU, clock, temperature, GPU), then separate pages for performance, processes, system info, startup apps, users, services, installed apps, and disk.
- The process list is a tree. Ending the parent ends what that parent started. Ending one node leaves the rest.
- Installed apps sort by size, and uninstall is a normal action on that table. The circle-packing and old-defrag block views are a disk page, separate from that table.
- A meter stays on screen when the OS will not give the number. On the Mac he showed, the clock reads as automatic rather than disappearing.
- Building on Arch after Debian meant learning pacman in place of apt. Both are the package manager for the same job: install the compiler, git, and the rest of the tools.
- Color saturation is a setting. He prefers intense color and said that is too much for some people. The default can be turned down.

## What AppAttic took

AppAttic keeps the summary-then-pages shape, tree actions on packages, a size-sorted installed list, and visible empty values. It does not copy VFD meters, bloom, or the high-saturation cockpit.

The stack is not the one he described. macOS uses SwiftCrossUI on AppKit and scans in Swift (`AppAtticScan`). Linux uses C++ Qt 6 and scans through Zig WASM plugins. There is no Windows build. See the adoption table in [`docs/tmog-design-language.md`](../tmog-design-language.md).
