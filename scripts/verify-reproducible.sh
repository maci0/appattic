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
    echo "  and SOURCE_DATE_EPOCH, and requires the artifacts to match."
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

# This list mirrors the one in core/build.sh. A flag added there and missed
# here is a check that no longer proves what it says, so assert the hardening
# flags are still there before running.
# shellcheck disable=SC2016  # literal text to grep for, not an expansion
for flag in '-ffile-prefix-map=$root=.' '-D_FORTIFY_SOURCE=2' '-Wl,-z,relro,-z,now'; do
    if ! grep -qF -- "$flag" "$ROOT/core/build.sh"; then
        echo "error: core/build.sh no longer carries '$flag'" >&2
        echo "       keep build_host() in $0 in step with it" >&2
        exit 1
    fi
done

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
        -target wasm32-freestanding \
        -fno-entry \
        -rdynamic \
        -OReleaseSmall \
        -fstrip \
        -femit-bin="$out" \
        src/core.zig)
}

# core/build.sh's cc flag block, with $root resolved to the tree being built.
build_host() {
    local root="$1" out="$2"
    local -a cflags=(-O2 -Wall -Wextra -fstack-protector-strong
        -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=2 -fPIE
        "-ffile-prefix-map=$root=." "-fdebug-prefix-map=$root=." "-fmacro-prefix-map=$root=.")
    local -a ldflags=()
    case "$(uname -s)" in
        Linux)
            ldflags=(-pie "-Wl,-z,relro,-z,now" "-Wl,-z,noexecstack")
            cflags+=(-fstack-clash-protection)
            case "$(uname -m)" in
                x86_64)
                    cflags+=(-fcf-protection=full)
                    ldflags+=(-fcf-protection=full)
                    ;;
                aarch64|arm64)
                    cflags+=(-mbranch-protection=standard)
                    ;;
            esac
            ;;
        Darwin) ldflags=("-Wl,-pie") ;;
        *) ldflags=(-pie) ;;
    esac
    cc "${cflags[@]}" "${ldflags[@]}" \
        -Werror -Wformat=2 -Wformat-security \
        -Wshadow -Wstrict-prototypes -Wconversion -Wpedantic -Wnull-dereference \
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
if [[ $fail -ne 0 ]]; then
    exit 1
fi
echo "reproducible: identical artifacts from a differing path, timezone and epoch"
