#!/usr/bin/env bash
# Qt 6 + cmake/ninja/clang for AppAttic Linux UI, Wasmtime C API, Swift for CLI/tests.
# Ubuntu-built binaries are not assumed to run on Arch (glibc / Swift runtime).
# Build on the distro you will run.
set -euo pipefail

_script_dir="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$_script_dir/.." && pwd)"
export LC_ALL=C
export LANG=C
export TZ=UTC
export DEBIAN_FRONTEND=noninteractive
# Checksums live next to this script so a Docker COPY of scripts/*.sh still verifies.
# shellcheck source=verify-sha256.sh
. "$_script_dir/verify-sha256.sh"
WASMTIME_VER="${WASMTIME_C_API_VERSION:-28.0.0}"
# shellcheck source=find-zig.sh
. "$_script_dir/find-zig.sh"
ZIG_VER="$(appattic_zig_version)" || exit 1
# shellcheck source=find-wasmtime.sh
. "$_script_dir/find-wasmtime.sh"
# The Swift note has to name the exact version, not a series: find-swift.sh
# rejects anything but the one in .swift-version, so a preflight that said
# "5.10" would pass a machine that scripts/check.sh then refuses.
# shellcheck source=find-swift.sh
. "$_script_dir/find-swift.sh"
SWIFT_VER="$(appattic_swift_version)" || exit 1

usage() {
    cat <<'EOF'
Usage: scripts/linux-deps.sh [--install] [--install-swift] [--install-wasmtime] [--install-zig]
                              [--install-shellcheck] [--install-desktop-file-utils]

  (no flags)           Preflight: report every dependency as present or missing,
                       against the versions .zig-version and .swift-version pin.
  --install            Install Qt 6 Widgets headers, cmake, ninja, pkg-config, clang (needs root).
  --install-swift      Install the .swift-version toolchain (official Ubuntu 22.04
                       tarball) to /opt/swift, or .deps/swift without root.
  --install-wasmtime   Install Wasmtime C API headers/libs (needed to embed appattic_core.wasm).
  --install-zig        Install the .zig-version toolchain only (no Qt, no wasmtime).
  --install-shellcheck  Install shellcheck (scripts/lint.sh needs it).
  --install-desktop-file-utils  Install desktop-file-validate, which
                       scripts/check-packaging.sh runs on the desktop entry.

Then run: bash scripts/linux-qt-link.sh

Arch Swift is not in extra. AUR package is swift-bin, or use --install-swift / swiftly.
The Ubuntu 22.04 Swift tarball needs that ABI (libpython3.10, older ICU). Prefer
Dockerfile (swift:5.10.1-jammy) or AUR swift-bin on Arch. Homebrew Qt on macOS is not Linux.

Every --install-* flag installs a Linux artifact: a distro package, or a
tarball whose pinned checksum in dep-checksums.sha256 is a linux triple. On
macOS each one stops with the Homebrew or Xcode command instead, and the
report marks the Qt 6 window as a Linux target rather than a missing tool.
EOF
}

# macOS is a supported host (build.sh has a Darwin branch, .swift-version is
# pinned for it, linux.yml runs a macos job), and it has no /etc/os-release.
# The host is read before anything is reported, so the preflight says what the
# machine is rather than what this script hoped for: without it a Mac was
# answered with "distro: unknown family: unknown" plus apt/dnf/pacman install
# lines, and every --install-* flag went on to fetch a Linux tarball.
host_os="$(uname -s)"

INSTALL_PKGS=0
INSTALL_SWIFT=0
INSTALL_WASMTIME=0
INSTALL_ZIG=0
INSTALL_SHELLCHECK=0
INSTALL_DESKTOP_FILE_UTILS=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL_PKGS=1 ;;
        --install-swift) INSTALL_SWIFT=1 ;;
        --install-wasmtime) INSTALL_WASMTIME=1 ;;
        --install-zig) INSTALL_ZIG=1 ;;
        --install-shellcheck) INSTALL_SHELLCHECK=1 ;;
        --install-desktop-file-utils) INSTALL_DESKTOP_FILE_UTILS=1 ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo "error: unknown argument: $arg" >&2
            echo "Usage: $0 [--install] [--install-swift] [--install-wasmtime] [--install-zig]" >&2
            echo "       [--install-shellcheck]" >&2
            echo "       $0 --help" >&2
            exit 2
            ;;
    esac
