#!/usr/bin/env bash
# Swift CLI (appattic). --ui launches AppAttic.app / AppAtticUI on macOS,
# or appattic-qt (C++ Qt 6) on Linux.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APPATTIC_OS="$(uname -s)"

file_mtime() {
    if [[ "$APPATTIC_OS" == Darwin ]]; then
        stat -f %m "$1"
    else
        stat -c %Y "$1"
    fi
}

find_bin() {
    local name="$1"
    local config c best="" best_mtime=0 mtime
    shopt -s nullglob
    for config in release debug; do
        for c in "${ROOT}/.build/${config}/${name}" "${ROOT}/.build/"*"/${config}/${name}"; do
            if [[ -f "$c" && -x "$c" ]]; then
                mtime=$(file_mtime "$c")
                if [[ "$mtime" -ge "$best_mtime" ]]; then
                    best="$c"
                    best_mtime="$mtime"
                fi
            fi
        done
    done
    shopt -u nullglob
    if [[ -n "$best" ]]; then
        printf '%s\n' "$best"
        return 0
    fi
    return 1
}

if [[ "${1:-}" == "--ui" ]]; then
    shift
    if [[ "$APPATTIC_OS" == Linux ]]; then
        export APPATTIC_CORE_OUT="${APPATTIC_CORE_OUT:-$ROOT/core/out}"
        for qt in "$ROOT/ui/linux-qt/build/appattic-qt" "$ROOT/ui/linux-qt/build/Debug/appattic-qt"; do
            if [[ -x "$qt" ]]; then
                exec "$qt" "$@"
            fi
        done
        echo "error: appattic-qt not found. Build with ./build.sh or bash scripts/linux-qt-link.sh." >&2
        echo "Linux UI needs Qt 6 Widgets (qt6-base-dev / qt6-qtbase-devel / qt6-base)." >&2
        exit 1
    fi
    APP=""
    APP_MTIME=0
    if [[ "$APPATTIC_OS" == Darwin && -x "$ROOT/AppAttic.app/Contents/MacOS/AppAttic" ]]; then
        APP="$ROOT/AppAttic.app/Contents/MacOS/AppAttic"
        APP_MTIME=$(file_mtime "$APP")
    fi
    BIN=""
    BIN_MTIME=0
    if BIN="$(find_bin AppAtticUI)"; then
        BIN_MTIME=$(file_mtime "$BIN")
    else
        BIN=""
    fi
    if [[ -n "$APP" && "$APP_MTIME" -ge "$BIN_MTIME" ]]; then
        exec "$APP" "$@"
    fi
    if [[ -n "$BIN" ]]; then
        exec "$BIN" "$@"
    fi
    echo "error: AppAttic UI binary not found. Build with ./build.sh first." >&2
    exit 1
fi

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    if BIN="$(find_bin appattic)"; then
        exec "$BIN" "$@"
    fi
    cat <<'EOF'
Usage: ./run.sh [command] [options]
       ./run.sh --ui [qt-args]

Build with ./build.sh first. After a build, this is the appattic CLI.
EOF
    exit 0
fi

BIN="$(find_bin appattic)" || {
    echo "error: appattic CLI not found. Build with ./build.sh first." >&2
    exit 1
}
exec "$BIN" "$@"
