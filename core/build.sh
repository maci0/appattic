#!/usr/bin/env bash
# WASM core + plugins + host.
# Usage: ./core/build.sh [test <name.zig> | test-core]
set -euo pipefail
export LC_ALL=C
export LANG=C
export TZ=UTC

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    echo "Usage: $0 [test <name.zig> | test-core]"
    echo "  (no args)          WASM + all zig tests + host (needs wasmtime C API)"
    echo "  test brew.zig      one plugin (fast edit loop)"
    echo "  test-core          zig fmt --check + every zig test (no wasmtime, no Qt)"
    exit 0
fi

if [ "${1:-}" = "test" ] && [ -z "${2:-}" ]; then
    echo "error: missing plugin name" >&2
    echo "Usage: $0 test <name.zig>" >&2
    echo "example: $0 test brew.zig" >&2
    exit 2
fi

if [ -n "${1:-}" ] && [ "${1:-}" != "test" ] && [ "${1:-}" != "test-core" ]; then
    echo "error: unknown argument: $1" >&2
    echo "Usage: $0 [test <name.zig> | test-core]" >&2
    echo "       $0 --help" >&2
    exit 2
fi

if [[ -z "${SOURCE_DATE_EPOCH:-}" ]]; then
    SOURCE_DATE_EPOCH="$(git -C "$(dirname -- "$0")" log -1 --pretty=%ct 2>/dev/null || printf '0')"
    export SOURCE_DATE_EPOCH
fi
root=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
out="$root/out"
mkdir -p "$out"

export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$root/../.zig-cache}"
export ZIG_LOCAL_CACHE_DIR="${ZIG_LOCAL_CACHE_DIR:-$root/../.zig-cache-local}"
mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"

# shellcheck source=../scripts/find-zig.sh
. "$root/../scripts/find-zig.sh"
if ! appattic_find_zig; then
    echo "zig missing. macOS: brew install zig. Linux: scripts/linux-deps.sh --install-zig" >&2
    echo "Then re-run $0" >&2
    exit 1
fi
if [ ! -f "$root/../.zig-version" ]; then
    echo "error: missing $root/../.zig-version; the required Zig version is declared there, not guessed here" >&2
    exit 1
fi
zig_need="$(tr -d '[:space:]' < "$root/../.zig-version")"
if [ -z "$zig_need" ]; then
    echo "error: empty $root/../.zig-version" >&2
    exit 1
fi
zig_ver="$(zig version)"
if [ "$zig_ver" != "$zig_need" ]; then
    echo "error: need zig $zig_need from .zig-version (have $zig_ver). scripts/linux-deps.sh --install" >&2
    exit 1
fi

if [ "${1:-}" = "test" ]; then
    name="${2##*/}"
    name="${name%.zig}.zig"
    if [ ! -f "$root/src/$name" ]; then
        echo "error: no $root/src/$name" >&2
        exit 1
    fi
    zig fmt --check "$root/src/$name"
    zig test "$root/src/$name"
    exit 0
fi

# One source per WASM artifact. core.zig is renamed appattic_core.wasm for the host.
wasm_sources=(
    core.zig
    container_runtime.zig snapd.zig
    path_xdg_config.zig path_xdg_data.zig path_xdg_cache.zig path_xdg_state.zig
    path_xdg_lib.zig path_var_app.zig path_user_bin.zig path_home_dot.zig path_shadow.zig
    pacman.zig aur.zig apt.zig dnf.zig zypper.zig flatpak.zig
    npm.zig pnpm.zig bun.zig pipx.zig uv.zig brew.zig gem.zig composer.zig pip.zig deno.zig
)

test_modules=(
    host_exec.zig jsonbuf.zig jsonscan.zig path_listing.zig guarded_remove.zig path_store.zig
)
# Every WASM artifact is unit-tested too, derived from wasm_sources so adding a
# plugin cannot silently skip its tests.
for src in "${wasm_sources[@]}"; do
    if [ "$src" != "core.zig" ]; then test_modules+=("$src"); fi
done

zig_test() {
    zig test "$root/src/$1"
}

