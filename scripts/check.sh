#!/usr/bin/env bash
# Fast local checks (lint + scan tests + CLI).
# Full Linux CI parity: bash scripts/check.sh --qt
# Usage: bash scripts/check.sh [--qt]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export LC_ALL=C
export LANG=C
export TZ=UTC

RUN_QT=0
for arg in "$@"; do
    case "$arg" in
        --qt) RUN_QT=1 ;;
        -h|--help)
            cat <<'EOF'
Usage: bash scripts/check.sh [--qt]

  (default)  lint + AppAtticScanTests + CLI debug build
  --qt       full Linux CI parity, including bash scripts/linux-qt-link.sh
EOF
            exit 0
            ;;
        *)
            echo "error: unknown argument: $arg" >&2
            echo "Usage: $0 [--qt]" >&2
            exit 2
            ;;
    esac
done

# shellcheck source=find-swift.sh
. "$ROOT/scripts/find-swift.sh"
appattic_require_swift

# The macOS CI job builds only the scan library and CLI: AppAtticUI needs
# swift-cross-ui 0.2.1, which needs a Swift 6 compiler, and Swift 6.1's SIL
# lifetime pass crashes on swift-mutex 0.0.6. Match that flag so the same
# command passes here and there. build.sh keeps the UI on macOS.
if [[ "$(uname -s)" == "Darwin" ]]; then
    export APPATTIC_NO_MAC_UI=1
fi

echo "== lint =="
bash "$ROOT/scripts/lint.sh"

echo "== AppAtticScanTests =="
swift test --filter AppAtticScanTests --disable-automatic-resolution

echo "== CLI debug =="
swift build -c debug --product appattic --disable-automatic-resolution

if [[ "$RUN_QT" -eq 1 ]]; then
    echo "== Qt UI link =="
    bash "$ROOT/scripts/linux-qt-link.sh"
else
    echo "note: skip Qt UI (pass --qt). CI Linux jobs run scripts/linux-qt-link.sh"
fi