done

# One guard for every flag, before any of them can reach a package manager or
# a download URL. macOS is a supported host (build.sh, .swift-version, the
# macos job in linux.yml), so the honest answer there is a named refusal plus
# the command that does work, not a Linux tarball fetched into /opt.
if [[ "$host_os" == Darwin ]]; then
    for pair in \
        "$INSTALL_PKGS|--install|brew install qt cmake ninja pkg-config zig wasmtime clang-format" \
        "$INSTALL_WASMTIME|--install-wasmtime|brew install wasmtime  (then: export WASMTIME_DIR=\$(brew --prefix wasmtime))" \
        "$INSTALL_ZIG|--install-zig|brew install zig  (core/build.sh wants exactly $(cat "$ROOT/.zig-version"))" \
        "$INSTALL_SWIFT|--install-swift|xcode-select --install  then check 'swift --version' against .swift-version" \
        "$INSTALL_SHELLCHECK|--install-shellcheck|brew install shellcheck" \
        "$INSTALL_DESKTOP_FILE_UTILS|--install-desktop-file-utils|scripts/check-packaging.sh notes the skip when it is absent"
    do
        if [[ "${pair%%|*}" == 1 ]]; then
            rest="${pair#*|}"
            flag="${rest%%|*}"
            echo "error: $flag is a Linux-only installer; this host is macOS ($host_os $(uname -m))" >&2
            echo "macOS: ${pair##*|}" >&2
            echo "note: the Linux UI is built on a Linux host; scripts/linux-qt-link.sh exits 3 on macOS" >&2
            exit 2
        fi
    done
fi

ID=""
ID_LIKE=""
if [[ -r /etc/os-release ]]; then
    . /etc/os-release
elif [[ -r /usr/lib/os-release ]]; then
    . /usr/lib/os-release
fi

id_lc="$(printf '%s' "${ID:-}" | tr '[:upper:]' '[:lower:]')"
like_lc="$(printf '%s' "${ID_LIKE:-}" | tr '[:upper:]' '[:lower:]')"
tokens=" $id_lc $like_lc "

family="unknown"
if [[ "$host_os" != Darwin ]]; then
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
fi

