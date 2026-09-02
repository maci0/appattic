# Contributing

Setup, tests, and layout: [README.md](README.md).

```bash
./build.sh --help
bash scripts/check.sh          # lint + AppAtticScanTests + CLI (CI parity)
bash scripts/check.sh --qt     # also Linux Qt UI proof
swift test --filter UtilTests --disable-automatic-resolution
./core/build.sh test brew.zig
```

PRs run `.github/workflows/linux.yml` (lint, Ubuntu tests, jammy, archlinux Qt link). Match those flags locally: `--disable-automatic-resolution` on `swift test` / `swift build`.

Swift 5.10.1 is `.swift-version`. Zig 0.16.0 is `.zig-version`. `./build.sh` fails with a named error if `swift` is missing; it also looks in `/opt/swift/usr/bin` and `.deps/swift/usr/bin`.
