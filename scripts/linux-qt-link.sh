#!/usr/bin/env bash
# Compile AppAttic Qt 6 UI on Linux and prove the binary links Qt6, not Gtk,
# then run headless --smoke (QT_QPA_PLATFORM=offscreen, else minimal).
# Homebrew Qt on macOS is not a Linux Qt link. Exit 3 on non-Linux.
# Usage: scripts/linux-qt-link.sh [--smoke]
#   (default)  build core/out WASM, link Qt binary, ldd gate, --smoke gate
#   --smoke    skip cmake rebuild; re-run ldd + binary --smoke on existing build
# Binary flags: --smoke / --version / --help (strict WASM load on --smoke only).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export LC_ALL=C
export LANG=C
export TZ=UTC
if [[ -z "${SOURCE_DATE_EPOCH:-}" ]]; then
    SOURCE_DATE_EPOCH="$(git log -1 --pretty=%ct 2>/dev/null || printf '0')"
    export SOURCE_DATE_EPOCH
fi

SMOKE_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --smoke) SMOKE_ONLY=1 ;;
        -h|--help)
            cat <<'EOF'
Usage: scripts/linux-qt-link.sh [--smoke]

  (default)  build core/out WASM, link Qt binary, ldd gate, --smoke gate
  --smoke    skip cmake rebuild; re-run ldd + binary --smoke on existing build

Binary flags: --smoke / --version / --help (strict WASM load on --smoke only).
Exit 3 on non-Linux. Homebrew Qt on macOS is not a Linux Qt link.
EOF
            exit 0
            ;;
        *)
            echo "error: unknown argument: $arg" >&2
            echo "Usage: scripts/linux-qt-link.sh [--smoke]" >&2
            exit 2
            ;;
    esac
done

OS="$(uname -s)"
ARCH="$(uname -m)"
if [[ "$OS" != Linux ]]; then
    echo "blocked: not Linux ($OS $ARCH). Homebrew Qt on macOS is not a Linux Qt link." >&2
    echo "Use CI (.github/workflows/linux.yml) or a Linux host." >&2
    exit 3
fi

# hostexec fixtures are default on Darwin; Linux needs this for hostexec_test and --smoke.
export APPATTIC_HOST_EXEC_FIXTURE=1

fail_dep() {
    echo "error: $1" >&2
    echo "$2" >&2
    echo "Qt 6 + clang + cmake: bash scripts/linux-deps.sh   (print)" >&2
    echo "                      bash scripts/linux-deps.sh --install" >&2
    echo "                      bash scripts/linux-deps.sh --install-wasmtime" >&2
    exit 2
}

command -v cmake >/dev/null 2>&1 || fail_dep \
    "cmake missing" \
    "Install Qt 6 build tools: bash scripts/linux-deps.sh --install"

command -v pkg-config >/dev/null 2>&1 || fail_dep \
    "pkg-config missing" \
    "Install Qt 6 headers: bash scripts/linux-deps.sh --install"

ensure_pkg_config_path() {
    local archdir d extra=""
    archdir="$(uname -m)"
    for d in "/usr/lib/${archdir}-linux-gnu/pkgconfig" \
             "/usr/lib/pkgconfig" \
             "/usr/share/pkgconfig"; do
        [[ -d "$d" ]] || continue
        if [[ -z "$extra" ]]; then
            extra="$d"
        else
            extra="$extra:$d"
        fi
    done
    if [[ -n "$extra" ]]; then
        if [[ -z "${PKG_CONFIG_PATH:-}" ]]; then
            export PKG_CONFIG_PATH="$extra"
        else
            export PKG_CONFIG_PATH="$extra:$PKG_CONFIG_PATH"
        fi
    fi
}

qt6_pkg_config_ok() {
    ensure_pkg_config_path
    pkg-config --exists Qt6Widgets 2>/dev/null && return 0
    pkg-config --exists Qt6Core 2>/dev/null && return 0
    return 1
}

