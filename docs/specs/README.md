# Specs

Requirement and architecture records. Visual rules live in [`DESIGN.md`](../../DESIGN.md).

| Document | Status | Role |
|----------|--------|------|
| [`2026-08-26-zig-wasm-core-design.md`](2026-08-26-zig-wasm-core-design.md) | Accepted | Zig WASM core + plugin ABI; Linux Qt loads this core |
| [`archive/2026-08-17-swift-scan-port-design.md`](archive/2026-08-17-swift-scan-port-design.md) | Implemented, superseded | Python to Swift scan port; replaced by the record above |

Superseded records live in [`archive/`](archive/) and are kept for history.

These records are canonical. [`core/README.md`](../../core/README.md) links here for the host load list and the backlog rather than restating them; it still shows the host argv block as a copy, which `scripts/lint.sh` holds against the argv `core/build.sh` prints, so the two cannot disagree unnoticed.
