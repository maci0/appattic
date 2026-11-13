# Contributing

What AppAttic does and how to use it: [README.md](README.md). Architecture: [`core/README.md`](core/README.md) and [`docs/specs/`](docs/specs/README.md).

## Setup

```bash
bash scripts/linux-deps.sh   # preflight, on Linux or macOS
```

The preflight reports each dependency as `present` or `missing` against the pins (Swift 5.10.1 in `.swift-version`, Zig 0.17.0 in `.zig-version`), with an install hint after each `missing` line. A tool it reports present is not why a gate fails; the ones it names are the remaining setup. Each `--install-*` flag installs the tool its `missing` line names:

```bash
./scripts/linux-deps.sh --install              # Qt 6 headers, cmake, ninja, pkg-config, clang (root)
./scripts/linux-deps.sh --install-wasmtime     # Wasmtime C API, to embed the core
./scripts/linux-deps.sh --install-zig
./scripts/linux-deps.sh --install-shellcheck   # these three for scripts/lint.sh
./scripts/linux-deps.sh --install-ripgrep
./scripts/linux-deps.sh --install-desktop-file-utils
./scripts/linux-deps.sh --install-swift        # into /opt/swift, or .deps/swift without root
export PATH="/opt/swift/usr/bin:$PATH"         # or "$PWD/.deps/swift/usr/bin"
```

Every `--install-*` flag is Linux-only: each installs a distro package or a tarball whose pinned checksum in `scripts/dep-checksums.sha256` is a Linux triple. On macOS the preflight still runs, with Homebrew and Xcode commands as hints and Qt 6 shown as `n/a (Linux target)`; an `--install-*` flag there exits 2 and names the command that works. Zig always comes from the checksummed `.zig-version` tarball, never a distro package. Arch has no Swift in `extra`: use AUR `swift-bin` or `--install-swift`. Qt 6 headers by distro: `qt6-base-dev` (Debian/Ubuntu), `qt6-qtbase-devel` (Fedora), `qt6-base` (Arch), `qt6-base-devel` (openSUSE).

## Building

```bash
./build.sh                               # release CLI; Linux window when Qt is available
./build.sh debug
./build.sh --help                        # contributor commands
bash scripts/linux-qt-link.sh            # only the Linux window, Debug, into ui/linux-qt/build
bash scripts/linux-qt-link.sh release    # Release, into ui/linux-qt/build-release
bash scripts/verify-qt-link.sh           # assert the link proof (ldd + --smoke); add `release` for that tree
```

`./build.sh` links the Linux window in the same config as the CLI, each config in its own tree, so a release link never picks up a stale Debug binary. Without Qt it builds the CLI and says so.

On macOS, `build.sh` contains an ad-hoc-signed `AppAttic.app` packaging path, but the current toolchain requirements prevent that path from completing: it enforces Swift 5.10.1, while `AppAtticUI` depends on swift-cross-ui 0.2.1 and needs Swift 6. It falls back to the CLI. Building the macOS UI requires a separate Swift 6 setup outside this pinned workflow; passing Swift 6 to `build.sh` is rejected. SwiftPM names the product `AppAtticUI` so it cannot collide with `appattic` on a case-insensitive volume.

Build the Linux window on the distro you will run it on. A cross-compile from macOS is not a Linux link, Homebrew Qt is not Linux Qt, and an Ubuntu-built binary is not assumed to start on Arch (glibc differs). Qt discovery looks in the Debian multiarch directory, `/usr/lib`, and `/usr/lib64`, so the same commands work on Fedora and openSUSE. The window's runtime requirements depend on its Qt, Wasmtime, and libc builds. It uses `statx` where libc declares it, falling back to `fstatat`. The CLI and `AppAtticScan` do not link the C host. musl is not a target.

Every Swift build goes through `appattic_swift_build` in `scripts/swift-build.sh`, never a bare `swift build`: the helper carries `--disable-automatic-resolution` and the prefix-map flags that keep the checkout path out of the binary, and `scripts/lint.sh` fails on a stray `swift build` in the scripts, workflows, or docs. `swift build` and `swift test` need unrestricted permissions in sandboxed environments.

Debug builds of `appattic-qt` also take `--dev-check <table|overview|stream|disk|shot>`, the CI gates and the offscreen page renders (`shot <dir>`). `NDEBUG` compiles them out, so a release binary rejects the flag with exit 2.

