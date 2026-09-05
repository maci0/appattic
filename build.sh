#!/usr/bin/env bash
set -euo pipefail

# Build AppAttic: Foundation scan library, Gtk-free CLI, native UI.
# macOS: AppAttic.app + ad-hoc codesign (SwiftCrossUI AppKit).
# Linux: CLI always. UI is C++ Qt 6 (ui/linux-qt) if Qt6Widgets is present.
# Usage: ./build.sh [release|debug]

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
export LC_ALL=C
export LANG=C
export TZ=UTC
if [[ -z "${SOURCE_DATE_EPOCH:-}" ]]; then
    SOURCE_DATE_EPOCH="$(git log -1 --pretty=%ct 2>/dev/null || printf '0')"
    export SOURCE_DATE_EPOCH
fi

CONFIG="${1:-release}"
case "$CONFIG" in
    -h|--help|help)
        cat <<'EOF'
Usage: ./build.sh [release|debug]

  ./build.sh [release|debug]   CLI (+ UI if Qt 6 / macOS)
  ./run.sh report              CLI after a build
  bash scripts/check.sh        fast: lint + AppAtticScanTests + CLI
  bash scripts/check.sh --qt   full Linux CI parity, including Qt/WASM proof
  bash scripts/lint.sh
  swift test --filter UtilTests --disable-automatic-resolution
  ./core/build.sh test brew.zig
EOF
        exit 0
        ;;
    release|debug) ;;
    *)
        echo "error: unknown argument: $CONFIG" >&2
        echo "Usage: $0 [release|debug]" >&2
        echo "       $0 --help" >&2
        exit 2
        ;;
esac

# shellcheck source=scripts/find-swift.sh
. "$ROOT/scripts/find-swift.sh"
appattic_require_swift

OS="$(uname -s)"
HAVE_QT=0
if command -v pkg-config >/dev/null 2>&1 && { pkg-config --exists Qt6Widgets || pkg-config --exists Qt6Core; }; then
    HAVE_QT=1
fi

resolve_bin() {
    local name="$1"
    local c
    local matches
    shopt -s nullglob
    matches=(".build/${CONFIG}/${name}" .build/*/"${CONFIG}"/"${name}")
    shopt -u nullglob
    for c in "${matches[@]}"; do
        if [[ -f "$c" && -x "$c" ]]; then
            printf '%s\n' "$c"
            return 0
        fi
    done
    return 1
}

if [[ "$OS" == Darwin ]]; then
    echo "Building AppAttic (CLI + UI, ${CONFIG})…"
    # Product-by-product: a full-package build also compiles Gtk/WinSDK extras from swift-cross-ui.
    swift build -c "$CONFIG" --product appattic --disable-automatic-resolution
    swift build -c "$CONFIG" --product AppAtticUI --disable-automatic-resolution
elif [[ "$OS" == Linux ]]; then
    echo "Building AppAttic CLI (${CONFIG})…"
    swift build -c "$CONFIG" --product appattic --disable-automatic-resolution
    if [[ "$HAVE_QT" -eq 1 ]]; then
        echo "Building Linux Qt 6 UI…"
        bash scripts/linux-qt-link.sh
    else
        echo "Qt 6 not found (pkg-config Qt6Widgets). Building CLI only (${CONFIG})…"
        echo "Debian/Ubuntu: sudo apt install qt6-base-dev cmake ninja-build pkg-config clang" >&2
        echo "Fedora:        sudo dnf install qt6-qtbase-devel cmake ninja-build pkgconf-pkg-config clang" >&2
        echo "Arch:          sudo pacman -S qt6-base cmake ninja pkgconf clang" >&2
        echo "openSUSE:      sudo zypper install qt6-base-devel cmake ninja pkgconf-pkg-config clang" >&2
        echo "Or:            ./scripts/linux-deps.sh [--install] [--install-wasmtime]" >&2
        echo "Then:          ./scripts/linux-qt-link.sh" >&2
    fi
else
    echo "Building AppAttic CLI (${CONFIG})…"
    swift build -c "$CONFIG" --product appattic --disable-automatic-resolution
fi

CLI="$(resolve_bin appattic)" || {
    echo "error: appattic binary not found after swift build -c ${CONFIG}" >&2
    exit 1
}

if [[ "$OS" == Darwin ]]; then
    BIN="$(resolve_bin AppAtticUI)" || {
        echo "error: AppAtticUI binary not found after swift build -c ${CONFIG}" >&2
        exit 1
    }
    mkdir -p AppAttic.app/Contents/MacOS
    mkdir -p AppAttic.app/Contents/Resources
    rm -rf AppAttic.app/Contents/Resources/appattic
    cp "$BIN" AppAttic.app/Contents/MacOS/AppAttic
    chmod +x AppAttic.app/Contents/MacOS/AppAttic
    cp packaging/Info.plist AppAttic.app/Contents/Info.plist
    cp packaging/AppAttic.icns AppAttic.app/Contents/Resources/AppAttic.icns
    codesign --force --sign - AppAttic.app
    echo "Built AppAttic.app"
    echo "Launch: open AppAttic.app"
    echo "CLI:    ./run.sh report"
    echo "        ${CLI}"
elif [[ "$OS" == Linux && "$HAVE_QT" -eq 1 ]]; then
    echo "Linux UI: ui/linux-qt/build/appattic-qt"
    echo "CLI:      ${CLI}"
    echo "Launch UI: ./run.sh --ui"
    echo "Launch CLI: ./run.sh report"
else
    echo "Linux CLI: ${CLI}"
    echo "Launch: ./run.sh report"
    echo "UI skipped (install Qt 6, then ./build.sh again)."
fi
