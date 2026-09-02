#!/usr/bin/env bash
# Shellcheck, hostexec warnings-as-errors, and zig fmt when zig is on PATH.
# Usage: bash scripts/lint.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export LC_ALL=C
export LANG=C
export TZ=UTC

case "${1:-}" in
    -h|--help)
        cat <<'EOF'
Usage: bash scripts/lint.sh

  shellcheck on build/run scripts, hostexec warnings-as-errors, zig fmt --check
EOF
        exit 0
        ;;
    "")
        ;;
    *)
        echo "error: unknown argument: $1" >&2
        echo "Usage: bash scripts/lint.sh" >&2
        exit 2
        ;;
esac

if ! command -v shellcheck >/dev/null 2>&1; then
    echo "error: shellcheck missing" >&2
    exit 1
fi
shellcheck -x -P SCRIPTDIR "$ROOT/build.sh" "$ROOT/run.sh" "$ROOT/core/build.sh" "$ROOT/scripts"/*.sh

if ! command -v cc >/dev/null 2>&1; then
    echo "error: cc missing" >&2
    exit 1
fi
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cc -O2 -Wall -Wextra -Werror -Wformat=2 -Wformat-security \
    -Wshadow -Wstrict-prototypes -Wconversion -Wpedantic -Wnull-dereference \
    -I "$ROOT/core/host" \
    "$ROOT/core/host/hostexec.c" \
    "$ROOT/core/host/hostexec_test.c" \
    -o "$tmp/hostexec_test"
case "$(uname -s)" in
    Linux) APPATTIC_HOST_EXEC_FIXTURE=1 "$tmp/hostexec_test" ;;
    *) "$tmp/hostexec_test" ;;
esac

if ! command -v zig >/dev/null 2>&1; then
    if [[ -x /opt/zig/zig ]]; then
        export PATH="/opt/zig:${PATH:-}"
    elif [[ -x /usr/local/bin/zig ]]; then
        export PATH="/usr/local/bin:${PATH:-}"
    elif [[ -x "$ROOT/.deps/zig/zig" ]]; then
        export PATH="$ROOT/.deps/zig:${PATH:-}"
    fi
fi
if command -v zig >/dev/null 2>&1; then
    zig fmt --check "$ROOT/core/src"
else
    echo "note: zig not on PATH, skip zig fmt --check" >&2
fi
