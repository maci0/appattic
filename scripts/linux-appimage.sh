#!/usr/bin/env bash
# Build a portable AppImage for the Qt 6 Linux UI (appattic-qt).
# Bundles Qt via linuxdeploy-plugin-qt, libwasmtime.so ($ORIGIN), and core/out WASM.
# Usage: bash scripts/linux-appimage.sh
#   ARCH=aarch64 bash scripts/linux-appimage.sh   # override host arch for tool names
# Requires Linux, Qt 6 dev, zig, wasmtime (scripts/linux-deps.sh). Exit 3 on Darwin.
set -euo pipefail

_script_dir="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$_script_dir/.." && pwd)"
cd "$ROOT"
export LC_ALL=C
export LANG=C
export TZ=UTC

for arg in "$@"; do
    case "$arg" in
        -h|--help)
            cat <<'EOF'
Usage: bash scripts/linux-appimage.sh

  ARCH=aarch64 bash scripts/linux-appimage.sh   # override host arch for tool names
  Requires Linux, Qt 6, zig, wasmtime (scripts/linux-deps.sh). Exit 3 on Darwin.
EOF
            exit 0
            ;;
        *)
            echo "error: unknown argument: $arg" >&2
            echo "Usage: bash scripts/linux-appimage.sh" >&2
            echo "       bash scripts/linux-appimage.sh --help" >&2
            exit 2
            ;;
    esac
done

if [[ -z "${SOURCE_DATE_EPOCH:-}" ]]; then
    SOURCE_DATE_EPOCH="$(git log -1 --pretty=%ct 2>/dev/null || printf '0')"
    export SOURCE_DATE_EPOCH
fi
if [[ -z "${VERSION:-}" ]]; then
    VERSION="$(git describe --tags --exact-match 2>/dev/null || printf '1.0.0')"
fi
VERSION="${VERSION#v}"
if [[ -z "$VERSION" ]]; then
    VERSION="1.0.0"
fi
export VERSION

# shellcheck source=verify-sha256.sh
. "$_script_dir/verify-sha256.sh"

LINUXDEPLOY_VER=1-alpha-20251107-1
LINUXDEPLOY_PLUGIN_QT_VER=1-alpha-20250213-1
APPIMAGETOOL_VER=1.9.1

OS="$(uname -s)"
HOST_ARCH="$(uname -m)"
if [[ "$OS" != Linux ]]; then
    echo "blocked: not Linux ($OS $HOST_ARCH). Homebrew Qt on macOS is not an AppImage build." >&2
    echo "Run this script on a Linux host with Qt 6, zig, and wasmtime installed." >&2
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
cmake --install "$BUILD_DIR" --prefix "$APPDIR/usr" --strip

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
while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    cp -f "$f" "$WASM_DEST/"
done < <(printf '%s\n' "$CORE_OUT"/*.wasm | LC_ALL=C sort)

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
    local expected
    require_sha256sum
    expected="$(checksum_for "$name")" || {
        echo "error: no pinned SHA-256 for $name" >&2
        exit 1
    }
    if [[ -f "$dest" ]] && [[ "$(file_sha256 "$dest")" == "$expected" ]]; then
        chmod +x "$dest"
        return 0
    fi
    if [[ -e "$dest" ]]; then
        echo "cached $name failed SHA-256; re-downloading"
        rm -f "$dest"
    fi
    echo "fetching $name…"
    curl_fetch "$url" "$dest"
    if ! verify_sha256 "$dest" "$expected"; then
        rm -f "$dest"
        exit 1
    fi
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
    "https://github.com/linuxdeploy/linuxdeploy/releases/download/${LINUXDEPLOY_VER}/linuxdeploy-${APPIMAGE_ARCH}.AppImage"
fetch_appimage_tool "linuxdeploy-plugin-qt-${APPIMAGE_ARCH}.AppImage" \
    "https://github.com/linuxdeploy/linuxdeploy-plugin-qt/releases/download/${LINUXDEPLOY_PLUGIN_QT_VER}/linuxdeploy-plugin-qt-${APPIMAGE_ARCH}.AppImage"
fetch_appimage_tool "appimagetool-${APPIMAGE_ARCH}.AppImage" \
    "https://github.com/AppImage/appimagetool/releases/download/${APPIMAGETOOL_VER}/appimagetool-${APPIMAGE_ARCH}.AppImage"

LINUXDEPLOY="$TOOLS/linuxdeploy-${APPIMAGE_ARCH}.AppImage"
PLUGIN_QT="$TOOLS/linuxdeploy-plugin-qt-${APPIMAGE_ARCH}.AppImage"
APPIMAGETOOL="$TOOLS/appimagetool-${APPIMAGE_ARCH}.AppImage"

QMAKE="$(command -v qmake6 || command -v qmake || true)"
export QMAKE
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

# Squashfs mtimes and file order follow SOURCE_DATE_EPOCH / LC_ALL=C.
find "$APPDIR" -exec touch -h -d "@${SOURCE_DATE_EPOCH}" {} +

mkdir -p "$DIST"
rm -f "$OUT"
echo "appimagetool: $OUT"
ARCH="$APPIMAGE_ARCH" SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" VERSION="$VERSION" \
    run_appimage_tool "$APPIMAGETOOL" "$APPDIR" "$OUT"

if [[ ! -x "$OUT" ]]; then
    echo "error: AppImage not created: $OUT" >&2
    exit 1
fi

{
    echo "format: appattic-buildinfo/1"
    echo "SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH}"
    echo "VERSION=${VERSION}"
    echo "ARCH=${APPIMAGE_ARCH}"
    echo "zig: $(zig version)"
    echo "cmake: $(cmake --version | head -n 1)"
    echo "cc: $("${CC:-cc}" --version | head -n 1)"
    echo "qt: $($QMAKE -query QT_VERSION 2>/dev/null || printf unknown)"
} >"${OUT}.buildinfo"

export APPATTIC_HOST_EXEC_FIXTURE=1
export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-offscreen}"
echo "smoke: QT_QPA_PLATFORM=$QT_QPA_PLATFORM $OUT --smoke"
set +e
dump="$(run_appimage_tool "$OUT" --smoke 2>&1)"
rc=$?
set -e
printf '%s\n' "$dump"
if [[ $rc -ne 0 ]] || ! printf '%s\n' "$dump" | grep -q '^SMOKE=ok$'; then
    echo "error: AppImage --smoke failed" >&2
    exit 1
fi

echo "AppImage: $OUT"
echo "buildinfo: ${OUT}.buildinfo"
echo "run:    $OUT"
echo "bundled:"
echo "  - appattic-qt + Qt 6 (linuxdeploy-plugin-qt)"
echo "  - libwasmtime.so (usr/bin, RPATH \$ORIGIN)"
echo "  - $wasm_count WASM modules (usr/share/appattic, APPATTIC_CORE_OUT in AppRun)"
