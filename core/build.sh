#!/usr/bin/env bash
# WASM core + plugins + host. Usage: ./core/build.sh [test <name.zig>]
set -euo pipefail
export LC_ALL=C
export LANG=C
export TZ=UTC

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    echo "Usage: $0 [test <name.zig>]"
    echo "  (no args)          WASM + all zig tests + host (needs wasmtime C API)"
    echo "  test brew.zig      one plugin (fast edit loop)"
    exit 0
fi

if [ "${1:-}" = "test" ] && [ -z "${2:-}" ]; then
    echo "error: missing plugin name" >&2
    echo "Usage: $0 test <name.zig>" >&2
    echo "example: $0 test brew.zig" >&2
    exit 2
fi

if [ -n "${1:-}" ] && [ "${1:-}" != "test" ]; then
    echo "error: unknown argument: $1" >&2
    echo "Usage: $0 [test <name.zig>]" >&2
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

if ! command -v zig >/dev/null 2>&1; then
    if [ -x /opt/zig/zig ]; then
        export PATH="/opt/zig:$PATH"
    elif [ -x /usr/local/bin/zig ]; then
        export PATH="/usr/local/bin:$PATH"
    elif [ -x "$root/../.deps/zig/zig" ]; then
        export PATH="$root/../.deps/zig:$PATH"
    fi
fi
if ! command -v zig >/dev/null 2>&1; then
    echo "zig missing. macOS: brew install zig. Linux: scripts/linux-deps.sh --install" >&2
    echo "Then re-run $0" >&2
    exit 1
fi
zig_need="0.16.0"
if [ -f "$root/../.zig-version" ]; then
    zig_need="$(tr -d '[:space:]' < "$root/../.zig-version")"
fi
if [ -z "$zig_need" ]; then
    zig_need="0.16.0"
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

zig fmt --check "$root/src"

zig_wasm() {
    zig build-exe \
        -target wasm32-freestanding \
        -fno-entry \
        -rdynamic \
        -OReleaseSmall \
        -fstrip \
        -femit-bin="$out/$2" \
        "$root/src/$1"
}

zig_wasm core.zig appattic_core.wasm
zig_wasm container_runtime.zig container_runtime.wasm
zig_wasm snapd.zig snapd.wasm
zig_wasm path_xdg_config.zig path_xdg_config.wasm
zig_wasm path_xdg_data.zig path_xdg_data.wasm
zig_wasm path_xdg_cache.zig path_xdg_cache.wasm
zig_wasm path_xdg_state.zig path_xdg_state.wasm
zig_wasm path_xdg_lib.zig path_xdg_lib.wasm
zig_wasm path_var_app.zig path_var_app.wasm
zig_wasm path_user_bin.zig path_user_bin.wasm
zig_wasm path_home_dot.zig path_home_dot.wasm
zig_wasm path_application_support.zig path_application_support.wasm
zig_wasm path_caches.zig path_caches.wasm
zig_wasm path_preferences.zig path_preferences.wasm
zig_wasm path_saved_state.zig path_saved_state.wasm
zig_wasm path_containers.zig path_containers.wasm
zig_wasm path_group_containers.zig path_group_containers.wasm
zig_wasm path_logs.zig path_logs.wasm
zig_wasm path_webkit.zig path_webkit.wasm
zig_wasm path_httpstorages.zig path_httpstorages.wasm
zig_wasm path_launchagents.zig path_launchagents.wasm
zig_wasm path_shadow.zig path_shadow.wasm
zig_wasm pacman.zig pacman.wasm
zig_wasm apt.zig apt.wasm
zig_wasm dnf.zig dnf.wasm
zig_wasm zypper.zig zypper.wasm
zig_wasm flatpak.zig flatpak.wasm
zig_wasm npm.zig npm.wasm
zig_wasm pnpm.zig pnpm.wasm
zig_wasm bun.zig bun.wasm
zig_wasm pipx.zig pipx.wasm
zig_wasm uv.zig uv.wasm
zig_wasm brew.zig brew.wasm
zig_wasm gem.zig gem.wasm
zig_wasm composer.zig composer.wasm
zig_wasm pip.zig pip.wasm