qt6_cmake_ok() {
    local archdir p
    archdir="$(uname -m)"
    for p in "/usr/lib/${archdir}-linux-gnu/cmake/Qt6/Qt6Config.cmake" \
             "/usr/lib/cmake/Qt6/Qt6Config.cmake"; do
        [[ -f "$p" ]] && return 0
    done
    return 1
}

if ! qt6_pkg_config_ok && ! qt6_cmake_ok; then
    fail_dep "Qt 6 development files missing" "Install Qt 6 headers: bash scripts/linux-deps.sh --install"
fi

command -v clang++ >/dev/null 2>&1 || command -v c++ >/dev/null 2>&1 || fail_dep \
    "C++ compiler missing" \
    "Debian/Ubuntu: apt install clang. Fedora: dnf install clang. Arch: pacman -S clang."

if ! command -v zig >/dev/null 2>&1; then
    if [[ -x /opt/zig/zig ]]; then
        export PATH="/opt/zig:${PATH:-}"
    elif [[ -x /usr/local/bin/zig ]]; then
        export PATH="/usr/local/bin:${PATH:-}"
    elif [[ -x "$ROOT/.deps/zig/zig" ]]; then
        export PATH="$ROOT/.deps/zig:${PATH:-}"
    fi
fi
command -v zig >/dev/null 2>&1 || fail_dep \
    "zig missing" \
    "Install zig: bash scripts/linux-deps.sh --install"

if [[ -z "${WASMTIME_DIR:-}" ]]; then
    if [[ -f /opt/wasmtime-c-api/include/wasmtime.h ]]; then
        export WASMTIME_DIR=/opt/wasmtime-c-api
    elif [[ -f "$ROOT/.deps/wasmtime-c-api/include/wasmtime.h" ]]; then
        export WASMTIME_DIR="$ROOT/.deps/wasmtime-c-api"
    elif [[ -f /usr/local/include/wasmtime.h ]]; then
        export WASMTIME_DIR=/usr/local
    fi
fi
if [[ -z "${WASMTIME_DIR:-}" ]] || [[ ! -f "${WASMTIME_DIR}/include/wasmtime.h" ]]; then
    fail_dep "wasmtime C API missing" "bash scripts/linux-deps.sh --install-wasmtime"
fi

echo "os: Linux $ARCH"
echo "cmake: $(cmake --version | head -n 1)"
if qt6_pkg_config_ok; then
    if pkg-config --exists Qt6Widgets; then
        echo "Qt6Widgets: $(pkg-config --modversion Qt6Widgets)"
    elif pkg-config --exists Qt6Core; then
        echo "Qt6Core: $(pkg-config --modversion Qt6Core)"
    fi
elif qt6_cmake_ok; then
    echo "Qt6: cmake config present (no pkg-config .pc on this distro)"
fi
echo "WASMTIME_DIR: $WASMTIME_DIR"
echo "zig: $(zig version | head -n 1)"

CORE_OUT="$ROOT/core/out"
export APPATTIC_CORE_OUT="$CORE_OUT"

wasmtime_ldpath() {
  local lib=""
  if [[ -d "${WASMTIME_DIR}/lib" ]]; then
    lib="${WASMTIME_DIR}/lib"
  elif [[ -d "${WASMTIME_DIR}/lib64" ]]; then
    lib="${WASMTIME_DIR}/lib64"
  fi
  if [[ -n "$lib" ]]; then
    export LD_LIBRARY_PATH="${lib}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  fi
}

ensure_qt_platform_plugins() {
  if [[ -n "${QT_PLUGIN_PATH:-}" ]]; then
    return 0
  fi
  local archdir
  archdir="$ARCH"
  local plug=""
  for d in "/usr/lib/${archdir}-linux-gnu/qt6/plugins" \
           "/usr/lib/qt6/plugins" \
           "/usr/lib64/qt6/plugins"; do
    if [[ -f "$d/platforms/libqoffscreen.so" ]]; then
      plug="$d"
      break
    fi
  done
  if [[ -n "$plug" ]]; then
    export QT_PLUGIN_PATH="$plug"
    echo "QT_PLUGIN_PATH=$plug"
    return 0
  fi
  echo "error: libqoffscreen.so not found (install qt6-qpa-plugins / qt6-base)" >&2
  exit 2
}

