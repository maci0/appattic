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
  ./build.sh release           Linux Qt UI into ui/linux-qt/build-release
  ./run.sh report              CLI after a build
  bash scripts/check.sh        fast: lint + Zig core + AppAtticScanTests + CLI
  bash scripts/check.sh --qt   full Linux CI parity, including Qt/WASM proof
  bash scripts/check.sh --core  the same, minus the Swift steps (no toolchain)
  bash scripts/lint.sh
  bash scripts/test.sh DiskSizeTests        one test class
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
# Only the configuration is read. A second argument used to be dropped in
# silence, so `./build.sh release --smoke` built a release and ignored the
# rest; scripts/test.sh and core/build.sh already reject the extra token.
if [[ $# -gt 1 ]]; then
    echo "error: expected at most one configuration, got $#" >&2
    echo "Usage: $0 [release|debug]" >&2
    echo "       $0 --help" >&2
    exit 2
fi

# shellcheck source=scripts/find-swift.sh
. "$ROOT/scripts/find-swift.sh"
appattic_require_swift
# The one spelling of the Swift build: the build root mapped out of the
# binary, resolution disabled. See scripts/swift-build.sh for why the mapping
# is here and not only in the C flags.
# shellcheck source=scripts/swift-build.sh
. "$ROOT/scripts/swift-build.sh"

OS="$(uname -s)"
HAVE_QT=0
HAVE_MAC_UI=0
if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists Qt6Widgets; then
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
    if appattic_swift_build "$CONFIG" --product appattic \
        && appattic_swift_build "$CONFIG" --product AppAtticUI; then
        HAVE_MAC_UI=1
    else
        # AppAtticUI needs swift-cross-ui 0.2.1, which needs a Swift 6 compiler;
        # --disable-automatic-resolution cannot fetch the package either. Build
        # the CLI alone rather than failing the whole build.
        export APPATTIC_NO_MAC_UI=1
        echo "note: AppAtticUI needs a Swift 6 compiler (swift-cross-ui 0.2.1); building the CLI only" >&2
        appattic_swift_build "$CONFIG" --product appattic
    fi
elif [[ "$OS" == Linux ]]; then
    echo "Building AppAttic CLI (${CONFIG})…"
    appattic_swift_build "$CONFIG" --product appattic
    if [[ "$HAVE_QT" -eq 1 ]]; then
        echo "Building Linux Qt 6 UI…"
        bash scripts/linux-qt-link.sh "$CONFIG"
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
    appattic_swift_build "$CONFIG" --product appattic
fi

CLI="$(resolve_bin appattic)" || {
    echo "error: appattic binary not found after appattic_swift_build $CONFIG" >&2
    exit 1
}

if [[ "$OS" == Darwin && "$HAVE_MAC_UI" -eq 1 ]]; then
    BIN="$(resolve_bin AppAtticUI)" || {
        echo "error: AppAtticUI binary not found after appattic_swift_build $CONFIG" >&2
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
    # Bundle mtimes come from the copy, so zipping the .app twice gives two
    # archives. Sign first: codesign rewrites the bundle, so touch has to be
    # the last thing that writes to it.
    # BSD touch (macOS) has no -h and no @epoch form; -t is the one both
    # spell. The bundle holds only copied files, so nothing follows a symlink.
    # The stamp is rendered in UTC and applied with TZ=UTC, because `touch -t`
    # reads its argument in local time: a host whose TZ is not UTC would give
    # every file in the bundle an mtime the machine's zone decided, and two
    # builds of one source two different archives.
    stamp="$(date -u -r "$SOURCE_DATE_EPOCH" +%Y%m%d%H%M.%S)"
    TZ=UTC find AppAttic.app -exec touch -t "$stamp" {} +
    echo "Built AppAttic.app"
    echo "Launch: open AppAttic.app"
    echo "CLI:    ./run.sh report"
    echo "        ${CLI}"
elif [[ "$OS" == Darwin ]]; then
    echo "macOS CLI: ${CLI}"
    echo "Launch CLI: ./run.sh report"
    echo "UI skipped (AppAtticUI needs a Swift 6 compiler; see .swift-version and the macos CI job)."
elif [[ "$OS" == Linux && "$HAVE_QT" -eq 1 ]]; then
    if [[ "$CONFIG" == release ]]; then
        echo "Linux UI: ui/linux-qt/build-release/appattic-qt"
    else
        echo "Linux UI: ui/linux-qt/build/appattic-qt"
    fi
    echo "CLI:      ${CLI}"
    echo "Launch UI: ./run.sh --ui"
    echo "Launch CLI: ./run.sh report"
else
    echo "Linux CLI: ${CLI}"
    echo "Launch: ./run.sh report"
    echo "UI skipped (install Qt 6, then ./build.sh again)."
fi