zig_test() {
    zig test "$root/src/$1"
}
zig_test host_exec.zig
zig_test jsonbuf.zig
zig_test jsonscan.zig
zig_test apt.zig
zig_test pacman.zig
zig_test snapd.zig
zig_test path_listing.zig
zig_test path_xdg_config.zig
zig_test path_xdg_data.zig
zig_test path_xdg_cache.zig
zig_test path_xdg_state.zig
zig_test path_xdg_lib.zig
zig_test path_var_app.zig
zig_test path_user_bin.zig
zig_test path_home_dot.zig
zig_test path_application_support.zig
zig_test path_caches.zig
zig_test path_preferences.zig
zig_test path_saved_state.zig
zig_test path_containers.zig
zig_test path_group_containers.zig
zig_test path_logs.zig
zig_test path_webkit.zig
zig_test path_httpstorages.zig
zig_test path_launchagents.zig
zig_test path_shadow.zig
zig_test dnf.zig
zig_test zypper.zig
zig_test flatpak.zig
zig_test npm.zig
zig_test pnpm.zig
zig_test bun.zig
zig_test pipx.zig
zig_test uv.zig
zig_test brew.zig
zig_test gem.zig
zig_test composer.zig
zig_test pip.zig
zig_test container_runtime.zig

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
    # shellcheck disable=SC2206,SC2207
    wasmtime_cflags=($(pkg-config --cflags wasmtime))
    # shellcheck disable=SC2206,SC2207
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
    "$root/host/hostexec_test.c" \
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

echo "built $out/appattic_core.wasm $out/container_runtime.wasm $out/snapd.wasm $out/path_xdg_config.wasm $out/path_xdg_data.wasm $out/path_xdg_cache.wasm $out/path_xdg_state.wasm $out/path_xdg_lib.wasm $out/path_var_app.wasm $out/path_user_bin.wasm $out/path_home_dot.wasm $out/path_application_support.wasm $out/path_caches.wasm $out/path_preferences.wasm $out/path_saved_state.wasm $out/path_containers.wasm $out/path_group_containers.wasm $out/path_logs.wasm $out/path_webkit.wasm $out/path_httpstorages.wasm $out/path_launchagents.wasm $out/path_shadow.wasm $out/pacman.wasm $out/apt.wasm $out/dnf.wasm $out/zypper.wasm $out/flatpak.wasm $out/npm.wasm $out/pnpm.wasm $out/bun.wasm $out/pipx.wasm $out/uv.wasm $out/brew.wasm $out/gem.wasm $out/composer.wasm $out/pip.wasm $out/host"
echo "try: $out/host $out/appattic_core.wasm $out/container_runtime.wasm=2 $out/snapd.wasm=1 $out/path_xdg_config.wasm=1 $out/path_xdg_data.wasm=1 $out/path_xdg_cache.wasm=1 $out/path_xdg_state.wasm=1 $out/path_xdg_lib.wasm=1 $out/path_var_app.wasm=1 $out/path_user_bin.wasm=1 $out/path_home_dot.wasm=1 $out/path_application_support.wasm=1 $out/path_caches.wasm=1 $out/path_preferences.wasm=1 $out/path_saved_state.wasm=1 $out/path_containers.wasm=1 $out/path_group_containers.wasm=1 $out/path_logs.wasm=1 $out/path_webkit.wasm=1 $out/path_httpstorages.wasm=1 $out/path_launchagents.wasm=1 $out/path_shadow.wasm=1 $out/pacman.wasm=1 $out/apt.wasm=1 $out/dnf.wasm=1 $out/zypper.wasm=1 $out/flatpak.wasm=1 $out/npm.wasm=1 $out/pnpm.wasm=1 $out/bun.wasm=1 $out/pipx.wasm=1 $out/uv.wasm=1 $out/brew.wasm=1 $out/gem.wasm=1 $out/composer.wasm=1 $out/pip.wasm=1"
echo "tag 0 = missing coeffect. Darwin host.exec injects fixtures."
echo "backlog (not loaded): chocolatey nuget appstore steam"