ensure_wasm_core() {
  echo "building WASM core + plugins (core/build.sh)…"
  bash "$ROOT/core/build.sh"
}

require_wasm_artifacts() {
  local missing=0
  for f in appattic_core.wasm path_shadow.wasm path_home_dot.wasm; do
    if [[ ! -f "$CORE_OUT/$f" ]]; then
      echo "error: missing $CORE_OUT/$f" >&2
      missing=1
    fi
  done
  if [[ "$missing" -ne 0 ]]; then
    echo "Run: bash core/build.sh" >&2
    exit 1
  fi
  echo "wasm: core/out ready ($(find "$CORE_OUT" -maxdepth 1 -name '*.wasm' | LC_ALL=C sort | wc -l | tr -d ' ') modules)"
}

for p in /usr/lib/x86_64-linux-gnu/cmake /usr/lib/aarch64-linux-gnu/cmake /usr/lib/cmake; do
    if [[ -d "$p/Qt6" ]]; then
        export CMAKE_PREFIX_PATH="${CMAKE_PREFIX_PATH:+$CMAKE_PREFIX_PATH:}$p"
    fi
done

gen=()
if command -v ninja >/dev/null 2>&1; then
    gen=(-G Ninja)
    echo "ninja: $(ninja --version)"
fi

find_binary() {
  bin=""
  for c in \
      "$ROOT/ui/linux-qt/build/appattic-qt" \
      "$ROOT/ui/linux-qt/build/Debug/appattic-qt"; do
      if [[ -f "$c" && -x "$c" ]]; then
          bin="$c"
          break
      fi
  done
  if [[ -z "$bin" ]]; then
      echo "error: appattic-qt binary missing (run without --smoke to build)" >&2
      exit 1
  fi
}

if [[ "$SMOKE_ONLY" -eq 0 ]]; then
  ensure_wasm_core
  require_wasm_artifacts
  echo "building appattic-qt (Qt 6 Widgets + Wasmtime)…"
  cmake -S "$ROOT/ui/linux-qt" -B "$ROOT/ui/linux-qt/build" \
      "${gen[@]}" \
      -DCMAKE_BUILD_TYPE=Debug \
      -DWASMTIME_ROOT="$WASMTIME_DIR"
  cmake --build "$ROOT/ui/linux-qt/build"
else
  require_wasm_artifacts
fi

find_binary
echo "binary: $bin"
wasmtime_ldpath
proof="$ROOT/ui/linux-qt/build/LINUX_QT_LINK.txt"
mkdir -p "$(dirname "$proof")"
smoke_plat=""
smoke_dump=""

smoke_output_ok() {
    local dump="$1"
    printf '%s\n' "$dump" | grep -q '^SMOKE=ok$' || return 1
    printf '%s\n' "$dump" | grep -Eq '^wasm: ok \([1-9][0-9]* plugins\)$' || return 1
    printf '%s\n' "$dump" | grep -q '^plugin:path-shadow$' || return 1
    printf '%s\n' "$dump" | grep -Eq '^tables: ok \(leftovers=[1-9][0-9]* stale=[1-9][0-9]*' || return 1
    return 0
}

try_smoke() {
    local plat="$1"
    local dump rc
    echo "smoke: QT_QPA_PLATFORM=$plat APPATTIC_CORE_OUT=$CORE_OUT $bin --smoke"
    set +e
    dump="$(QT_QPA_PLATFORM="$plat" APPATTIC_CORE_OUT="$CORE_OUT" "$bin" --smoke 2>&1)"
    rc=$?
    set -e
    printf '%s\n' "$dump"
    if [[ $rc -eq 0 ]] && smoke_output_ok "$dump"; then
        smoke_dump="$dump"
        smoke_plat="$plat"
        return 0
    fi
    if [[ $rc -eq 0 ]]; then
        echo "error: --smoke exited 0 but output missing wasm/plugins/path-shadow proof" >&2
    fi
    return 1
}

