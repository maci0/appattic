#!/usr/bin/env bash
# Native micro-benchmarks for the Zig core (Linux only: uses clock_gettime).
# Not part of ./core/build.sh; run on demand: ./core/bench.sh [filter-substr]
# One line per benchmark: "<name> <iters> <ns/op> <checksum>", then a final
# "sink=<n>" line so the optimizer cannot drop a benchmarked loop.
set -euo pipefail
export LC_ALL=C
export LANG=C
export TZ=UTC
if [[ "$(uname -s)" != Linux ]]; then
    echo "core/bench.sh needs Linux (std.os.linux timer)" >&2
    exit 2
fi
root=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
if ! command -v zig >/dev/null 2>&1; then
    if [ -x /opt/zig/zig ]; then export PATH="/opt/zig:$PATH"; fi
fi
export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$root/../.zig-cache}"
export ZIG_LOCAL_CACHE_DIR="${ZIG_LOCAL_CACHE_DIR:-$root/../.zig-cache-local}"
mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"
zig fmt --check "$root/bench"
# Zig 0.16 has no main-pkg-path: sibling imports resolve from the root file's
# directory, so stage the bench beside a copy of src in a scratch dir rather
# than writing a temporary source file into the tree.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cp -R "$root"/src/. "$tmp/"
cp "$root/bench/bench.zig" "$tmp/bench.zig"
out="$tmp/zigbench"
# zig 0.16 writes -femit-bin relative to the working directory; an absolute
# path outside it fails in the linker, so link from inside the scratch dir.
(cd "$tmp" && zig build-exe -OReleaseFast bench.zig -femit-bin=zigbench)
if [ -n "${1:-}" ]; then
    "$out" | grep -F -- "${1}" || true
else
    "$out"
fi
