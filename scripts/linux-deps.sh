#!/usr/bin/env bash
# Qt 6 + cmake/ninja/clang for AppAttic Linux UI, Wasmtime C API, Swift for CLI/tests.
# Ubuntu-built binaries are not assumed to run on Arch (glibc / Swift runtime).
# Build on the distro you will run.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WASMTIME_VER="${WASMTIME_C_API_VERSION:-28.0.0}"
ZIG_VER="${ZIG_VERSION:-0.16.0}"

usage() {
    cat <<'EOF'
Usage: scripts/linux-deps.sh [--install] [--install-swift] [--install-wasmtime]

  (no flags)           Print Qt 6, Wasmtime, and Swift notes for this distro.
  --install            Install Qt 6 Widgets headers, cmake, ninja, pkg-config, clang (needs root).
  --install-swift      Install Swift 5.10.1 (official Ubuntu 22.04 tarball) to /opt/swift.
  --install-wasmtime   Install Wasmtime C API headers/libs (needed to embed appattic_core.wasm).

Then run: bash scripts/linux-qt-link.sh

Arch Swift is not in extra. AUR package is swift-bin, or use --install-swift / swiftly.
The Ubuntu 22.04 Swift tarball needs that ABI (libpython3.10, older ICU). Prefer
Dockerfile (swift:5.10-jammy) or AUR swift-bin on Arch. Homebrew Qt on macOS is not Linux.
EOF
}

INSTALL_PKGS=0
INSTALL_SWIFT=0
INSTALL_WASMTIME=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL_PKGS=1 ;;
        --install-swift) INSTALL_SWIFT=1 ;;
        --install-wasmtime) INSTALL_WASMTIME=1 ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo "unknown argument: $arg" >&2
            usage >&2
            exit 2
            ;;
    esac
done

OS_RELEASE=""
if [[ -r /etc/os-release ]]; then
    OS_RELEASE=/etc/os-release
elif [[ -r /usr/lib/os-release ]]; then
    OS_RELEASE=/usr/lib/os-release
fi

ID=""
ID_LIKE=""
if [[ -n "$OS_RELEASE" ]]; then
    # shellcheck disable=SC1090
    . "$OS_RELEASE"
fi

id_lc="$(printf '%s' "${ID:-}" | tr '[:upper:]' '[:lower:]')"
like_lc="$(printf '%s' "${ID_LIKE:-}" | tr '[:upper:]' '[:lower:]')"
tokens=" $id_lc $like_lc "

family="unknown"
if [[ "$tokens" == *" arch "* || "$tokens" == *" archlinux "* || "$tokens" == *" manjaro "* \
    || "$tokens" == *" endeavouros "* || "$tokens" == *" garuda "* || "$tokens" == *" cachyos "* \
    || "$tokens" == *" artix "* ]]; then
    family="arch"
elif [[ "$tokens" == *" fedora "* || "$tokens" == *" rhel "* || "$tokens" == *" centos "* \
    || "$tokens" == *" rocky "* || "$tokens" == *" almalinux "* || "$tokens" == *" nobara "* ]]; then
    family="fedora"
elif [[ "$tokens" == *" suse "* || "$tokens" == *" sles "* || "$id_lc" == opensuse* ]]; then
    family="suse"
elif [[ "$tokens" == *" debian "* || "$tokens" == *" ubuntu "* || "$tokens" == *" linuxmint "* \
    || "$tokens" == *" pop "* ]]; then
    family="debian"
fi

