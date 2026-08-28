#!/usr/bin/env bash
# Build a portable AppImage for the Qt 6 Linux UI (appattic-qt).
# Bundles Qt via linuxdeploy-plugin-qt, libwasmtime.so ($ORIGIN), and core/out WASM.
# Usage: bash scripts/linux-appimage.sh
#   ARCH=aarch64 bash scripts/linux-appimage.sh   # override host arch for tool names
# Requires Linux, Qt 6 dev, zig, wasmtime (scripts/linux-deps.sh). Exit 3 on Darwin.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

OS="$(uname -s)"
HOST_ARCH="$(uname -m)"
if [[ "$OS" != Linux ]]; then
    echo "blocked: not Linux ($OS $HOST_ARCH). Homebrew Qt on macOS is not an AppImage build."
    echo "Run this script on a Linux host with Qt 6, zig, and wasmtime installed."
    exit 3
fi

APPIMAGE_ARCH="${ARCH:-$HOST_ARCH}"
case "$APPIMAGE_ARCH" in
    x86_64|amd64) APPIMAGE_ARCH=x86_64 ;;
    aarch64|arm64) APPIMAGE_ARCH=aarch64 ;;
    *)
        echo "error: unsupported ARCH=$APPIMAGE_ARCH (want x86_64 or aarch64)" >&2
        exit 2
        ;;
esac
if [[ "$APPIMAGE_ARCH" != "$HOST_ARCH" ]]; then
    echo "note: ARCH=$APPIMAGE_ARCH overrides host $HOST_ARCH for tool downloads only"
fi

DIST="$ROOT/dist"
APPDIR="$DIST/AppDir"
TOOLS="$DIST/.appimage-tools"
OUT="$DIST/AppAttic-${APPIMAGE_ARCH}.AppImage"
BUILD_DIR="$ROOT/ui/linux-qt/build-release"
CORE_OUT="$ROOT/core/out"

fail_dep() {
    echo "error: $1" >&2
    echo "$2" >&2
    echo "Qt 6 + zig + wasmtime: bash scripts/linux-deps.sh --install" >&2
    echo "                         bash scripts/linux-deps.sh --install-wasmtime" >&2
    exit 2
}

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

command -v cmake >/dev/null 2>&1 || fail_dep "cmake missing" "bash scripts/linux-deps.sh --install"
command -v curl >/dev/null 2>&1 || fail_dep "curl missing" "install curl"

if ! command -v zig >/dev/null 2>&1; then
    if [[ -x /opt/zig/zig ]]; then
        export PATH="/opt/zig:${PATH:-}"
    elif [[ -x "$ROOT/.deps/zig/zig" ]]; then
        export PATH="$ROOT/.deps/zig:${PATH:-}"
    fi
fi
command -v zig >/dev/null 2>&1 || fail_dep "zig missing" "bash scripts/linux-deps.sh --install"

wasmtime_libdir() {
    if [[ -d "${WASMTIME_DIR}/lib" ]]; then
        echo "${WASMTIME_DIR}/lib"
    elif [[ -d "${WASMTIME_DIR}/lib64" ]]; then
        echo "${WASMTIME_DIR}/lib64"
    else
        return 1
    fi
}

WASMTIME_LIB="$(wasmtime_libdir)" || fail_dep "wasmtime lib dir missing" "check WASMTIME_DIR=$WASMTIME_DIR"
WASMTIME_SO=""
for so in "$WASMTIME_LIB"/libwasmtime.so "$WASMTIME_LIB"/libwasmtime.so.*; do
    if [[ -f "$so" ]]; then
        WASMTIME_SO="$so"
        break
    fi
done
if [[ -z "$WASMTIME_SO" ]]; then
    fail_dep "libwasmtime.so not found under $WASMTIME_LIB" "reinstall wasmtime C API"
fi

echo "os: Linux $HOST_ARCH  image arch: $APPIMAGE_ARCH"
echo "WASMTIME_DIR: $WASMTIME_DIR"
echo "zig: $(zig version | head -n 1)"

export APPATTIC_HOST_EXEC_FIXTURE=1
echo "building WASM core + plugins (core/build.sh)…"
bash "$ROOT/core/build.sh"

