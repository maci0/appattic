#!/usr/bin/env bash
# Swift CLI (appattic). --ui launches AppAttic.app / AppAtticUI on macOS,
# or appattic-qt (C++ Qt 6) on Linux.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APPATTIC_OS="$(uname -s)"

# `stat`'s two spellings for the same field, decided by what the host's own
# `stat` accepts rather than by what `uname` calls it: GNU takes `-c %Y`, BSD
# and macOS take `-f %m`, and `stat` is the one command here that differs by
# libc rather than by kernel. Sending every host not spelled Darwin to the GNU
# flag fails quietly, not loudly -- `stat` writes to stderr, returns nothing,
# and an empty result compares as 0 against an initial best_mtime of 0, so
# every candidate ties, `>=` keeps the first, and `find_bin` below launches the
# older build with nothing but a stray error on stderr. The stat portability
# check in scripts/lint.sh drives both spellings and asserts which build won.
# The probe runs once, against a file this script has already found, and a
# stat offering neither spelling is reported rather than read as "epoch 0".
APPATTIC_STAT_FLAG=""
file_mtime() {
    if [[ -z "$APPATTIC_STAT_FLAG" ]]; then
        if stat -c %Y "$1" >/dev/null 2>&1; then
            APPATTIC_STAT_FLAG=(-c %Y)
        elif stat -f %m "$1" >/dev/null 2>&1; then
            APPATTIC_STAT_FLAG=(-f %m)
        else
            echo "error: this host's stat has neither the GNU (-c) nor the BSD (-f) spelling" >&2
            return 1
        fi
    fi
    stat "${APPATTIC_STAT_FLAG[@]}" "$1"
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
        # build-release/ first: it is the tree ./build.sh release and the
        # AppImage link into, so it is the binary a release build produced.
        for qt in \
            "$ROOT/ui/linux-qt/build-release/appattic-qt" \
            "$ROOT/ui/linux-qt/build/appattic-qt" \
            "$ROOT/ui/linux-qt/build/Debug/appattic-qt"; do
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
    # No build yet: the CLI's own help is not on disk, so send the contributor
    # the same command list ./build.sh --help prints instead of a bare stub.
    cat <<'EOF'
Usage: ./run.sh [command] [options]
       ./run.sh --ui [qt-args]

appattic is not built yet. Build it, then this is the appattic CLI.
EOF
    echo
    exec "$ROOT/build.sh" --help
fi

BIN="$(find_bin appattic)" || {
    echo "error: appattic CLI not found. Build with ./build.sh first." >&2
    exit 1
}
exec "$BIN" "$@"