## Tests and gates

```bash
bash scripts/check.sh          # fast: lint + Zig core + AppAtticScanTests + CLI
bash scripts/check.sh --qt     # full Linux CI parity, including Qt/WASM proof
bash scripts/check.sh --core   # no Swift needed: lint + Zig core + reproducible artifacts
bash scripts/test.sh                                                  # AppAtticScanTests
bash scripts/test.sh DiskSizeTests                                    # one class
bash scripts/test.sh DiskSizeTests/testParseDuKBRequiresLeadingInteger   # one test
./core/build.sh test brew.zig                  # one Zig module
./core/build.sh test jsonbuf.zig isSafeIdent   # one Zig test, from the module that declares it
./core/build.sh test-core                      # the whole Zig core, no Wasmtime or Qt
bash scripts/lint.sh
```

`bash scripts/check.sh --help` lists each mode's steps. `--core` is for work in `core/src/`, `core/host/`, or `packaging/`; it is not the CI gate, and its last line names the Swift steps it skipped. The default mode refuses to start without Swift, so an unrun test cannot pass unnoticed.

Use `scripts/test.sh`, not `swift test`. It passes `--disable-automatic-resolution`, checks the toolchain against `.swift-version`, and sets `APPATTIC_NO_MAC_UI=1` on macOS; a bare `swift test` builds every target, including `AppAtticUI`, and fails on the pinned toolchain. The CI jobs call the same script.

A filter that matches no test fails rather than passing. `swift test` exits 0 after running zero tests, so a misspelled class reads green; `scripts/test.sh` refuses that, and `core/build.sh` does the same for a `zig test` filter. The Zig filter is scoped to the named module, because `zig test` on one file also runs the tests of every file it imports, and an unscoped name could go green while the module you edited went untested.

`core/build.sh` builds and tests one module per process, on all cores but one (`APPATTIC_BUILD_JOBS` overrides). Output stays in the module order the script declares, so a red line names the module that broke. It also fails on unformatted Zig and on a `hostexec_test` warning.

### Lint

`bash scripts/lint.sh --help` lists every check. It needs `shellcheck`, `yamllint`, `ripgrep`, and the pinned Zig on `PATH`; a missing one is named with its install command, never a silent pass, and CI installs the full set. It also uses whatever else the host has: every C compiler on `PATH` for the C host (warnings as errors, then ASan and UBSan, GCC `-fanalyzer`, and `clang --analyze`), the Wasmtime headers to compile `embed.c`, and `desktop-file-validate` for the desktop entry. Each one it lacks is reported as unchecked.

Checks worth knowing before editing docs:

- No `path:line` citations in the markdown. Line numbers rot silently; name the symbol and the file instead.
- The host argv block in `core/README.md` and the spec must match what `core/build.sh` prints.
- `ConfigTests` require this repo's README to name every environment switch `appattic config` reports, and its quoted `config` run to keep the order the command prints. `PackagingTests` require each documented single-test and single-plugin example to resolve.
- Commit messages crediting an AI tool are rejected. The lint job checks out full history for this; a shallow clone checks fewer commits and says how many.

The Qt shell is compiled by its own build, not by `lint.sh`: `ui/linux-qt/CMakeLists.txt` builds every C++ source with warnings as errors, and a source added to that directory without joining its list fails the configure.

### Reproducibility and races

```bash
bash scripts/verify-reproducible.sh         # every WASM module and the C host, built twice
bash scripts/verify-swift-reproducible.sh   # the release CLI, built twice
bash scripts/verify-qt-reproducible.sh      # appattic-qt, built twice
bash scripts/race-check.sh                  # the C host and Qt worker pools, ThreadSanitizer
bash scripts/race-check.sh --swift          # ScanConcurrencyTests, ThreadSanitizer
```

Each double build runs from two differently named directories under a different timezone and `SOURCE_DATE_EPOCH`, and fails unless the artifacts are byte-identical, so a build path, timestamp, or locale that reaches an output shows up as a diff. The prefix maps that make that hold live in `scripts/swift-build.sh` and `ui/linux-qt/CMakeLists.txt`, and `lint.sh` fails if the Swift check and the Swift build drift apart on the flag list. `scripts/check.sh` runs the WASM and Swift checks on every pass, `--qt` adds the Qt one, and the CI `test` job runs all three as blocking steps.