# Dev headers + tools for cmake link; runtime QPA/OpenGL/xcb for headless --smoke (no Gtk).
debian_qt_pkgs=(
    ca-certificates curl xz-utils
    qt6-base-dev cmake ninja-build pkg-config clang libgl1-mesa-dev
    qt6-qpa-plugins libgl1 libxkbcommon0 libxcb1 libxcb-cursor0 libxcb-xinerama0 xvfb
)
arch_qt_pkgs=(qt6-base cmake ninja pkgconf clang curl xz zig libglvnd xorg-server-xvfb)
fedora_qt_pkgs=(
    qt6-qtbase-devel cmake ninja-build pkgconf-pkg-config clang curl xz zig
    qt6-qtbase qt6-qtbase-gui mesa-libGL xorg-x11-server-Xvfb
)
suse_qt_pkgs=(
    qt6-base-devel cmake ninja pkgconf-pkg-config clang curl xz zig
    libQt6Widgets6 libQt6Gui6 libqt6-qpa-plugins libGL1 libxkbcommon0 libxcb1 xorg-xserver
)

run_as_root() {
    if [[ "$(id -u)" -eq 0 ]]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        echo "error: need root for: $*" >&2
        exit 1
    fi
}

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

qt6_dev_ok() {
    qt6_pkg_config_ok && return 0
    qt6_cmake_ok && return 0
    return 1
}

debian_enable_universe() {
    [[ "$family" == debian ]] || return 0
    [[ "${ID:-}" == ubuntu ]] || return 0
    if grep -rqE '[[:space:]]universe([[:space:]]|$)' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
        return 0
    fi
    local f
    for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
        [[ -f "$f" ]] || continue
        if grep -qE '^deb ' "$f" && ! grep -qE '[[:space:]]universe([[:space:]]|$)' "$f"; then
            echo "enabling universe in $f (qt6-qpa-plugins)"
            run_as_root sed -i -E '/^deb /s/\s+main(\s|$)/ main universe\1/' "$f"
        fi
    done
}

debian_bootstrap_curl() {
    [[ "$family" == debian ]] || return 0
    command -v curl >/dev/null 2>&1 && command -v xz >/dev/null 2>&1 && return 0
    debian_enable_universe
    run_as_root apt-get update
    run_as_root apt-get install -y --no-install-recommends ca-certificates curl xz-utils
}

install_family_pkgs() {
    case "$family" in
        arch)
            run_as_root pacman -S --needed --noconfirm "${arch_qt_pkgs[@]}"
            ;;
        fedora)
            run_as_root dnf install -y "${fedora_qt_pkgs[@]}"
            ;;
        suse)
            run_as_root zypper --non-interactive install "${suse_qt_pkgs[@]}"
            ;;
        debian)
            debian_enable_universe
            run_as_root apt-get update
            run_as_root apt-get install -y --no-install-recommends "${debian_qt_pkgs[@]}"
            ;;
        *)
            echo "error: cannot --install Qt 6 on unrecognized distro" >&2
            exit 1
            ;;
    esac
}

qt_cmd=""
case "$family" in
    arch)
        qt_cmd="pacman -S --needed --noconfirm ${arch_qt_pkgs[*]}"
        ;;
    fedora)
        qt_cmd="dnf install -y ${fedora_qt_pkgs[*]}"
        ;;
    suse)
        qt_cmd="zypper --non-interactive install ${suse_qt_pkgs[*]}"
        ;;
    debian)
        qt_cmd="enable universe (Ubuntu), apt-get update, apt-get install -y ${debian_qt_pkgs[*]}"
        ;;
    *)
        qt_cmd=""
        ;;
esac

echo "distro: ${ID:-unknown}  family: $family"
if [[ -n "$qt_cmd" ]]; then
    echo "Qt 6: $qt_cmd"
else
    echo "Qt 6: install Qt 6 Widgets development files, cmake, ninja, pkg-config, and clang."
    echo "Debian/Ubuntu: apt install qt6-base-dev qt6-qpa-plugins libgl1 xvfb cmake ninja-build pkg-config clang"
    echo "Fedora:        dnf install qt6-qtbase-devel cmake ninja-build pkgconf-pkg-config clang"
    echo "Arch:          pacman -S qt6-base cmake ninja pkgconf clang"
    echo "openSUSE:      zypper install qt6-base-devel cmake ninja pkgconf-pkg-config clang"
fi

