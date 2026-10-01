# Contributing

Setup, tests, and layout: [README.md](README.md).

```bash
./build.sh --help
bash scripts/check.sh          # fast: lint + Zig core + AppAtticScanTests + CLI
bash scripts/check.sh --qt     # full Linux CI parity, including Qt/WASM proof
bash scripts/check.sh --core   # the same, minus every Swift step (see below)
bash scripts/test.sh DiskSizeTests    # one class, or one test: Class/testName
./core/build.sh test brew.zig
./core/build.sh test jsonbuf.zig isSafeIdent
./core/build.sh test-core
bash core/bench.sh                # Zig parser benchmarks, on demand, Linux only
```

`core/build.sh` compiles and tests one module per process, one core at a time
minus one (`APPATTIC_BUILD_JOBS` overrides, as a whole number of at least 1; any
other value stops the build and names the variable). Output and failure reports stay in
the module order the script declares, so a red line names the module that broke.
The second argument to `test` filters to one test, the Zig counterpart of
`scripts/test.sh Class/testName`; a name that matches nothing fails rather than
reporting a green run over zero tests. The filter is scoped to the named
module, because `zig test` on one file also runs the tests of every file it
imports: an unqualified name would run the imported tree's tests and read green
while the module you edited went untested. A test that lives in another module
is run from that module.

A filter that matches no test fails rather than reporting a pass. `swift test` exits 0 having run zero tests, so a renamed or misspelled class name reads green; `scripts/test.sh` refuses that condition, the same way `core/build.sh` does for a `zig test` filter that matches nothing.

`scripts/check.sh --core` runs the lint gate, the Zig core suite and the
reproducible-artifact check without a Swift toolchain, for work in `core/src/`,
`core/host/` or `packaging/`. It is not the CI gate: `AppAtticScanTests` and the
CLI build do not run, and the last line of the run names both. The default
`scripts/check.sh` still refuses to start without Swift, so an unrun test cannot
pass unnoticed.

PRs run `.github/workflows/linux.yml` (lint, Ubuntu tests, jammy, archlinux Qt link). The Ubuntu, jammy and macOS jobs call `bash scripts/test.sh` themselves, so use that script rather than `swift test`: it passes `--disable-automatic-resolution`, sets `APPATTIC_NO_MAC_UI=1` on macOS, and checks the toolchain against `.swift-version`. `swift test` builds every target in the package and `AppAtticUI` needs a Swift 6 compiler, which `.swift-version` (5.10.1) does not provide, so a bare `swift test` does not build on the pinned toolchain. `scripts/check.sh` runs the same script. The lint job checks out full history so `scripts/lint.sh` can reject AI tool credits in commit messages; a shallow clone sees fewer commits and says how many.

Missing tools: `bash scripts/linux-deps.sh` with no flags is the preflight. It reports each dependency as `present` or `missing`, against the versions `.zig-version` and `.swift-version` pin, and an install hint follows only a `missing` line. Run it first on a clean clone: a tool it reports as present will not be the reason a gate fails, and the ones it names are the whole remaining setup. Each `--install-*` flag installs the tool its `missing` line names.

Every `--install-*` flag is Linux-only: each installs a distro package or a tarball whose pinned checksum in `scripts/dep-checksums.sha256` is a `linux` triple. On macOS the script still runs the preflight and reports the same `present` / `missing` lines, with Homebrew and Xcode commands as the hints; Qt 6 reads `n/a (Linux target)`, because the Qt window is a Linux build (`scripts/linux-qt-link.sh` exits 3 on Darwin) and the CLI and scan library are what build on a Mac. An `--install-*` flag on macOS stops with exit 2 and the command that works there, rather than fetching a Linux binary.

Every workflow pins its actions to a commit SHA with a `# vX.Y.Z` comment; Dependabot (`.github/dependabot.yml`) reads both, so a pin bump arrives as a pull request instead of rotting until the action fails.

