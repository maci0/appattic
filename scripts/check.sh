#!/usr/bin/env bash
# Fast local checks (lint + Zig core tests + scan tests + CLI).
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

  (default)  lint + Zig core tests + AppAtticScanTests + CLI debug build
  --core     lint + Zig core tests + reproducible artifacts, no Swift
             toolchain needed. For core/src/, core/host/ and packaging work.
             Not the CI gate: the Swift steps do not run, and the run says so.
  --qt       full Linux CI parity, including bash scripts/linux-qt-link.sh
             and the scripts/verify-qt-link.sh proof checks

  One test class instead of the suite: bash scripts/test.sh DiskSizeTests
EOF
            exit 0
            ;;
        *)
            echo "error: unknown argument: $arg" >&2
            echo "Usage: $0 [--core] [--qt]" >&2
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

if [[ "$RUN_SWIFT" -eq 1 ]]; then
    echo "== AppAtticScanTests =="
    bash "$ROOT/scripts/test.sh"

    echo "== CLI debug =="
    swift build -c debug --product appattic --disable-automatic-resolution
fi

# Two builds of the same source, diffed. Cheap next to the Zig suite and it
# is the only check that would notice a build path or timestamp leaking into
# an artifact.
echo "== reproducible artifacts =="
bash "$ROOT/scripts/verify-reproducible.sh"

if [[ "$RUN_QT" -eq 1 ]]; then
    echo "== Qt UI link =="
    bash "$ROOT/scripts/linux-qt-link.sh"
    bash "$ROOT/scripts/verify-qt-link.sh"
else
    echo "note: skip Qt UI (pass --qt). CI Linux jobs run scripts/linux-qt-link.sh"
fi

# A green --core must never be read as a full pass, so the skipped steps are
# named on the last line of the run rather than only in --help.
if [[ "$RUN_SWIFT" -eq 0 ]]; then
    echo "note: --core did NOT run AppAtticScanTests or the CLI build. That is the CI gate;"
    echo "      run 'bash scripts/check.sh' once Swift is installed, or push and let CI run it."
fi