echo "Zig ${ZIG_VER}: official tarball on Debian/Ubuntu (no apt zig on jammy/noble); distro pkg elsewhere if >= ${ZIG_VER}"
echo "Wasmtime C API ${WASMTIME_VER}: bash $0 --install-wasmtime"
echo "Swift 5.10: needed to compile the CLI and tests. Not shipped as a universal Linux binary."
case "$family" in
    arch)
        echo "  Arch extra has no Swift compiler. AUR: swift-bin (or swiftly-bin)."
        echo "  Or: $0 --install-swift   (Ubuntu 22.04 toolchain into /opt/swift)"
        ;;
    debian)
        echo "  swiftly: https://www.swift.org/install/linux/"
        echo "  Or Ubuntu 22.04/24.04 Swift.org packages, or $0 --install-swift"
        ;;
    fedora|suse)
        echo "  swiftly: https://www.swift.org/install/linux/"
        echo "  Or: $0 --install-swift   (Ubuntu 22.04 toolchain into /opt/swift)"
        ;;
    *)
        echo "  swiftly: https://www.swift.org/install/linux/"
        echo "  Or: $0 --install-swift"
        ;;
esac
echo "Build on the machine you run. Do not copy an Ubuntu build onto Arch and expect it to start."
echo "After Qt 6 + Wasmtime + zig are installed: bash scripts/linux-qt-link.sh"
if [[ "$family" == debian ]]; then
    ver="${VERSION_ID:-}"
    if [[ "$ver" == 24.04 ]]; then
        echo "Ubuntu 24.04: Swift 5.10.1 tarball targets 22.04 (libpython3.10). Prefer swiftly, Dockerfile, or CI setup-swift."
    fi
fi

zig_ok() {
    command -v zig >/dev/null 2>&1 && zig version 2>/dev/null | grep -qE "^${ZIG_VER%.*}\."
}

install_zig_tarball() {
    local dest=""
    if [[ -w /opt ]] || [[ "$(id -u)" -eq 0 ]]; then
        dest="/opt/zig"
    else
        dest="$ROOT/.deps/zig"
    fi
    if [[ -x "$dest/zig" ]] && "$dest/zig" version 2>/dev/null | grep -qE "^${ZIG_VER%.*}\."; then
        echo "Zig already at $dest/zig"
        "$dest/zig" version | head -n 1
        export PATH="$dest:${PATH:-}"
        if [[ "$(id -u)" -eq 0 ]]; then
            ln -sf "$dest/zig" /usr/local/bin/zig
        fi
        return 0
    fi
    if ! command -v curl >/dev/null 2>&1; then
        debian_bootstrap_curl
    fi
    if ! command -v curl >/dev/null 2>&1; then
        echo "error: curl required to install zig ${ZIG_VER}" >&2
        exit 1
    fi
    local arch
    arch="$(uname -m)"
    local triple=""
    case "$arch" in
        x86_64) triple="x86_64" ;;
        aarch64|arm64) triple="aarch64" ;;
        *)
            echo "error: no Zig ${ZIG_VER} tarball for $arch" >&2
            exit 1
            ;;
    esac
    local url="https://ziglang.org/download/${ZIG_VER}/zig-${triple}-linux-${ZIG_VER}.tar.xz"
    echo "Downloading Zig ${ZIG_VER} ($triple)…"
    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN
    curl -fsSL "$url" | tar -xJ -C "$tmp"
    local unpacked
    unpacked="$(printf '%s\n' "$tmp"/zig-* | head -n 1)"
    if [[ ! -x "$unpacked/zig" ]]; then
        echo "error: Zig tarball layout unexpected" >&2
        exit 1
    fi
    mkdir -p "$(dirname "$dest")"
    rm -rf "$dest"
    mv "$unpacked" "$dest"
    if [[ "$(id -u)" -eq 0 ]]; then
        ln -sf "$dest/zig" /usr/local/bin/zig
    fi
    export PATH="$dest:${PATH:-}"
    echo "Installed Zig ${ZIG_VER} to $dest"
    echo "export PATH=\"$dest:\$PATH\""
    "$dest/zig" version | head -n 1
}