`bash scripts/lint.sh` needs `shellcheck`, `yamllint`, and the pinned Zig on PATH (`bash scripts/linux-deps.sh --install-zig`). It compiles the C host with every compiler on `PATH`, so `clang` (`bash scripts/linux-deps.sh --install`) makes the gate see what clang sees, and it compiles `embed.c` when the Wasmtime C API headers are installed (`bash scripts/linux-deps.sh --install-wasmtime`); without them it names that file as unchecked. The C host also goes through both static analyzers the compilers already on `PATH` provide: GCC's `-fanalyzer`, which needs a GCC driver and reports that it gave up on a path it could not finish, and `clang --analyze`, which prints its findings and exits 0 regardless, so the script matches the output rather than the exit status. A host with neither says which pass did not run. CI installs the yamllint version pinned in `scripts/deps.sh`; `scripts/deps.sh check` fails when the workflow and that pin disagree. Zig always comes from the checksummed `.zig-version` tarball, never from a distro package, so `zig fmt --check` sees the pinned version. Outside CI a missing Zig skips `zig fmt --check`; in CI it fails the run. The packaging gate needs no tool of its own: `scripts/check-packaging.sh` compares the desktop entry, the AppStream metainfo, the man page, and the Flatpak manifest against each other and against the install rules in `ui/linux-qt/CMakeLists.txt`, and adds `desktop-file-validate` (distro package `desktop-file-utils`, or `desktop-file-validate` on macOS) when it finds it, saying it skipped the desktop entry when it does not. The gate also refuses a `path:line` citation in the markdown: a line number in prose rots silently, and half the ones the spec carried had already drifted, so a doc names the symbol and the file and a reader greps for the symbol instead.

Swift 5.10.1 is `.swift-version`. Zig 0.16.0 is `.zig-version`. `./build.sh` fails with a named error if `swift` is missing; it also looks in `/opt/swift/usr/bin` and `.deps/swift/usr/bin`. `scripts/deps.sh check` fails when a workflow's `swift-version:` step or its `container: swift:` job image disagrees with `.swift-version`.

## Releasing

The version is declared in one file and copied into four others, and `bash scripts/check-version.sh` fails when any of them disagree. It runs in `scripts/lint.sh`, so CI catches a partial bump. Bump all of them in one commit:

- `Sources/AppAtticScan/Version.swift`, `appAtticVersion` (what `appattic --version` prints, and what `ui/linux-qt/CMakeLists.txt` reads at configure time for `APPATTIC_VERSION`)
- `packaging/org.appattic.AppAttic.metainfo.xml`, a new `<release>` with its date and a consumer-facing `<description>`
- `packaging/Info.plist`, `CFBundleShortVersionString` (what macOS reads; `build.sh` copies the file into `AppAttic.app` unchanged). Its `CFBundleVersion` is the build number beside that version, not the version itself: raise it on every release, including patches, or macOS treats the new bundle as the one already installed.
- `packaging/appattic-qt.1`, the `.TH` version line (the man page for the Qt window)
- `packaging/appattic.1`, the `.TH` version line (the man page for the CLI)

The AppStream `<description>` is the only release note shipped to users, so a release without one is a silent release, and `check-version.sh` fails on a `<release>` with no date or no `<description>`. A note that contradicts the binary is worse than no note, because it is the text a caller migrates from, so `check-version.sh` also fails when the newest note names a different set of flags winning over a usage error than `cliHelpText` does. Both are released the same way: `--help` and `--version` ask a question and exit, and a bad token elsewhere on the line suppresses neither. The `v*` tag is the release trigger; the workflow refuses to build a tag that does not match the declared version. A version already released is immutable: the same number may not ship a second, different build, so `check-version.sh` also fails when the declared version is a tag that points at another commit. The release workflow checks out the full history so that check can see the tags. The Flatpak manifest is not a fifth copy to remember: `scripts/linux-flatpak.sh` stamps the declared version into the manifest it builds, and fails if the manifest ever carries a literal that disagrees. Minor bumps carry new features, patch bumps carry fixes, and a breaking change to the CLI, JSON output, or cache format goes out as a major. A change to an exit code a script can see, or to a flag that used to be accepted and ignored, is a breaking change: the `<description>` says what moved and what the caller has to change. That same `<description>` is the GitHub release body: the workflow writes it with `scripts/release-notes.sh` rather than letting the action generate a commit list, so the release page is the same text and not a second changelog. A public symbol carries `@available(*, deprecated, ...)` from the release that deprecates it, its comment names the version it is removed in, and the `<description>` of that release says so: a deprecation only a compile log or a source comment carries is not a lifecycle, it is a comment. One major separates the two, so a caller has a release to move in.

There is no rollback step, and that follows from the immutability rule above rather than from an oversight: the AppImage embeds the update URL of its own tag, so a second build under the same number is an image that checks for an update to itself. A release that shipped a bad build is withdrawn and replaced with a new version. [`docs/runbooks/release-rollback.md`](docs/runbooks/release-rollback.md) is the procedure: what to decide between, `gh release delete --cleanup-tag` and why the tag has to go with it, and the bump-and-retag steps.
