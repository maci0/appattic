# Specs

Architecture records. Visual rules live in [`DESIGN.md`](../../DESIGN.md).

| Document | Status | Role |
|----------|--------|------|
| [`2026-08-26-zig-wasm-core-design.md`](2026-08-26-zig-wasm-core-design.md) | Accepted | Zig WASM core and plugin ABI. Linux Qt loads this core. The Swift CLI and macOS UI still scan in `AppAtticScan`. |
| [`archive/2026-08-17-swift-scan-port-design.md`](archive/2026-08-17-swift-scan-port-design.md) | Historical | Python-to-Swift scan port. The port landed. Later CLI commands and the Zig core are outside this record. |

[`core/README.md`](../../core/README.md) points here for the host load list and the backlog. It still prints the host argv block. `scripts/lint.sh` checks that copy against the argv `core/build.sh` prints.