try_smoke_xvfb() {
    local dump rc
    echo "smoke: xvfb-run -a QT_QPA_PLATFORM=xcb APPATTIC_CORE_OUT=$CORE_OUT $bin --smoke"
    set +e
    dump="$(xvfb-run -a env QT_QPA_PLATFORM=xcb APPATTIC_CORE_OUT="$CORE_OUT" "$bin" --smoke 2>&1)"
    rc=$?
    set -e
    printf '%s\n' "$dump"
    if [[ $rc -eq 0 ]] && smoke_output_ok "$dump"; then
        smoke_dump="$dump"
        smoke_plat="xcb (xvfb-run)"
        return 0
    fi
    return 1
}

run_smoke() {
    ensure_qt_platform_plugins
    wasmtime_ldpath
    if try_smoke offscreen; then
        echo "smoke: ok (offscreen)"
        return 0
    fi
    echo "offscreen smoke failed, trying minimal"
    if try_smoke minimal; then
        echo "smoke: ok (minimal)"
        return 0
    fi
    if command -v xvfb-run >/dev/null 2>&1; then
        echo "minimal smoke failed, trying xvfb-run + xcb"
        if try_smoke_xvfb; then
            echo "smoke: ok (xvfb-run xcb)"
            return 0
        fi
    fi
    echo "error: Qt offscreen/minimal/xvfb --smoke failed" >&2
    echo "Install qt6-qpa-plugins, libgl1, libxcb-*, xvfb (bash scripts/linux-deps.sh --install)" >&2
    exit 1
}

pass_link() {
    local how="$1"
    local dump="$2"
    {
        echo "LINUX_QT_LINK=ok"
        echo "LINUX_QT_SMOKE=ok"
        echo "os: Linux $ARCH"
        echo "binary: $bin"
        echo "proof: $how"
        echo "smoke: QT_QPA_PLATFORM=$smoke_plat --smoke"
        echo "$dump"
        echo "$smoke_dump"
    } >"$proof"
    echo "LINUX_QT_LINK=ok"
    echo "LINUX_QT_SMOKE=ok"
}

if command -v ldd >/dev/null 2>&1; then
    deps="$(ldd "$bin")"
    if echo "$deps" | grep -E 'libgtk-[0-9]' >/dev/null; then
        echo "error: binary linked Gtk; Linux UI must be Qt 6 Widgets only" >&2
        echo "$deps" >&2
        exit 1
    fi
    if echo "$deps" | grep -E 'libQt6Widgets' >/dev/null; then
        echo "linked: Qt 6 Widgets"
    else
        echo "error: binary built but ldd shows no libQt6Widgets" >&2
        echo "$deps" >&2
        exit 1
    fi
    if echo "$deps" | grep -E 'libwasmtime' >/dev/null; then
        echo "linked: wasmtime"
    else
        echo "note: libwasmtime not in ldd (may be static)"
    fi
    run_smoke
    pass_link ldd "$deps"
    exit 0
fi
if command -v readelf >/dev/null 2>&1; then
    needed="$(readelf -d "$bin" | grep NEEDED || true)"
    echo "$needed"
    if echo "$needed" | grep -qE 'libgtk-[0-9]'; then
        echo "error: readelf shows libgtk; Linux UI must be Qt 6 Widgets only" >&2
        exit 1
    fi
    if echo "$needed" | grep -q 'libQt6Widgets'; then
        echo "linked: Qt 6 Widgets (readelf)"
        run_smoke
        pass_link readelf "$needed"
        exit 0
    fi
    echo "error: readelf shows no libQt6Widgets" >&2
    exit 1
fi
echo "error: no ldd or readelf to prove Qt 6 is linked" >&2
exit 1
