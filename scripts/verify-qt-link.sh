#!/usr/bin/env bash
# Assert the Linux Qt 6 link proof scripts/linux-qt-link.sh just wrote.
# CI jobs, the Dockerfiles, and scripts/check.sh --qt all run this so the
# acceptance criteria exist once, not per pipeline.
# Usage: bash scripts/verify-qt-link.sh [path/to/LINUX_QT_LINK.txt]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROOF="${1:-$ROOT/ui/linux-qt/build/LINUX_QT_LINK.txt}"

for arg in "$@"; do
    case "$arg" in
        -h|--help)
            cat <<'EOF'
Usage: bash scripts/verify-qt-link.sh [path/to/LINUX_QT_LINK.txt]

  Checks the Qt 6 link proof for the link, offscreen smoke, the path-shadow
  plugin, a non-zero WASM plugin count, and the table teardown counters.
  Defaults to ui/linux-qt/build/LINUX_QT_LINK.txt.
EOF
            exit 0
            ;;
    esac
done

if [[ ! -f "$PROOF" ]]; then
    echo "error: no Qt link proof at $PROOF" >&2
    echo "       run scripts/linux-qt-link.sh first" >&2
    exit 1
fi

check() {
    local pattern="$1"
    local what="$2"
    if ! grep -Eq "$pattern" "$PROOF"; then
        echo "error: Qt link proof has no $what" >&2
        echo "       expected /$pattern/ in $PROOF" >&2
        exit 1
    fi
}

check '^LINUX_QT_LINK=ok$' 'LINUX_QT_LINK=ok'
check '^LINUX_QT_SMOKE=ok$' 'LINUX_QT_SMOKE=ok'
check '^plugin:path-shadow$' 'the path-shadow plugin line'
check '^wasm: ok \([1-9][0-9]* plugins\)$' 'a non-zero WASM plugin count'
check '^tables: ok \(leftovers=[1-9][0-9]* stale=[0-9]+' 'the table teardown counters'

echo "qt link proof ok: $PROOF"
