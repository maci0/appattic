#!/usr/bin/env bash
# Build the same source twice and diff the artifacts, so the reproducibility
# the build scripts claim is tested rather than asserted. Each pass runs in
# its own directory, under a different name, locale, timezone and
# SOURCE_DATE_EPOCH, and the two outputs must be byte-identical.
#
# Covers every WASM module core/build.sh ships (zig) and the C host. The linked
# host needs the Wasmtime C API, so the C pass builds the host test binary,
# which compiles the same core/host sources with the same flags core/build.sh
# uses.
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
    echo "  Builds every WASM module core/build.sh ships, and the C host test,"
    echo "  twice, from two differently named directories, under a different"
    echo "  locale, timezone and SOURCE_DATE_EPOCH, and requires every artifact"
    echo "  to match. Also requires the module mtime a .cwasm.stamp records to"
    echo "  be the epoch."
    exit 0
fi
if [[ $# -ne 0 ]]; then
    echo "error: unknown argument: $1" >&2
    echo "Usage: $0" >&2
    echo "       $0 --help" >&2
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

# Every shipped module, built exactly as core/build.sh builds them.
#
# core.zig on its own proves almost nothing. It is four lines that import
# abi.zig, emit one constant, and come out at 81 bytes: no std, no string
# data, no comptime table, nothing a timestamp, a build path or a hash-map
# iteration order could get into.
#
# Checking one plugin instead of all of them was a sampling argument, not a
# proof: apt.zig was picked as the second-largest module, on the theory that a
# leaked path or an unsorted map would show there first. Nothing ties the leak
# to size. Each plugin links a different slice of the shared tree, so a
# nondeterminism reached through path_listing.zig is compiled into the plugins
# that import it and into none of the ones that do not, and the gate could sit
# on a green sample while the module that actually carries the leak shipped
# unchecked.
#
# The whole set costs a few seconds of wall clock, so coverage is the default
# and sampling is not. The list is read out of core/build.sh rather than
# restated here, because a plugin added to the build and not to this gate is
# exactly the artifact that would go unchecked: core/build.sh is the only
# place that knows what ships.
repro_modules() {
    # The `wasm_sources=( ... )` array, whichever way it is laid out. The
    # closing paren on its own line is how core/build.sh writes it today, but a
    # range that only stops at `^)$` reads nothing once someone collapses the
    # array onto one line. So: take the opening line, then every following
    # line up to and including the first that closes with `)`, then drop the
    # `wasm_sources=(` and the trailing `)` and read what is left.
    awk '
        /^wasm_sources=\(/ { inside = 1 }
        inside {
            line = $0
            sub(/^[^()]*\(/, "", line)
            sub(/\)[^()]*$/, "", line)
            print line
        }
        inside && /\)/ { inside = 0 }
    ' "$ROOT/core/build.sh" \
        | sed -e 's/#.*//' | tr -s '[:space:]' '\n' | grep -E '\.zig$'
}
REPRO_MODULES=()
while IFS= read -r m; do
    REPRO_MODULES+=("$m")
done < <(repro_modules)
# A count the tree cannot narrow itself past. Anything a reader would call
# "a sample" is caught here instead of being read as coverage: core.zig plus
# one plugin is what this gate used to check, and it is a sample. The floor is
# deliberately under the current 28 so adding a plugin needs no edit here,
# but dropping below it means the list stopped being what ships.
if [[ "${#REPRO_MODULES[@]}" -lt 20 ]]; then
    echo "error: read ${#REPRO_MODULES[@]} module(s) from core/build.sh wasm_sources;" >&2
    echo "       expected the whole shipped list, so this gate cannot narrow itself" >&2
    exit 1
fi

build_wasm() {
    local root="$1" out="$2"
    (cd "$root" && zig build-exe \
        "${zig_build_flags[@]}" \
        -femit-bin="$out" \
        "src/$3")
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

# Build every module into "$out", one process each, at most $JOBS in flight.
# The wait is in list order so a failed module names itself, the rule
# core/build.sh's run_modules follows for the same reason.
JOBS="$( (command -v nproc >/dev/null 2>&1 && nproc) \
    || (command -v sysctl >/dev/null 2>&1 && sysctl -n hw.ncpu) || printf 1)"
case "$JOBS" in
    '' | *[!0-9]*) JOBS=1 ;;
    *) ;;
esac
[ "$JOBS" -gt 1 ] || JOBS=1

build_all() {
    local root="$1" tag="$2"
    local m reaped=0 rc=0
    local -a pids=() names=()
    for m in "${REPRO_MODULES[@]}"; do
        build_wasm "$root" "$tmp/${m%.zig}.$tag.wasm" "$m" &
        pids+=("$!")
        names+=("$m")
        while [ "$(( ${#pids[@]} - reaped ))" -ge "$JOBS" ]; do
            if ! wait "${pids[$reaped]}"; then
                echo "error: ${names[$reaped]} failed to build" >&2
                rc=1
            fi
            reaped=$((reaped + 1))
        done
    done
    while [ "$reaped" -lt "${#pids[@]}" ]; do
        if ! wait "${pids[$reaped]}"; then
            echo "error: ${names[$reaped]} failed to build" >&2
            rc=1
        fi
        reaped=$((reaped + 1))
    done
    return "$rc"
}

echo "pass 1: LC_ALL=C TZ=UTC SOURCE_DATE_EPOCH=1000000000"
build_host "$A" "$tmp/host1"
if [[ "$HAVE_ZIG" -eq 1 ]]; then
    build_all "$A" 1
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
        build_all "$B" 2
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
    for m in "${REPRO_MODULES[@]}"; do
        compare "$m" "$tmp/${m%.zig}.1.wasm" "$tmp/${m%.zig}.2.wasm" || fail=1
    done
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
            wasm="$tmp/core.1.wasm"
            epoch=1000000000
            zone=America/Los_Angeles
        else
            wasm="$tmp/core.2.wasm"
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
echo "reproducible: ${#REPRO_MODULES[@]} WASM modules and the C host are identical from a differing path, timezone and epoch"