The race checks cover the three places that run their own threads: the C host's PATH apply/restore pair, the Qt leftover-size and disk-walk pools, and the Swift `pmap` fan-out behind the shared progress callback. Each builds out of tree. A missing toolchain is a named skip locally and a failure in CI.

### CI

`.github/workflows/linux.yml` runs on every push and PR: `lint`, `test` (Ubuntu 24.04: tests, race checks, CLI contract, the three double builds, Qt link), `jammy` (`swift:5.10.1-jammy` container), `archlinux` (Qt link), and `macos` (scan library and CLI). Container images are digest-pinned. Actions are pinned to a commit SHA with a `# vX.Y.Z` comment, which Dependabot (`.github/dependabot.yml`) reads, so pin bumps arrive as PRs. `scripts/deps.sh check` fails when a workflow's Swift version disagrees with `.swift-version`.

The two Dockerfiles run the same build as CI's Ubuntu and Arch jobs (tests, CLI, Qt window, link proof); no workflow builds them:

```bash
podman build -t appattic .                           # Ubuntu (docker works too)
podman build -t appattic-arch -f Dockerfile.arch .   # Arch userland
```

### Benchmarks

On demand, for comparing two changes; not in CI and not a gate:

```bash
bash core/bench.sh [filter-substr]                       # Zig core parsers, Linux only
. scripts/swift-build.sh && appattic_swift_build release --product appattic-bench
.build/release/appattic-bench [--json] [filter-substr]   # AppAtticScan hot paths
```