# A zig test on one small plugin is a second or two of mostly compiler startup,
# so the suite is latency bound and a serial loop leaves every core but one
# idle. One module per process, this many at a time. A core is held back from
# the count so the editor and the test runner still have somewhere to run.
detect_jobs() {
    local n=1
    if command -v nproc >/dev/null 2>&1; then
        n="$(nproc 2>/dev/null || printf 1)"
    elif command -v sysctl >/dev/null 2>&1; then
        n="$(sysctl -n hw.ncpu 2>/dev/null || printf 1)"
    fi
    case "$n" in
        ''|*[!0-9]*) n=1 ;;
    esac
    if [ "$n" -gt 2 ]; then
        printf '%s\n' "$((n - 1))"
    else
        printf '1\n'
    fi
}
JOBS="${APPATTIC_BUILD_JOBS:-$(detect_jobs)}"

# Run "$1" once per remaining argument, at most $JOBS in flight, and report
# failures in the order the list declared them. Each module writes its own
# artifact and reads only the source tree and the shared zig cache, which is
# built for concurrent use, so nothing here has to serialize.
#
# Waiting in list order rather than as each job happens to finish is deliberate:
# the log stays diffable between runs, and a failed module names itself instead
# of leaving the reader to attribute whichever line landed last.
run_modules() {
    local fn="$1"
    shift
    local m reaped=0 rc=0
    local -a pids=()
    local -a names=()
    for m in "$@"; do
        echo "-- $m"
        "$fn" "$m" &
        pids+=("$!")
        names+=("$m")
        while [ "$(( ${#pids[@]} - reaped ))" -ge "$JOBS" ]; do
            if ! wait "${pids[$reaped]}"; then
                echo "error: ${names[$reaped]} failed" >&2
                rc=1
            fi
            reaped=$((reaped + 1))
        done
    done
    while [ "$reaped" -lt "${#pids[@]}" ]; do
        if ! wait "${pids[$reaped]}"; then
            echo "error: ${names[$reaped]} failed" >&2
            rc=1
        fi
        reaped=$((reaped + 1))
    done
    return "$rc"
}

# zig fmt plus every zig test, with no WASM or host build: the gate a
# contributor runs when editing core/src, and what scripts/check.sh calls.
if [ "${1:-}" = "test-core" ]; then
    zig fmt --check "$root/src" "$root/bench"
    run_modules zig_test "${test_modules[@]}"
    echo "zig: ${#test_modules[@]} modules ok"
    exit 0
fi

zig fmt --check "$root/src" "$root/bench"

