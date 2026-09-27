#!/usr/bin/env bash
# Assert the Linux Qt 6 link proof scripts/linux-qt-link.sh just wrote.
# CI jobs, the Dockerfiles, and scripts/check.sh --qt all run this so the
# acceptance criteria exist once, not per pipeline.
# Usage: bash scripts/verify-qt-link.sh [path/to/LINUX_QT_LINK.txt]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# The proof lands in the build tree of the config that produced it, so the
# default has to follow the config: a caller that linked release would otherwise
# verify the debug proof left over from an earlier run.
if [[ $# -gt 0 ]]; then
    case "$1" in
        release) PROOF="$ROOT/ui/linux-qt/build-release/LINUX_QT_LINK.txt" ;;
        debug) PROOF="$ROOT/ui/linux-qt/build/LINUX_QT_LINK.txt" ;;
        *) PROOF="$1" ;;
    esac
else
    PROOF="$ROOT/ui/linux-qt/build/LINUX_QT_LINK.txt"
fi

for arg in "$@"; do
    case "$arg" in
        -h|--help)
            cat <<'EOF'
Usage: bash scripts/verify-qt-link.sh [release|debug|path/to/LINUX_QT_LINK.txt]

  Checks the Qt 6 link proof for the link, offscreen smoke, the path-shadow
  plugin, a non-zero WASM plugin count, and the table teardown counters.
  A config name reads that config's proof; a path is read as given.
  Defaults to ui/linux-qt/build/LINUX_QT_LINK.txt.
EOF
            exit 0
            ;;
        -*)
            echo "error: unknown argument: $arg" >&2
            echo "Usage: bash scripts/verify-qt-link.sh [release|debug|path/to/LINUX_QT_LINK.txt]" >&2
            exit 2
            ;;
    esac
done

# Only the first argument names the proof, and the loop above scans the rest for
# -h. A second path would be dropped, so a typo in it verifies the wrong file.
if [[ $# -gt 1 ]]; then
    echo "error: unexpected argument: $2" >&2
    echo "Usage: bash scripts/verify-qt-link.sh [path/to/LINUX_QT_LINK.txt]" >&2
    exit 2
fi

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
