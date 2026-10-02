#!/usr/bin/env bash
# Fast local checks (lint + Zig core tests + scan tests + CLI + reproducible
# artifacts, WASM/C and Swift).
# Full Linux CI parity: bash scripts/check.sh --qt
# No Swift toolchain, for core/src/ and core/host/ work: bash scripts/check.sh --core
# Usage: bash scripts/check.sh [--core] [--qt]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export LC_ALL=C
export LANG=C
export TZ=UTC

RUN_QT=0
RUN_SWIFT=1
for arg in "$@"; do
    case "$arg" in
        --qt) RUN_QT=1 ;;
        --core) RUN_SWIFT=0 ;;
        -h|--help)
            cat <<'EOF'
Usage: bash scripts/check.sh [--core] [--qt]

  (default)  lint + Zig core tests + the C host under ThreadSanitizer
             (scripts/race-check.sh) + AppAtticScanTests + the Swift scan
             library under ThreadSanitizer (scripts/race-check.sh --swift)
             + CLI debug build
             and the built CLI's help/exit-code/stream contract
             (scripts/cli-contract.sh), then both double-build checks
             (scripts/verify-reproducible.sh for the WASM modules and the
             C host, scripts/verify-swift-reproducible.sh for the CLI)
  --core     lint + Zig core tests + ThreadSanitizer + reproducible
             artifacts, no Swift toolchain needed. For core/src/, core/host/
             and packaging work. Not the CI gate: the Swift steps do not run,
             and the run says so.
  --qt       full Linux CI parity, including the Qt worker pools under
             ThreadSanitizer, bash scripts/linux-qt-link.sh, the
             scripts/verify-qt-link.sh proof checks, and the Qt release
             double-build (scripts/verify-qt-reproducible.sh)

  One test class instead of the suite: bash scripts/test.sh DiskSizeTests
EOF
            exit 0
            ;;
        *)
            echo "error: unknown argument: $arg" >&2
            echo "Usage: $0 [--core] [--qt]" >&2
            echo "       $0 --help" >&2
            exit 2
            ;;
    esac
done

# The macOS CI job builds only the scan library and CLI: AppAtticUI needs
# swift-cross-ui 0.2.1, which needs a Swift 6 compiler, and Swift 6.1's SIL
# lifetime pass crashes on swift-mutex 0.0.6. Match that flag so the same
# command passes here and there. build.sh keeps the UI on macOS.
if [[ "$(uname -s)" == "Darwin" ]]; then
    export APPATTIC_NO_MAC_UI=1
fi

# --core is for a contributor editing core/src/, core/host/ or packaging, who
# has zig, cc and shellcheck but not a Swift 5.10.1 toolchain. None of the
# steps below need it, and requiring it first would leave the gate unreachable
# for exactly the work it was written to cover.
if [[ "$RUN_SWIFT" -eq 1 ]]; then
    # shellcheck source=find-swift.sh
    . "$ROOT/scripts/find-swift.sh"
    appattic_require_swift
fi

echo "== lint =="
bash "$ROOT/scripts/lint.sh"

# The Zig core has its own suite, and CI reaches it through the Qt link. Run it
# here too, so a contributor editing core/src/ has a gate without Qt 6 or
# Wasmtime installed.
echo "== Zig core =="
# shellcheck source=find-zig.sh
. "$ROOT/scripts/find-zig.sh"
if appattic_require_zig; then
    bash "$ROOT/core/build.sh" test-core
fi

# The host applies and restores the process PATH from the thread that runs a
# scan, so core/host has threaded code, and a sanitizer run is the only thing
# that sees an interleaving the assertions happen to survive. It needs a C
# compiler and nothing else, which is what --core already assumes.
echo "== ThreadSanitizer (C host) =="
bash "$ROOT/scripts/race-check.sh"

if [[ "$RUN_SWIFT" -eq 1 ]]; then
    # shellcheck source=swift-build.sh
    . "$ROOT/scripts/swift-build.sh"

    echo "== AppAtticScanTests =="
    bash "$ROOT/scripts/test.sh"

    echo "== ThreadSanitizer (Swift scan library) =="
    # The pmap fan-out is the third threaded tree, and the one no other
    # sanitizer run reaches: the C host and the Qt pools are the other two.
    # ScanConcurrencyTests pins the serialized progress callback and names
    # `swift test --sanitize=thread` as what turns those assertions into
    # memory-ordering evidence, and nothing ran it.
    bash "$ROOT/scripts/race-check.sh" --swift

    echo "== CLI debug =="
    appattic_swift_build debug --product appattic

    # The built binary answers `--help`, exit codes, and which stream a result
    # lands on. Running it is the only way to see a stream mix-up, and a
    # script consuming this CLI breaks on one silently.
    echo "== CLI contract =="
    bash "$ROOT/scripts/cli-contract.sh"
fi

# Two builds of the same source, diffed. Cheap next to the Zig suite and it
# is the only check that would notice a build path or timestamp leaking into
# an artifact.
echo "== reproducible artifacts =="
bash "$ROOT/scripts/verify-reproducible.sh"

if [[ "$RUN_SWIFT" -eq 1 ]]; then
    # The same check for the Swift product. Two release builds, which is
    # minutes rather than seconds, so it runs here and in CI but not in the
    # --core path a contributor runs in a loop.
    echo "== reproducible Swift CLI =="
    bash "$ROOT/scripts/verify-swift-reproducible.sh"
fi

if [[ "$RUN_QT" -eq 1 ]]; then
    # The Qt window walks disk directories on a worker pool and measures
    # leftover sizes on another, so it has the same threaded code under the
    # same argument. Reuses the Qt 6 and Wasmtime already required here.
    echo "== ThreadSanitizer (Qt worker pools) =="
    bash "$ROOT/scripts/race-check.sh" --qt

    echo "== Qt UI link =="
    bash "$ROOT/scripts/linux-qt-link.sh"
    bash "$ROOT/scripts/verify-qt-link.sh"

    echo "== reproducible Qt release binary =="
    # The third double-build, and the one that covers the binary
    # scripts/linux-appimage.sh packs into the AppImage. The other two cover
    # the WASM modules and the Swift CLI, and neither reaches this one.
    bash "$ROOT/scripts/verify-qt-reproducible.sh"
else
    echo "note: skip Qt UI (pass --qt). CI Linux jobs run scripts/linux-qt-link.sh"
fi

# A green --core must never be read as a full pass, so the skipped steps are
# named on the last line of the run rather than only in --help.
if [[ "$RUN_SWIFT" -eq 0 ]]; then
    echo "note: --core did NOT run AppAtticScanTests, the Swift scan library under"
    echo "      ThreadSanitizer, or the CLI build, and did not run the Qt worker"
    echo "      pools under ThreadSanitizer (pass --qt). That is the CI gate; run"
    echo "      'bash scripts/check.sh' once Swift is installed, or push and let CI run it."
fi
