# shellcheck shell=bash
# shellcheck disable=SC2154  # ROOT is set by every script that sources this one
# Sourced by scripts/linux-appimage.sh and scripts/linux-qt-link.sh. Requires ROOT.
# Sets WASMTIME_DIR; the caller reports the failure so its own message names
# the flag that installs the missing headers.

appattic_find_wasmtime() {
    if [[ -n "${WASMTIME_DIR:-}" && ! -f "$WASMTIME_DIR/include/wasmtime.h" ]]; then
        return 1
    fi
    if [[ -n "${WASMTIME_DIR:-}" ]]; then
        return 0
    fi
    local d
    for d in /opt/wasmtime-c-api "$ROOT/.deps/wasmtime-c-api" /usr/local; do
        if [[ -f "$d/include/wasmtime.h" ]]; then
            export WASMTIME_DIR="$d"
            return 0
        fi
    done
    return 1
}