wasm_count=0
for f in "$CORE_OUT"/*.wasm; do
    [[ -f "$f" ]] || continue
    wasm_count=$((wasm_count + 1))
done
if [[ "$wasm_count" -lt 2 ]]; then
    echo "error: expected WASM modules in $CORE_OUT" >&2
    exit 1
fi
echo "wasm: $wasm_count modules in core/out"

for p in "/usr/lib/${HOST_ARCH}-linux-gnu/cmake" \
         /usr/lib/x86_64-linux-gnu/cmake \
         /usr/lib/aarch64-linux-gnu/cmake \
         /usr/lib/cmake; do
    if [[ -d "$p/Qt6" ]]; then
        export CMAKE_PREFIX_PATH="${CMAKE_PREFIX_PATH:+$CMAKE_PREFIX_PATH:}$p"
    fi
done

gen=()
if command -v ninja >/dev/null 2>&1; then
    gen=(-G Ninja)
fi

echo "building appattic-qt (Release)…"
cmake -S "$ROOT/ui/linux-qt" -B "$BUILD_DIR" \
    "${gen[@]}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DWASMTIME_ROOT="$WASMTIME_DIR"
cmake --build "$BUILD_DIR"

rm -rf "$APPDIR"
mkdir -p "$APPDIR"
cmake --install "$BUILD_DIR" --prefix "$APPDIR/usr"

BIN="$APPDIR/usr/bin/appattic-qt"
if [[ ! -x "$BIN" ]]; then
    echo "error: install did not produce $BIN" >&2
    exit 1
fi

if command -v ldd >/dev/null 2>&1; then
    deps="$(ldd "$BIN")"
    if echo "$deps" | grep -E 'libgtk-[0-9]' >/dev/null; then
        echo "error: binary linked Gtk; Linux UI must be Qt 6 only" >&2
        exit 1
    fi
    if ! echo "$deps" | grep -E 'libQt6Widgets' >/dev/null; then
        echo "error: binary missing libQt6Widgets" >&2
        exit 1
    fi
fi

cp -L "$WASMTIME_SO" "$APPDIR/usr/bin/libwasmtime.so"

WASM_DEST="$APPDIR/usr/share/appattic"
mkdir -p "$WASM_DEST"
cp -a "$CORE_OUT"/*.wasm "$WASM_DEST/"

DESKTOP="$ROOT/packaging/appattic.desktop"
ICON="$ROOT/packaging/appattic.svg"
if [[ ! -f "$DESKTOP" || ! -f "$ICON" ]]; then
    echo "error: missing packaging/appattic.desktop or packaging/appattic.svg" >&2
    exit 1
fi

mkdir -p "$TOOLS"
fetch_appimage_tool() {
    local name="$1"
    local url="$2"
    local dest="$TOOLS/$name"
    if [[ -x "$dest" ]]; then
        return 0
    fi
    echo "fetching $name…"
    curl -fsSL "$url" -o "$dest"
    chmod +x "$dest"
}

# GitHub Actions and other minimal hosts often lack libfuse.so.2 for AppImage tools.
run_appimage_tool() {
    local tool="$1"
    shift
    if [[ "${APPIMAGE_EXTRACT_AND_RUN:-}" == 1 ]] \
        || ! ldconfig -p 2>/dev/null | grep -q 'libfuse\.so\.2'; then
        "$tool" --appimage-extract-and-run "$@"
    else
        "$tool" "$@"
    fi
}

fetch_appimage_tool "linuxdeploy-${APPIMAGE_ARCH}.AppImage" \
    "https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-${APPIMAGE_ARCH}.AppImage"
fetch_appimage_tool "linuxdeploy-plugin-qt-${APPIMAGE_ARCH}.AppImage" \
    "https://github.com/linuxdeploy/linuxdeploy-plugin-qt/releases/download/continuous/linuxdeploy-plugin-qt-${APPIMAGE_ARCH}.AppImage"
fetch_appimage_tool "appimagetool-${APPIMAGE_ARCH}.AppImage" \
    "https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-${APPIMAGE_ARCH}.AppImage"

LINUXDEPLOY="$TOOLS/linuxdeploy-${APPIMAGE_ARCH}.AppImage"
PLUGIN_QT="$TOOLS/linuxdeploy-plugin-qt-${APPIMAGE_ARCH}.AppImage"
APPIMAGETOOL="$TOOLS/appimagetool-${APPIMAGE_ARCH}.AppImage"

export QMAKE="$(command -v qmake6 || command -v qmake)"
if [[ -z "$QMAKE" ]]; then
    fail_dep "qmake missing" "install Qt 6 development packages (qt6-base-dev / qt6-qtbase-devel)"
fi
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
export LINUXDEPLOY_PLUGIN_QT="$PLUGIN_QT"
# linuxdeploy bundles an old strip that chokes on .relr.dyn (newer toolchains)
export NO_STRIP=1

echo "linuxdeploy: bundling Qt 6 into AppDir…"
run_appimage_tool "$LINUXDEPLOY" --appdir "$APPDIR" \
    --executable "$BIN" \
    --desktop-file "$DESKTOP" \
    --icon-file "$ICON" \
    --plugin qt

patch_apprun() {
    local apprun="$APPDIR/AppRun"
    local target="${APPDIR}/usr/bin/appattic-qt"
    if [[ ! -x "$target" ]]; then
        echo "error: install did not produce $target" >&2
        exit 1
    fi
  # Qt 6 plugin skips apprun-hooks; linuxdeploy leaves AppRun as a symlink to the
  # binary. sed would edit the ELF. Replace with a script that exports wasm path
  # (qt.conf beside the binary covers Qt plugins for Qt 6).
    if [[ ! -L "$apprun" ]] && [[ -f "$apprun" ]] \
        && grep -q 'APPATTIC_CORE_OUT=' "$apprun" 2>/dev/null; then
        return 0
    fi
    rm -f "$apprun"
    cat > "$apprun" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
APPDIR="$(cd "$(dirname "$0")" && pwd)"
export APPATTIC_CORE_OUT="${APPDIR}/usr/share/appattic"
if [[ -d "${APPDIR}/apprun-hooks" ]]; then
    for hook in "${APPDIR}/apprun-hooks"/*.sh; do
        [[ -e "$hook" ]] && source "$hook"
    done
fi
exec "${APPDIR}/usr/bin/appattic-qt" "$@"
EOF
    chmod +x "$apprun"
}

patch_apprun

mkdir -p "$DIST"
rm -f "$OUT"
echo "appimagetool: $OUT"
ARCH="$APPIMAGE_ARCH" run_appimage_tool "$APPIMAGETOOL" "$APPDIR" "$OUT"

echo "AppImage: $OUT"
echo "run:    $OUT"
echo "smoke:  QT_QPA_PLATFORM=offscreen $OUT --appimage-extract-and-run --smoke"
echo "bundled:"
echo "  - appattic-qt + Qt 6 (linuxdeploy-plugin-qt)"
echo "  - libwasmtime.so (usr/bin, RPATH \$ORIGIN)"
echo "  - $wasm_count WASM modules (usr/share/appattic, APPATTIC_CORE_OUT in AppRun)"