`core/bench.sh` is described in [`core/README.md`](core/README.md#benchmarks). `appattic-bench` prints one `<name> <iters> <ns/op> <checksum>` line per benchmark, or JSON with `--json`. Both end with a `sink=<n>` line so the optimizer cannot drop a benchmarked loop.

### Build-time variables

| Variable | Effect |
|---|---|
| `APPATTIC_NO_MAC_UI` | `1`/`true`/`yes`/`on` drops the macOS UI target and its Swift 6 dependency, so the package builds on Swift 5.10.1. `scripts/test.sh` sets it on macOS |
| `APPATTIC_BUILD_JOBS` | Job count for `core/build.sh`, a whole number of at least 1; anything else stops the build |
| `SOURCE_DATE_EPOCH` | Build date for the reproducible builds and their double-build checks |
| `WASMTIME_DIR` | Wasmtime C API prefix for building and linking the Linux window; the AppImage and Flatpak builds set it |

## Packaging

### AppImage

```bash
bash scripts/linux-deps.sh --install
bash scripts/linux-deps.sh --install-wasmtime
bash scripts/linux-appimage.sh
# dist/AppAttic-x86_64.AppImage  (aarch64 on arm64 hosts)
```

The script downloads pinned linuxdeploy, linuxdeploy-plugin-qt, and appimagetool into `dist/.appimage-tools/`, checks their SHA-256, and fails unless the packed binary's `--smoke` prints `SMOKE=ok`. WASM modules ship under `usr/share/appattic/` and `libwasmtime.so` under `usr/lib/`, reached as `$ORIGIN/../lib`. The image embeds update information pointing at its release's `.zsync`. The script also writes `dist/AppAttic-<arch>.AppImage.sbom.json`, a CycloneDX 1.5 inventory of the pinned third-party inputs: the downloaded tools, the `Package.resolved` pins, and the vendored files (the Michroma title font in `ui/linux-qt/fonts/`, SIL OFL 1.1, compiled into the binary with its license installed beside it).

### Flatpak

```bash
bash scripts/linux-flatpak.sh   # needs flatpak-builder; installs org.kde.Sdk//6.10 from Flathub if missing
flatpak run org.appattic.AppAttic
```

The manifest is `packaging/flatpak/org.appattic.AppAttic.yml`, on `org.kde.Platform` 6.10. It carries no version: `scripts/linux-flatpak.sh` stamps `appAtticVersion` into the manifest it builds and fails if the file ever holds a literal that disagrees. The sandbox gets `--filesystem=host:ro` so scans can see the machine. Nothing inside the sandbox writes a host path: Move to Trash goes through the file-manager portal, and the confirmed cleanup and update scripts run outside it under `flatpak-spawn --host`. With `FLATPAK_ID` set, plugin tags look under `/run/host`, since the sandbox `PATH` has no host pacman or apt. Scan plugins still cannot run `rm` or distro upgrades through `host.exec`.

### Pins, licenses, and the SBOM

```bash
bash scripts/deps.sh check              # pins vs URLs vs Flatpak sha256 and runtime branch, fetcher defaults, vendored hashes and licenses
bash scripts/deps.sh sbom out.json      # the CycloneDX 1.5 inventory
bash scripts/deps.sh yamllint-version   # the yamllint pin lint.sh names when it is missing
```

`scripts/lint.sh` runs `check`, so a version bump that leaves a pin, URL, or Flatpak `sha256:` behind fails the local gate. It also fails when:

- a pin or vendored file has no SPDX license row (`VENDORED` and `SWIFTPM_LICENSES` in `scripts/deps.sh`, each read from the package's `LICENSE` at the pinned revision), or a row names something no longer pinned;
- the Flatpak manifest names no runtime, `runtime-version`, or SDK, since an unnamed branch lets `flatpak-builder` resolve whatever the remote's default is;
- a fetcher default disagrees with the recorded pin: `WASMTIME_VER` in `linux-deps.sh` against the Wasmtime checksum row, `KDE_RUNTIME` in `linux-flatpak.sh` against the manifest branch. Neither script runs in CI, so this check is what catches that drift.

`jpeg` (via `swift-image-formats`) is the one non-permissive license, MPL-2.0. Its file-level copyleft covers that package's own sources, which nothing here modifies, not the binary linking them. The inventory pins the KDE runtime by branch, not digest, and says so in `appattic:pinned-by`; it lists that runtime as one component, and does not list the Qt libraries `linuxdeploy-plugin-qt` copies into the AppImage from the build host.

## Releasing

The version is declared once, in `Sources/AppAtticScan/Version.swift` (`appAtticVersion`: what `appattic --version` prints and what `ui/linux-qt/CMakeLists.txt` reads at configure time). Four files copy it; bump them in the same commit:

- `packaging/org.appattic.AppAttic.metainfo.xml`: a new `<release>` with its date and a user-facing `<description>`.
- `packaging/Info.plist`: `CFBundleShortVersionString`, and `CFBundleVersion`, a build number raised on every release including patches, or macOS treats the new bundle as the one already installed. `build.sh` copies the file into `AppAttic.app` unchanged.
- `packaging/appattic.1` and `packaging/appattic-qt.1`: the `.TH` version line.

`bash scripts/check-version.sh` prints the declared version and fails when any copy disagrees, when the newest `<release>` has no date or no `<description>`, when `CFBundleVersion` is not a build number, when CMake stops deriving the version, when the newest note lists different flags winning over a usage error than `cliHelpText` does, or when the declared version is already a tag on another commit. `--tag vX.Y.Z` also requires the tag to match. `scripts/lint.sh` runs it, so CI catches a partial bump.

Pushing a `v*` tag runs `.github/workflows/release.yml`: `check-version.sh --tag` on a full-history checkout, `AppAtticScanTests` (it runs in parallel with `linux.yml`, so it cannot rely on that), then the AppImage build. It publishes the AppImage, `.zsync`, `.buildinfo`, and `.sbom.json`, with `bash scripts/release-notes.sh vX.Y.Z` (the release's AppStream `<description>`, exit 1 when there is none) as the release body. The macOS zip job is disabled.

Release rules:

- The `<description>` is the only release note: shipped in the package and used as the GitHub release body. A release without one is a silent release, and a note that contradicts the binary is worse, because callers migrate from it.
- Minor bumps carry features, patch bumps fixes. A breaking change to the CLI, JSON output, or cache format is a major. That includes an exit code a script can see changing and a flag that used to be accepted and ignored now failing; the note says what moved and what a caller changes.
- A deprecated public symbol carries `@available(*, deprecated, ...)` from the release that deprecates it, its comment names the removal version, and that release's note says so. One major separates deprecation from removal.
- A released version is immutable. Each AppImage's update URL names its own tag's `.zsync`; distributing different bytes under that version breaks that identity, and the URL does not discover a later tag. A bad release is withdrawn and replaced by a new version; [`docs/runbooks/release-rollback.md`](docs/runbooks/release-rollback.md) is the procedure.

After the tag is pushed, update the AUR recipes in `packaging/aur/` (`appattic`, `appattic-qt`, `appattic-bin`): set `pkgver` to the tag, refresh the checksums, and push each package base to `ssh://aur@aur.archlinux.org/<name>.git`. Each recipe packages the tag, not the branch tip.
