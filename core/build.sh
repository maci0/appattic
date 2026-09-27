#!/usr/bin/env bash
# WASM core + plugins + host.
# Usage: ./core/build.sh [test <name.zig> [testName] | test-core]
set -euo pipefail
export LC_ALL=C
export LANG=C
export TZ=UTC

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    echo "Usage: $0 [test <name.zig> [testName] | test-core]"
    echo "  (no args)              WASM + all zig tests + host (needs wasmtime C API)"
    echo "  test brew.zig          one module (fast edit loop)"
    echo "  test jsonbuf.zig isSafeIdent  one test in that module"
    echo "  test-core              zig fmt --check + every zig test (no wasmtime, no Qt)"
    exit 0
fi

if [ "$#" -gt 1 ] && [ "${1:-}" != "test" ]; then
    echo "error: expected at most one argument, got $#" >&2
    echo "Usage: $0 [test <name.zig> [testName] | test-core]" >&2
    echo "       $0 --help" >&2
    exit 2
fi

if [ "${1:-}" = "test" ] && [ -z "${2:-}" ]; then
    echo "error: missing plugin name" >&2
    echo "Usage: $0 test <name.zig> [testName]" >&2
    echo "example: $0 test brew.zig" >&2
    exit 2
fi

# test takes a name and an optional filter; anything past the filter is a typo
# rather than a name to guess at.
if [ "${1:-}" = "test" ] && [ "$#" -gt 3 ]; then
    echo "error: expected at most a module and a test name, got $#" >&2
    echo "Usage: $0 test <name.zig> [testName]" >&2
    exit 2
fi

if [ -n "${1:-}" ] && [ "${1:-}" != "test" ] && [ "${1:-}" != "test-core" ]; then
    echo "error: unknown argument: $1" >&2
    echo "Usage: $0 [test <name.zig> [testName] | test-core]" >&2
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
# Sourced before the first artifact is emitted: zig_build_flags is read at
# source time, and every WASM module is built with it.
# shellcheck source=build-flags.sh
. "$root/build-flags.sh"
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
    filter="${3:-}"
    if [ -n "$filter" ]; then
        # A module's tests are named <module>.test.<name>, and `zig test` on
        # one file runs the tests of every file it imports. An unqualified
        # filter therefore reaches the imported tree: `test brew.zig
        # isSafeIdent` reported jsonbuf's tests green and never ran a brew
        # test, which is the opposite of what the command promises. Scope the
        # filter to the named module so a name that lives elsewhere reads as
        # the typo it is.
        mod="${name%.zig}"
        log="$(zig test --test-filter "$mod.test.$filter" "$root/src/$name" 2>&1)" || {
            printf '%s\n' "$log" >&2
            exit 1
        }
        # zig test exits 0 and prints "All 0 tests passed" when --test-filter
        # matches nothing, so a typo in the name would read as a green run.
        # The count is taken from the progress lines the runner prints.
        printf '%s\n' "$log"
        if ! printf '%s\n' "$log" | grep -qE '^[0-9]+/[0-9]+ '; then
            echo "error: no test named '$filter' in $name" >&2
            echo "note: a test in an imported module is not in $name; run it from" >&2
            echo "      that module instead: zig test core/src/<module>.zig 2>&1 |" >&2
            printf "      grep -oE '\\b%s\\.test\\.[A-Za-z0-9_ ]+'\n" "$mod" >&2
            exit 1
        fi
        exit 0
    fi
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
        # A plain count: nproc's own answer, or APPATTIC_BUILD_JOBS.
        *) ;;
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
# The directory is generated (gitignored) and every full build re-emits
# everything in it, so the whole of it is cleared: a list of extensions misses
# an artifact kind added later, and it left the host binary behind when the
# link step was skipped. Only the full build clears it; test and test-core
# leave the artifacts alone.
rm -rf "${out:?}"/* "${out:?}"/.[!.]* 2>/dev/null || true

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
        "${zig_build_flags[@]}" \
        -femit-bin="$out/$(wasm_artifact_name "$1")" \
        "$root/src/$1"
}

run_modules zig_wasm "${wasm_sources[@]}"

# The precompiled image written below is bound to its source by a sibling
# `.cwasm.stamp` holding that module's size and mtime, and the AppImage ships
# the stamp as file content: a stamp carrying the wall clock makes two builds
# of the same source differ, and no amount of normalizing the archive metadata
# reaches inside a file. Every module is therefore stamped with the epoch
# before the image is compiled, so the stamp is a function of the source and
# the epoch. The reader compares the stamp against the .wasm's own mtime, and
# every consumer copies the pair with `cp -pf` and then stamps the whole
# bundle with the same epoch, so the image still validates.
appattic_touch_epoch "$out"/*.wasm

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
    # Elsewhere hostexec.c picks the fixture default itself.
    *) ;;
esac

# The C host flags, resolved against the tree being built.
appattic_host_flags "$root"

cc "${cc_cflags[@]}" "${cc_ldflags[@]}" \
    "${cc_strict_warnings[@]}" \
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