emit_ci_path() {
    local d
    for d in /opt/zig /usr/local/bin; do
        if [[ "$d" == /opt/zig && -x "$d/zig" ]] || [[ "$d" == /usr/local/bin && ( -x "$d/zig" || -L "$d/zig" ) ]]; then
            if [[ -n "${GITHUB_PATH:-}" ]]; then
                echo "$d" >>"$GITHUB_PATH"
                echo "CI PATH: $d"
            fi
        fi
    done
}

if [[ "$INSTALL_PKGS" -eq 1 ]]; then
    echo "Installing Qt 6…"
    install_family_pkgs
    if ! command -v pkg-config >/dev/null 2>&1; then
        echo "error: pkg-config still missing after install" >&2
        exit 1
    fi
    if ! qt6_dev_ok; then
        echo "error: Qt 6 still missing after install (pkg-config Qt6Widgets or Qt6Config.cmake)" >&2
        exit 1
    fi
    if qt6_pkg_config_ok; then
        echo "Qt6Widgets: $(pkg-config --modversion Qt6Widgets 2>/dev/null || pkg-config --modversion Qt6Core)"
    elif qt6_cmake_ok; then
        echo "Qt6: cmake config present (no pkg-config .pc on this distro)"
    fi
    smoke_plugin=""
    archdir="$(uname -m)"
    for d in "/usr/lib/${archdir}-linux-gnu/qt6/plugins/platforms" \
             "/usr/lib/qt6/plugins/platforms" \
             "/usr/lib64/qt6/plugins/platforms"; do
        if [[ -f "$d/libqoffscreen.so" ]]; then
            smoke_plugin="$d/libqoffscreen.so"
            break
        fi
    done
    if [[ -z "$smoke_plugin" && "$family" == debian ]]; then
        echo "error: libqoffscreen.so missing; install qt6-qpa-plugins" >&2
        exit 1
    fi
    if [[ -n "$smoke_plugin" ]]; then
        echo "Qt offscreen plugin: $smoke_plugin"
    fi
    if qt6_pkg_config_ok && pkg-config --exists Qt6Widgets; then
        echo "Qt6Widgets: $(pkg-config --modversion Qt6Widgets)"
    fi
    if ! command -v cmake >/dev/null 2>&1; then
        echo "error: cmake still missing after install" >&2
        exit 1
    fi
    echo "cmake: $(cmake --version | head -n 1)"
    if command -v clang >/dev/null 2>&1; then
        echo "clang: $(clang --version | head -n 1)"
    fi
    if ! zig_ok; then
        install_zig_tarball
    fi
    if ! zig_ok; then
        echo "error: zig ${ZIG_VER} still missing after install" >&2
        exit 1
    fi
    echo "zig: $(zig version | head -n 1)"
    emit_ci_path
fi

install_wasmtime_c_api() {
    local dest=""
    if [[ -w /opt ]] || [[ "$(id -u)" -eq 0 ]]; then
        dest="/opt/wasmtime-c-api"
    else
        dest="$ROOT/.deps/wasmtime-c-api"
    fi
    if [[ -f "$dest/include/wasmtime.h" ]]; then
        echo "Wasmtime C API already at $dest"
        return 0
    fi
    if ! command -v curl >/dev/null 2>&1; then
        echo "error: curl required for --install-wasmtime" >&2
        exit 1
    fi
    local arch
    arch="$(uname -m)"
    local triple=""
    case "$arch" in
        x86_64) triple="x86_64-linux" ;;
        aarch64|arm64) triple="aarch64-linux" ;;
        *)
            echo "error: no Wasmtime C API tarball for $arch" >&2
            exit 1
            ;;
    esac
    local url="https://github.com/bytecodealliance/wasmtime/releases/download/v${WASMTIME_VER}/wasmtime-v${WASMTIME_VER}-${triple}-c-api.tar.xz"
    echo "Downloading Wasmtime C API ${WASMTIME_VER} ($triple)…"
    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN
    curl -fsSL "$url" | tar -xJ -C "$tmp"
    local unpacked
    unpacked="$(printf '%s\n' "$tmp"/wasmtime-* | head -n 1)"
    if [[ ! -d "$unpacked" ]]; then
        echo "error: Wasmtime tarball layout unexpected" >&2
        exit 1
    fi
    mkdir -p "$(dirname "$dest")"
    rm -rf "$dest"
    mv "$unpacked" "$dest"
    if [[ ! -f "$dest/include/wasmtime.h" ]]; then
        echo "error: $dest/include/wasmtime.h missing after unpack" >&2
        exit 1
    fi
    echo "Installed Wasmtime C API to $dest"
    echo "export WASMTIME_DIR=\"$dest\""
}