# Dev headers + tools for cmake link; runtime QPA/OpenGL/xcb for headless --smoke (no Gtk).
# Zig is deliberately absent from every list: the tarball installed below is
# checksummed and carries the .zig-version pin, so a distro package of another
# version never takes its place.
debian_qt_pkgs=(
    ca-certificates curl xz-utils
    qt6-base-dev cmake ninja-build pkg-config patchelf clang libgl1-mesa-dev
    qt6-qpa-plugins libgl1 libxkbcommon0 libxcb1 libxcb-cursor0 libxcb-xinerama0 xvfb
)
arch_qt_pkgs=(qt6-base cmake ninja pkgconf patchelf clang curl xz libglvnd xorg-server-xvfb)
fedora_qt_pkgs=(
    qt6-qtbase-devel cmake ninja-build pkgconf-pkg-config patchelf clang curl xz
    qt6-qtbase qt6-qtbase-gui mesa-libGL xorg-x11-server-Xvfb
)
suse_qt_pkgs=(
    qt6-base-devel cmake ninja pkgconf-pkg-config patchelf clang curl xz
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

# shellcheck source=find-qt6.sh
. "$_script_dir/find-qt6.sh"

# Either discovery path finding Qt 6 is enough to build against; a tree with
# only one of them still has a cmake or a pkg-config answer.
qt6_dev_ok() {
    appattic_qt6_pkg_config_ok || appattic_qt6_cmake_ok
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

# Download a pinned release tarball, unpack the single top-level directory it
# holds, and move that directory to dest. The Zig, Wasmtime and Swift
# installers differ only in the archive they name, so the pin check, the
# download and the unpack live here once.
#   $1 url  $2 archive  $3 top-level dir prefix  $4 tar decompress flag
#   $5 progress line  $6 label for layout errors  $7 pin hint  $8 dest
install_release_tarball() {
    local url="$1" archive="$2" prefix="$3" tarflag="$4"
    local message="$5" label="$6" hint="$7" dest="$8"
    local expected
    expected="$(checksum_for "$archive")" || {
        echo "error: no pinned SHA-256 for $archive${hint}" >&2
        exit 1
    }
    echo "$message"
    local tmp
    tmp="$(mktemp -d)"
    curl_fetch "$url" "$tmp/$archive"
    verify_sha256 "$tmp/$archive" "$expected"
    tar "$tarflag" -C "$tmp" -f "$tmp/$archive"
    rm -f "$tmp/$archive"
    local unpacked
    unpacked="$(printf '%s\n' "$tmp"/"$prefix"* | LC_ALL=C sort | head -n 1)"
    if [[ ! -d "$unpacked" ]]; then
        echo "error: ${label} layout unexpected" >&2
        exit 1
    fi
    mkdir -p "$(dirname "$dest")"
    rm -rf "$dest"
    mv "$unpacked" "$dest"
    rm -rf "$tmp"
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

if [[ "$host_os" == Darwin ]]; then
    echo "host: macOS $(uname -m)"
    echo "note: the Qt 6 window is a Linux target; the CLI and scan library build here."
else
    echo "distro: ${ID:-unknown}  family: $family"
fi

# Every dependency is reported as found or missing, so this doubles as the
# preflight a contributor runs first: before, it printed the same install
# command on a machine that already had the tool, and nothing said what was
# still missing. `present <name>: <detail>` and `missing <name>:` are the only
# two shapes, and the install hint follows a `missing` line only.
present() { echo "  present $1${2:+ ($2)}"; }
missing() {
    echo "  missing $1"
    shift
    printf '    %s\n' "$@"
}

# The install line a missing tool names has to be the one that works on this
# host: the flag when it is Linux, the Homebrew or Xcode command when it is
# not. Every hint below reads these two, so a Mac is never told to apt-get a
# package Homebrew carries under a different name.
if [[ "$host_os" == Darwin ]]; then
    zig_install="brew install zig   (core/build.sh wants exactly ${ZIG_VER}; brew ships its own)"
    wasmtime_install="brew install wasmtime   (export WASMTIME_DIR=\$(brew --prefix wasmtime))"
    shellcheck_install="brew install shellcheck"
    swift_install="xcode-select --install   then check 'swift --version' against .swift-version (or: https://www.swift.org/install/)"
    desktop_validate_install="scripts/check-packaging.sh notes the skip when it is absent; macOS has no distro package"
else
    zig_install="bash $0 --install-zig (checksummed tarball, never a distro package)"
    wasmtime_install="bash $0 --install-wasmtime"
    shellcheck_install="bash $0 --install-shellcheck"
    swift_install="bash $0 --install-swift   (Ubuntu 22.04 toolchain into /opt/swift or .deps/swift)"
    desktop_validate_install="bash $0 --install-desktop-file-utils"
fi

# zig_ok reads .zig-version, so a zig of another version counts as missing
# rather than as a tool that is there and wrong.
if command -v zig >/dev/null 2>&1; then
    have="$(zig version 2>/dev/null || true)"
    if [[ "$have" == "$ZIG_VER" ]]; then
        present "zig ${ZIG_VER}" "$have"
    else
        missing "zig (need ${ZIG_VER}, found ${have:-unknown})" "$zig_install"
    fi
else
    missing "zig ${ZIG_VER}" "$zig_install"
fi

if qt6_dev_ok; then
    ver="$(pkg-config --modversion Qt6Widgets 2>/dev/null || printf 'cmake config only')"
    present "Qt 6" "$ver"
elif [[ "$host_os" == Darwin ]]; then
    # Not a defect on macOS: the Qt window is a Linux target (linux-qt-link.sh
    # exits 3 on Darwin), and core/build.sh + the Qt link need its headers on
    # the Linux host that runs them. Saying so beats four lines of apt/dnf.
    echo "  n/a     Qt 6 (Linux target: build the window on a Linux host)"
else
    missing "Qt 6 Widgets development files" \
        "cmake, ninja, pkg-config and clang come with it" \
        "Debian/Ubuntu: apt install qt6-base-dev qt6-qpa-plugins libgl1 xvfb cmake ninja-build pkg-config clang" \
        "Fedora:        dnf install qt6-qtbase-devel cmake ninja-build pkgconf-pkg-config clang" \
        "Arch:          pacman -S qt6-base cmake ninja pkgconf clang" \
        "openSUSE:      zypper install qt6-base-devel cmake ninja pkgconf-pkg-config clang"
fi

if appattic_find_wasmtime; then
    present "Wasmtime C API ${WASMTIME_VER}" "${WASMTIME_DIR:-pkg-config}"
else
    missing "Wasmtime C API ${WASMTIME_VER} (embed.c and the Qt link need it)" \
        "$wasmtime_install"
fi

if command -v shellcheck >/dev/null 2>&1; then
    present "shellcheck" "$(command -v shellcheck)"
else
    missing "shellcheck (scripts/lint.sh needs it)" "$shellcheck_install"
fi

if command -v yamllint >/dev/null 2>&1; then
    present "yamllint" "$(command -v yamllint)"
else
    missing "yamllint (scripts/lint.sh needs it)" \
        "uv tool install \"yamllint==$(bash "$_script_dir/deps.sh" yamllint-version)\""
fi

if command -v cc >/dev/null 2>&1; then
    present "cc" "$(command -v cc)"
else
    missing "cc (the C host gate needs it)" "install a C compiler: gcc or clang"
fi

# lint.sh compiles every C file under core/host with each compiler it finds,
# and the two disagree on what they diagnose, so a machine with only one
# compiler passes a defect the other would warn about. CI has both, so
# without clang a local gate is weaker than the CI gate it stands in for.
if command -v clang >/dev/null 2>&1; then
    present "clang" "$(command -v clang)"
elif [[ "$host_os" == Darwin ]]; then
    # Xcode ships it; the prompt above a clean macOS clone never did.
    missing "clang (scripts/lint.sh compiles with cc and clang; without it the local run is weaker than CI)" \
        "xcode-select --install"
else
    missing "clang (scripts/lint.sh compiles with cc and clang; without it the local run is weaker than CI)" \
        "bash $0 --install"
fi

# check-packaging.sh runs desktop-file-validate on the desktop entry when it
# is on PATH and only notes the skip when it is not. CI installs it so the
# check is blocking there; a preflight that stayed silent about it left the
# desktop entry unvalidated locally with nothing naming the tool.
if command -v desktop-file-validate >/dev/null 2>&1; then
    present "desktop-file-validate" "$(command -v desktop-file-validate)"
else
    missing "desktop-file-validate (scripts/check-packaging.sh runs it on the desktop entry; without it the check only notes the skip)" \
        "$desktop_validate_install"
fi

# Swift is the one tool with no single install command: the distro packages
# differ, and the tarball is built for another glibc. Report the version found
# against the pin, because a swift of the wrong version fails the same way a
# missing one does.
if appattic_find_swift; then
    have="$(swift --version 2>/dev/null | head -n 1)"
    case "$have" in
        *"Swift version ${SWIFT_VER} "*|*"Apple Swift version ${SWIFT_VER} "*)
            present "swift ${SWIFT_VER}" "$have"
            ;;
        *)
            missing "swift ${SWIFT_VER} (found: ${have:-unknown})" "$swift_install"
            ;;
    esac
else
    missing "swift ${SWIFT_VER} (needed to compile the CLI and tests)" "$swift_install"
    if [[ "$family" == arch ]]; then
        echo "    Arch extra has no Swift compiler. AUR: swift-bin (or swiftly-bin)."
    fi
fi

if [[ "$host_os" == Darwin ]]; then
    echo "Then: ./build.sh debug   (CLI + AppAttic.app)   bash scripts/check.sh"
else
    echo "Build on the machine you run. Do not copy an Ubuntu build onto Arch and expect it to start."
    echo "With Qt 6, Wasmtime and zig present: bash scripts/linux-qt-link.sh"
fi
if [[ "$family" == debian ]]; then
    ver="${VERSION_ID:-}"
    if [[ "$ver" == 24.04 ]]; then
        echo "Ubuntu 24.04: Swift ${SWIFT_VER} tarball targets 22.04 (libpython3.10). Prefer swiftly, Dockerfile, or CI setup-swift."
    fi
fi

zig_ok() {
    command -v zig >/dev/null 2>&1 && [[ "$(zig version 2>/dev/null)" == "$ZIG_VER" ]]
}

install_zig_tarball() {
    local dest=""
    if [[ -w /opt ]] || [[ "$(id -u)" -eq 0 ]]; then
        dest="/opt/zig"
    else
        dest="$ROOT/.deps/zig"
    fi
    if [[ -x "$dest/zig" ]] && [[ "$("$dest/zig" version 2>/dev/null)" == "$ZIG_VER" ]]; then
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
    local archive="zig-${triple}-linux-${ZIG_VER}.tar.xz"
    local url="https://ziglang.org/download/${ZIG_VER}/${archive}"
    install_release_tarball "$url" "$archive" "zig-" -xJ \
        "Downloading Zig ${ZIG_VER} ($triple)…" "Zig tarball" \
        " (ZIG_VERSION=$ZIG_VER)" "$dest"
    if [[ ! -x "$dest/zig" ]]; then
        echo "error: Zig tarball layout unexpected" >&2
        exit 1
    fi
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
                # $GITHUB_PATH is append-only, so a rerun in the same job would
                # otherwise stack another copy of each directory on PATH.
                if ! grep -qxF "$d" "$GITHUB_PATH" 2>/dev/null; then
                    echo "$d" >>"$GITHUB_PATH"
                fi
                echo "CI PATH: $d"
            fi
        fi
    done
}

# A missing Zig is worth one download attempt; a second miss after the install
# is a broken network or a bad tarball, and a build that goes on without the
# toolchain reports it much later and much less clearly.
ensure_zig_on_path() {
    if ! zig_ok; then
        install_zig_tarball
    fi
    if ! zig_ok; then
        echo "error: zig ${ZIG_VER} still missing after install" >&2
        exit 1
    fi
    echo "zig: $(zig version | head -n 1)"
    emit_ci_path
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
    if appattic_qt6_pkg_config_ok; then
        echo "Qt6Widgets: $(pkg-config --modversion Qt6Widgets 2>/dev/null || pkg-config --modversion Qt6Core)"
    elif appattic_qt6_cmake_ok; then
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
    if appattic_qt6_pkg_config_ok && pkg-config --exists Qt6Widgets; then
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
    ensure_zig_on_path
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
    local archive="wasmtime-v${WASMTIME_VER}-${triple}-c-api.tar.xz"
    local url="https://github.com/bytecodealliance/wasmtime/releases/download/v${WASMTIME_VER}/${archive}"
    install_release_tarball "$url" "$archive" "wasmtime-" -xJ \
        "Downloading Wasmtime C API ${WASMTIME_VER} ($triple)…" "Wasmtime tarball" \
        " (WASMTIME_C_API_VERSION=$WASMTIME_VER)" "$dest"
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
    local ver="$SWIFT_VER"
    local dest=""
    if [[ -w /opt ]] || [[ "$(id -u)" -eq 0 ]]; then
        dest="/opt/swift"
    else
        dest="$ROOT/.deps/swift"
    fi
    if [[ -x "$dest/usr/bin/swift" ]]; then
        echo "Swift already at $dest/usr/bin/swift"
        "$dest/usr/bin/swift" --version | awk 'NR==1 {print; exit}'
        return 0
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
    local archive=""
    local url
    case "$arch" in
        x86_64)
            archive="swift-${ver}-RELEASE-ubuntu22.04.tar.gz"
            url="https://download.swift.org/swift-${ver}-release/ubuntu2204/swift-${ver}-RELEASE/${archive}"
            ;;
        aarch64|arm64)
            archive="swift-${ver}-RELEASE-ubuntu22.04-aarch64.tar.gz"
            url="https://download.swift.org/swift-${ver}-release/ubuntu2204-aarch64/swift-${ver}-RELEASE/${archive}"
            ;;
        *)
            echo "error: no Swift ${ver} Linux tarball for $arch" >&2
            echo "Install swiftly or AUR swift-bin." >&2
            exit 1
            ;;
    esac
    install_release_tarball "$url" "$archive" "swift-" -xz \
        "Downloading Swift ${ver} for $arch…" "Swift tarball" "" "$dest"
    echo "Installed Swift ${ver} to $dest/usr/bin"
    echo "export PATH=\"$dest/usr/bin:\$PATH\""
    if ! "$dest/usr/bin/swift" --version >/dev/null 2>&1; then
        echo "error: $dest/usr/bin/swift did not start. Ubuntu 22.04 tarball needs that ABI." >&2
        echo "Arch: AUR swift-bin. Ubuntu 24.04: swiftly or Dockerfile (swift:5.10.1-jammy)." >&2
        if command -v ldd >/dev/null 2>&1; then
            ldd "$dest/usr/bin/swift" >&2 || true
        fi
        exit 1
    fi
    "$dest/usr/bin/swift" --version | awk 'NR==1 {print; exit}'
}

