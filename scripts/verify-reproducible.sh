#!/usr/bin/env bash
# Build the same source twice and diff the artifacts, so the reproducibility
# the build scripts claim is tested rather than asserted. Each pass runs in
# its own directory, under a different name, locale, timezone and
# SOURCE_DATE_EPOCH, and the two outputs must be byte-identical.
#
# Covers one WASM module (zig) and the C host sources (cc). The linked host
# needs the Wasmtime C API, so the C pass builds the host test binary, which
# compiles the same core/host sources with the same flags core/build.sh uses.
#
# Usage: bash scripts/verify-reproducible.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export LC_ALL=C
export LANG=C
export TZ=UTC

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    echo "Usage: bash scripts/verify-reproducible.sh"
    echo
    echo "  Builds one WASM module and the C host test twice, from two"
    echo "  differently named directories, under a different locale, timezone"
    echo "  and SOURCE_DATE_EPOCH, and requires the artifacts to match. Also"
    echo "  requires the module mtime a .cwasm.stamp records to be the epoch."
    exit 0
fi
if [[ $# -ne 0 ]]; then
    echo "error: unknown argument: $1" >&2
    echo "Usage: $0" >&2
    exit 2
fi

if ! command -v cc >/dev/null 2>&1; then
    echo "error: cc missing" >&2
    exit 1
fi
# Same rule as find-zig.sh: a local checkout without zig gets a note and keeps
# going, CI never passes on the skip.
# shellcheck source=find-zig.sh
. "$ROOT/scripts/find-zig.sh"
if appattic_require_zig; then
    HAVE_ZIG=1
else
    HAVE_ZIG=0
    echo "note: zig not on PATH; checking the C host only" >&2
fi

# The flags come from core/build-flags.sh, the lists core/build.sh compiles the
# shipped artifacts with, so this check cannot drift into compiling something
# the release never builds.
# shellcheck source=../core/build-flags.sh
. "$ROOT/core/build-flags.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# The two roots differ in name length on purpose: a build that leaks its own
# path into the output gives two different artifacts here.
A="$tmp/a"
B="$tmp/a-build-tree-with-a-longer-name"
mkdir -p "$A" "$B"
cp -R "$ROOT/core/src" "$A/src"
cp -R "$ROOT/core/host" "$A/host"
cp -R "$ROOT/core/src" "$B/src"
cp -R "$ROOT/core/host" "$B/host"

export ZIG_GLOBAL_CACHE_DIR="$tmp/zig-global"
export ZIG_LOCAL_CACHE_DIR="$tmp/zig-local"

# One representative WASM module, built exactly as core/build.sh builds them.
build_wasm() {
    local root="$1" out="$2"
    (cd "$root" && zig build-exe \
        "${zig_build_flags[@]}" \
        -femit-bin="$out" \
        src/core.zig)
}

build_host() {
    local root="$1" out="$2"
    appattic_host_flags "$root"
    cc "${cc_cflags[@]}" "${cc_ldflags[@]}" \
        "${cc_strict_warnings[@]}" \
        -I"$root/host" \
        "$root/host/hostexec.c" \
        "$root/host/tests/hostexec_test.c" \
        -o "$out"
}

echo "pass 1: LC_ALL=C TZ=UTC SOURCE_DATE_EPOCH=1000000000"
build_host "$A" "$tmp/host1"
if [[ "$HAVE_ZIG" -eq 1 ]]; then
    build_wasm "$A" "$tmp/core1.wasm"
fi

echo "pass 2: TZ=Asia/Tokyo SOURCE_DATE_EPOCH=1800000000"
# The subshell is what keeps pass 2's zone and epoch out of everything that
# follows, and the stamp checks below read both under their own zones.
# shellcheck disable=SC2030  # deliberately scoped to this subshell
(
    export TZ=Asia/Tokyo
    export SOURCE_DATE_EPOCH=1800000000
    build_host "$B" "$tmp/host2"
    if [[ "$HAVE_ZIG" -eq 1 ]]; then
        build_wasm "$B" "$tmp/core2.wasm"
    fi
)

compare() {
    local what="$1" one="$2" two="$3"
    if cmp -s "$one" "$two"; then
        echo "ok: $what is byte-identical across both passes"
        return 0
    fi
    echo "error: $what differs between the two builds" >&2
    if command -v diffoscope >/dev/null 2>&1; then
        diffoscope "$one" "$two" >&2 2>/dev/null || true
    fi
    echo "       the build carries something the two passes set differently:" >&2
    echo "       build path, timezone, or SOURCE_DATE_EPOCH" >&2
    return 1
}

fail=0
compare "C host test binary" "$tmp/host1" "$tmp/host2" || fail=1
if [[ "$HAVE_ZIG" -eq 1 ]]; then
    compare "core.wasm" "$tmp/core1.wasm" "$tmp/core2.wasm" || fail=1
fi

# What a precompiled image's `.cwasm.stamp` records: the module's mtime beside
# its bytes, and the stamp ships in the AppImage as file content. Writing the
# images needs the Wasmtime C API, so the two values the stamp would hold are
# checked on the module itself. core/build.sh stamps every module with the
# epoch before it compiles the images, so a stamp names the epoch and never
# the clock of the build that wrote it; a module left at its own mtime makes
# two builds of one source differ, which no archive normalization reaches.
#
# Applied and read under a timezone neither pass exports as UTC, because
# `touch -t` reads its argument in local time. Checked under TZ=UTC it passed
# against a helper that rendered the stamp in UTC and applied it in local
# time, which is the one thing that had to fail: on any host not running UTC
# the stamp it produced was hours off, and the AppImage ships that stamp as
# file content.
if [[ "$HAVE_ZIG" -eq 1 ]]; then
    for pass in 1 2; do
        if [[ "$pass" -eq 1 ]]; then
            wasm="$tmp/core1.wasm"
            epoch=1000000000
            zone=America/Los_Angeles
        else
            wasm="$tmp/core2.wasm"
            epoch=1800000000
            zone=Asia/Tokyo
        fi
        # The subshell is the point: neither TZ nor SOURCE_DATE_EPOCH may
        # escape a check that varies them per pass, and neither leak into the
        # next pass or the next script that sources this one.
        # shellcheck disable=SC2030,SC2031  # the subshell is what isolates them
        (
            export TZ="$zone"
            export SOURCE_DATE_EPOCH="$epoch"
            appattic_touch_epoch "$wasm"
            mtime="$(date -r "$wasm" +%s)"
            echo "pass $pass stamp input: size $(wc -c <"$wasm" | tr -d ' ') mtime $mtime (TZ=$zone)"
            if [[ "$mtime" != "$epoch" ]]; then
                echo "error: $wasm mtime is $mtime, not SOURCE_DATE_EPOCH $epoch (TZ=$zone)" >&2
                echo "       a .cwasm.stamp written from it would carry the build clock" >&2
                exit 1
            fi
        ) || fail=1
    done
fi
if [[ $fail -ne 0 ]]; then
    exit 1
fi
echo "reproducible: identical artifacts from a differing path, timezone and epoch"
