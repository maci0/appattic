# Contributing

Setup, tests, and layout: [README.md](README.md).

```bash
./build.sh --help
bash scripts/check.sh          # fast: lint + Zig core + AppAtticScanTests + CLI
bash scripts/check.sh --qt     # full Linux CI parity, including Qt/WASM proof
swift test --filter DiskSizeTests --disable-automatic-resolution
./core/build.sh test brew.zig
./core/build.sh test-core
```

PRs run `.github/workflows/linux.yml` (lint, Ubuntu tests, jammy, archlinux Qt link). Match those flags locally: `--disable-automatic-resolution` on `swift test` / `swift build`, and `APPATTIC_NO_MAC_UI=1` on macOS (`scripts/check.sh` sets it for you). The lint job checks out full history so `scripts/lint.sh` can reject AI tool credits in commit messages; a shallow clone sees fewer commits and says how many.

Missing tools: `bash scripts/linux-deps.sh` prints what the distro needs, `--install-shellcheck` installs the one `scripts/lint.sh` cannot do without.

`bash scripts/lint.sh` needs `shellcheck`, `yamllint`, and the pinned Zig on PATH (`bash scripts/linux-deps.sh --install-zig`). CI installs the yamllint version pinned in `scripts/deps.sh`; `scripts/deps.sh check` fails when the workflow and that pin disagree. Zig always comes from the checksummed `.zig-version` tarball, never from a distro package, so `zig fmt --check` sees the pinned version. Outside CI a missing Zig skips `zig fmt --check`; in CI it fails the run.

Swift 5.10.1 is `.swift-version`. Zig 0.16.0 is `.zig-version`. `./build.sh` fails with a named error if `swift` is missing; it also looks in `/opt/swift/usr/bin` and `.deps/swift/usr/bin`.

## Releasing

The version is declared in one file and copied into three others, and `bash scripts/check-version.sh` fails when any of them disagree. It runs in `scripts/lint.sh`, so CI catches a partial bump. Bump all of them in one commit:

- `Sources/AppAtticScan/Version.swift`, `appAtticVersion` (what `appattic --version` prints, and what `ui/linux-qt/CMakeLists.txt` reads at configure time for `APPATTIC_VERSION`)
- `packaging/org.appattic.AppAttic.metainfo.xml`, a new `<release>` with its date and a consumer-facing `<description>`
- `packaging/Info.plist`, `CFBundleShortVersionString` (what macOS reads; `build.sh` copies the file into `AppAttic.app` unchanged). Its `CFBundleVersion` is the build number beside that version, not the version itself: raise it on every release, including patches, or macOS treats the new bundle as the one already installed.
- `packaging/appattic-qt.1`, the `.TH` version line (the man page for the Qt window)

The AppStream `<description>` is the only release note shipped to users, so a release without one is a silent release. The `v*` tag is the release trigger; the workflow refuses to build a tag that does not match the declared version. Minor bumps carry new features, patch bumps carry fixes, and a breaking change to the CLI, JSON output, or cache format goes out as a major.

