# Contributing

Setup, tests, and layout: [README.md](README.md).

```bash
./build.sh --help
bash scripts/check.sh          # fast: lint + Zig core + AppAtticScanTests + CLI
bash scripts/check.sh --qt     # full Linux CI parity, including Qt/WASM proof
bash scripts/check.sh --core   # the same, minus every Swift step (see below)
bash scripts/test.sh DiskSizeTests    # one class, or one test: Class/testName
./core/build.sh test brew.zig
./core/build.sh test-core
```

`core/build.sh` compiles and tests one module per process, one core at a time
minus one (`APPATTIC_BUILD_JOBS` overrides). Output and failure reports stay in
the module order the script declares, so a red line names the module that broke.

`scripts/check.sh --core` runs the lint gate, the Zig core suite and the
reproducible-artifact check without a Swift toolchain, for work in `core/src/`,
`core/host/` or `packaging/`. It is not the CI gate: `AppAtticScanTests` and the
CLI build do not run, and the last line of the run names both. The default
`scripts/check.sh` still refuses to start without Swift, so an unrun test cannot
pass unnoticed.

PRs run `.github/workflows/linux.yml` (lint, Ubuntu tests, jammy, archlinux Qt link). The Ubuntu, jammy and macOS jobs call `bash scripts/test.sh` themselves, so use that script rather than `swift test`: it passes `--disable-automatic-resolution`, sets `APPATTIC_NO_MAC_UI=1` on macOS, and checks the toolchain against `.swift-version`. `swift test` builds every target in the package and `AppAtticUI` needs a Swift 6 compiler, which `.swift-version` (5.10.1) does not provide, so a bare `swift test` does not build on the pinned toolchain. `scripts/check.sh` runs the same script. The lint job checks out full history so `scripts/lint.sh` can reject AI tool credits in commit messages; a shallow clone sees fewer commits and says how many.

Missing tools: `bash scripts/linux-deps.sh` prints what the distro needs, `--install-shellcheck` installs the one `scripts/lint.sh` cannot do without. Every workflow pins its actions to a commit SHA with a `# vX.Y.Z` comment; Dependabot (`.github/dependabot.yml`) reads both, so a pin bump arrives as a pull request instead of rotting until the action fails.

`bash scripts/lint.sh` needs `shellcheck`, `yamllint`, and the pinned Zig on PATH (`bash scripts/linux-deps.sh --install-zig`). It compiles the C host with every compiler on `PATH`, so `clang` (`bash scripts/linux-deps.sh --install`) makes the gate see what clang sees, and it compiles `embed.c` when the Wasmtime C API headers are installed (`bash scripts/linux-deps.sh --install-wasmtime`); without them it names that file as unchecked. CI installs the yamllint version pinned in `scripts/deps.sh`; `scripts/deps.sh check` fails when the workflow and that pin disagree. Zig always comes from the checksummed `.zig-version` tarball, never from a distro package, so `zig fmt --check` sees the pinned version. Outside CI a missing Zig skips `zig fmt --check`; in CI it fails the run. The packaging gate needs no tool of its own: `scripts/check-packaging.sh` compares the desktop entry, the AppStream metainfo, the man page, and the Flatpak manifest against each other and against the install rules in `ui/linux-qt/CMakeLists.txt`, and adds `desktop-file-validate` (distro package `desktop-file-utils`, or `desktop-file-validate` on macOS) when it finds it, saying it skipped the desktop entry when it does not.

Swift 5.10.1 is `.swift-version`. Zig 0.16.0 is `.zig-version`. `./build.sh` fails with a named error if `swift` is missing; it also looks in `/opt/swift/usr/bin` and `.deps/swift/usr/bin`. `scripts/deps.sh check` fails when a workflow's `swift-version:` step or its `container: swift:` job image disagrees with `.swift-version`.

## Releasing

The version is declared in one file and copied into three others, and `bash scripts/check-version.sh` fails when any of them disagree. It runs in `scripts/lint.sh`, so CI catches a partial bump. Bump all of them in one commit:

- `Sources/AppAtticScan/Version.swift`, `appAtticVersion` (what `appattic --version` prints, and what `ui/linux-qt/CMakeLists.txt` reads at configure time for `APPATTIC_VERSION`)
- `packaging/org.appattic.AppAttic.metainfo.xml`, a new `<release>` with its date and a consumer-facing `<description>`
- `packaging/Info.plist`, `CFBundleShortVersionString` (what macOS reads; `build.sh` copies the file into `AppAttic.app` unchanged). Its `CFBundleVersion` is the build number beside that version, not the version itself: raise it on every release, including patches, or macOS treats the new bundle as the one already installed.
- `packaging/appattic-qt.1`, the `.TH` version line (the man page for the Qt window)

The AppStream `<description>` is the only release note shipped to users, so a release without one is a silent release, and `check-version.sh` fails on a `<release>` with no date or no `<description>`. The `v*` tag is the release trigger; the workflow refuses to build a tag that does not match the declared version. A version already released is immutable: the same number may not ship a second, different build, so `check-version.sh` also fails when the declared version is a tag that points at another commit. The release workflow checks out the full history so that check can see the tags. The Flatpak manifest is not a fifth copy to remember: `scripts/linux-flatpak.sh` stamps the declared version into the manifest it builds, and fails if the manifest ever carries a literal that disagrees. Minor bumps carry new features, patch bumps carry fixes, and a breaking change to the CLI, JSON output, or cache format goes out as a major. A change to an exit code a script can see, or to a flag that used to be accepted and ignored, is a breaking change: the `<description>` says what moved and what the caller has to change. That same `<description>` is the GitHub release body: the workflow writes it with `scripts/release-notes.sh` rather than letting the action generate a commit list, so the release page is the same text and not a second changelog.