# core/out is kept between runs and the packaging scripts bundle it by glob
# (AppImage) or by pattern (cmake install). Without this, the output of a
# removed or renamed plugin survives in the tree and ships in the artifact.
# Only the full build clears it; test and test-core leave the artifacts alone.
rm -f "$out"/*.wasm "$out"/*.cwasm "$out"/*.cwasm.tmp

# One artifact name for every consumer of it: the emit below, the built list
# and the host's try line. core.zig is the one source whose artifact is not
# named after it, because the host loads it as appattic_core.wasm.
wasm_artifact_name() {
    if [ "${1%.zig}" = "core" ]; then
        printf 'appattic_core.wasm\n'
    else
        printf '%s.wasm\n' "${1%.zig}"
    fi
}

zig_wasm() {
    zig build-exe \
        -target wasm32-freestanding \
        -fno-entry \
        -rdynamic \
        -OReleaseSmall \
        -fstrip \
        -femit-bin="$out/$(wasm_artifact_name "$1")" \
        "$root/src/$1"
}

run_modules zig_wasm "${wasm_sources[@]}"

run_modules zig_test "${test_modules[@]}"


wasmtime_libdir() {
    prefix=$1
    if [ -d "$prefix/lib" ]; then
        echo "$prefix/lib"
    elif [ -d "$prefix/lib64" ]; then
        echo "$prefix/lib64"
    else
        return 1
    fi
}

wasmtime_from_prefix() {
    prefix=$1
    libdir=$(wasmtime_libdir "$prefix") || return 1
    [ -f "$prefix/include/wasmtime.h" ] || return 1
    wasmtime_cflags=(-I"$prefix/include")
    wasmtime_libs=(-L"$libdir" "-Wl,-rpath,$libdir" -lwasmtime)
}

wasmtime_cflags=()
wasmtime_libs=(-lwasmtime)
if [ -f /opt/homebrew/include/wasmtime.h ]; then
    wasmtime_from_prefix /opt/homebrew
elif [ -n "${WASMTIME_DIR:-}" ] && wasmtime_from_prefix "$WASMTIME_DIR"; then
    :
elif [ -f /opt/wasmtime-c-api/include/wasmtime.h ]; then
    wasmtime_from_prefix /opt/wasmtime-c-api
elif [ -f "$root/../.deps/wasmtime-c-api/include/wasmtime.h" ]; then
    wasmtime_from_prefix "$root/../.deps/wasmtime-c-api"
elif command -v pkg-config >/dev/null 2>&1 && pkg-config --exists wasmtime; then
    # shellcheck disable=SC2206,SC2207  # pkg-config output is a flag list to word-split
    wasmtime_cflags=($(pkg-config --cflags wasmtime))
    # shellcheck disable=SC2206,SC2207  # pkg-config output is a flag list to word-split
    wasmtime_libs=($(pkg-config --libs wasmtime))
else
    echo "wasmtime C API missing. macOS: brew install wasmtime. Linux: scripts/linux-deps.sh --install-wasmtime" >&2
    echo "WASM modules are in $out. Host stub not linked." >&2
    exit 1
fi

# hostexec_test is proof-only; Linux needs fixtures (Darwin defaults in hostexec.c).
case "$(uname -s)" in
    Linux) export APPATTIC_HOST_EXEC_FIXTURE=1 ;;
esac

cc_cflags=(-O2 -Wall -Wextra -fstack-protector-strong -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=2 -fPIE
    "-ffile-prefix-map=$root=." "-fdebug-prefix-map=$root=." "-fmacro-prefix-map=$root=.")
cc_ldflags=()
case "$(uname -s)" in
    Linux)
        cc_ldflags=(-pie "-Wl,-z,relro,-z,now" "-Wl,-z,noexecstack")
        cc_cflags+=(-fstack-clash-protection)
        case "$(uname -m)" in
            x86_64)
                cc_cflags+=(-fcf-protection=full)
                cc_ldflags+=(-fcf-protection=full)
                ;;
            aarch64|arm64)
                cc_cflags+=(-mbranch-protection=standard)
                ;;
        esac
        ;;
    Darwin)
        cc_ldflags=("-Wl,-pie")
        ;;
    *)
        cc_ldflags=(-pie)
        ;;
esac

cc "${cc_cflags[@]}" "${cc_ldflags[@]}" \
    -Werror -Wformat=2 -Wformat-security \
    -Wshadow -Wstrict-prototypes -Wconversion -Wpedantic -Wnull-dereference \
    -I"$root/host" \
    "$root/host/hostexec.c" \
    "$root/host/tests/hostexec_test.c" \
    -o "$out/hostexec_test"
"$out/hostexec_test"

cc "${cc_cflags[@]}" "${cc_ldflags[@]}" \
    -I"$root/host" \
    "${wasmtime_cflags[@]}" \
    "$root/host/stub.c" \
    "$root/host/embed.c" \
    "$root/host/hostexec.c" \
    "${wasmtime_libs[@]}" \
    -o "$out/host"

# Ship precompiled images beside the wasm: a fresh process then deserializes
# instead of compiling the whole set (~65 ms -> ~3 ms). A failure here only
# costs that speedup, so it warns instead of failing the build.
if ! "$out/host" --precompile "$out"/*.wasm; then
    echo "warning: precompiled images not written; first scan will compile" >&2
fi

built="$out/host"
try_line="$out/host $out/appattic_core.wasm"
for src in "${wasm_sources[@]}"; do
    dst="$(wasm_artifact_name "$src")"
    built="$built $out/$dst"
    case "$dst" in
        appattic_core.wasm) ;;
        container_runtime.wasm) try_line="$try_line $out/$dst=2" ;;
        *) try_line="$try_line $out/$dst=1" ;;
    esac
done
echo "built $built"
echo "try: $try_line"
echo "tag 0 = missing coeffect. Darwin host.exec injects fixtures."
echo "backlog (not loaded): chocolatey nuget appstore steam"