if [[ "$INSTALL_WASMTIME" -eq 1 ]]; then
    if ! command -v curl >/dev/null 2>&1; then
        debian_bootstrap_curl
    fi
    install_wasmtime_c_api
fi

install_swift_tarball() {
    local ver="5.10.1"
    local dest="/opt/swift"
    if [[ -x "$dest/usr/bin/swift" ]]; then
        echo "Swift already at $dest/usr/bin/swift"
        "$dest/usr/bin/swift" --version | head -n 1
        return 0
    fi
    if [[ "$(id -u)" -ne 0 && ! -w /opt ]]; then
        echo "error: --install-swift writes /opt/swift (root, AUR swift-bin, or swiftly)" >&2
        exit 1
    fi
    if ! command -v curl >/dev/null 2>&1; then
        debian_bootstrap_curl
    fi
    if ! command -v curl >/dev/null 2>&1; then
        echo "error: curl required for --install-swift" >&2
        exit 1
    fi
    local arch
    arch="$(uname -m)"
    local url
    case "$arch" in
        x86_64)
            url="https://download.swift.org/swift-${ver}-release/ubuntu2204/swift-${ver}-RELEASE/swift-${ver}-RELEASE-ubuntu22.04.tar.gz"
            ;;
        aarch64|arm64)
            url="https://download.swift.org/swift-${ver}-release/ubuntu2204-aarch64/swift-${ver}-RELEASE/swift-${ver}-RELEASE-ubuntu22.04-aarch64.tar.gz"
            ;;
        *)
            echo "error: no Swift ${ver} Linux tarball for $arch" >&2
            echo "Install swiftly or AUR swift-bin." >&2
            exit 1
            ;;
    esac
    echo "Downloading Swift ${ver} for $arch…"
    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN
    curl -fsSL "$url" | tar -xz -C "$tmp"
    local unpacked
    unpacked="$(printf '%s\n' "$tmp"/swift-* | head -n 1)"
    if [[ ! -d "$unpacked" ]]; then
        echo "error: Swift tarball layout unexpected" >&2
        exit 1
    fi
    mkdir -p /opt
    rm -rf "$dest"
    mv "$unpacked" "$dest"
    echo "Installed Swift ${ver} to $dest/usr/bin"
    echo "export PATH=\"$dest/usr/bin:\$PATH\""
    if ! "$dest/usr/bin/swift" --version >/dev/null 2>&1; then
        echo "error: $dest/usr/bin/swift did not start. Ubuntu 22.04 tarball needs that ABI." >&2
        echo "Arch: AUR swift-bin. Ubuntu 24.04: swiftly or Dockerfile (swift:5.10-jammy)." >&2
        if command -v ldd >/dev/null 2>&1; then
            ldd "$dest/usr/bin/swift" >&2 || true
        fi
        exit 1
    fi
    "$dest/usr/bin/swift" --version | head -n 1
}

if [[ "$INSTALL_SWIFT" -eq 1 ]]; then
    install_swift_tarball
    echo "Next: export PATH=\"/opt/swift/usr/bin:\$PATH\""
    echo "      bash scripts/linux-qt-link.sh"
fi