if [[ "$INSTALL_SWIFT" -eq 1 ]]; then
    install_swift_tarball
    echo "Then: bash scripts/linux-qt-link.sh"
fi

# scripts/lint.sh runs `zig fmt --check`. The lint job has no Qt, so it needs
# the toolchain on its own rather than through --install.
if [[ "$INSTALL_ZIG" -eq 1 ]]; then
    ensure_zig_on_path
fi

install_shellcheck() {
    if command -v shellcheck >/dev/null 2>&1; then
        echo "shellcheck already on PATH: $(command -v shellcheck)"
        return 0
    fi
    case "$family" in
        arch) run_as_root pacman -S --needed --noconfirm shellcheck ;;
        fedora) run_as_root dnf install -y ShellCheck ;;
        suse) run_as_root zypper --non-interactive install shellcheck ;;
        debian)
            debian_enable_universe
            run_as_root apt-get update
            run_as_root apt-get install -y --no-install-recommends shellcheck
            ;;
        *)
            echo "error: cannot install shellcheck on unrecognized distro" >&2
            echo "Debian/Ubuntu: apt install shellcheck" >&2
            echo "Fedora:        dnf install ShellCheck" >&2
            echo "Arch:          pacman -S shellcheck" >&2
            echo "openSUSE:      zypper install shellcheck" >&2
            return 1
            ;;
    esac
    echo "shellcheck: $(command -v shellcheck || printf 'not on PATH')"
}

