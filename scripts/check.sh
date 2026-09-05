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