if [[ "$INSTALL_SHELLCHECK" -eq 1 ]]; then
    install_shellcheck
    echo "Then: bash scripts/lint.sh"
fi

# desktop-file-validate validates the desktop entry the Qt install ships.
# scripts/check-packaging.sh runs it when it is on PATH and names the skip when
# it is not, so CI installs it rather than letting the gate go unchecked.
install_desktop_file_utils() {
    if command -v desktop-file-validate >/dev/null 2>&1; then
        echo "desktop-file-validate already on PATH: $(command -v desktop-file-validate)"
        return 0
    fi
    case "$family" in
        arch) run_as_root pacman -S --needed --noconfirm desktop-file-utils ;;
        fedora) run_as_root dnf install -y desktop-file-utils ;;
        suse) run_as_root zypper --non-interactive install desktop-file-utils ;;
        debian)
            run_as_root apt-get update
            run_as_root apt-get install -y --no-install-recommends desktop-file-utils
            ;;
        *)
            echo "error: cannot install desktop-file-utils on unrecognized distro" >&2
            echo "Debian/Ubuntu: apt install desktop-file-utils" >&2
            echo "Fedora:        dnf install desktop-file-utils" >&2
            echo "Arch:          pacman -S desktop-file-utils" >&2
            echo "openSUSE:      zypper install desktop-file-utils" >&2
            return 1
            ;;
    esac
    echo "desktop-file-validate: $(command -v desktop-file-validate || printf 'not on PATH')"
}

if [[ "$INSTALL_DESKTOP_FILE_UTILS" -eq 1 ]]; then
    install_desktop_file_utils
    echo "Then: bash scripts/check-packaging.sh"
fi
