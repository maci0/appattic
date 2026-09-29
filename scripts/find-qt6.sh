# shellcheck shell=bash
# Sourced by scripts/linux-deps.sh, scripts/linux-qt-link.sh, and
# scripts/linux-appimage.sh. Requires ROOT.

appattic_pkg_config_path() {
    local archdir d extra=""
    archdir="$(uname -m)"
    for d in "/usr/lib/${archdir}-linux-gnu/pkgconfig" \
             "/usr/lib64/pkgconfig" \
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

appattic_qt6_pkg_config_ok() {
    appattic_pkg_config_path
    pkg-config --exists Qt6Widgets 2>/dev/null && return 0
    pkg-config --exists Qt6Core 2>/dev/null && return 0
    return 1
}

appattic_qt6_cmake_ok() {
    local archdir p
    archdir="$(uname -m)"
    for p in "/usr/lib/${archdir}-linux-gnu/cmake/Qt6/Qt6Config.cmake" \
             "/usr/lib64/cmake/Qt6/Qt6Config.cmake" \
             "/usr/lib/cmake/Qt6/Qt6Config.cmake"; do
        [[ -f "$p" ]] && return 0
    done
    return 1
}

# Prepend every Qt 6 cmake dir found to CMAKE_PREFIX_PATH. The arch arg names
# the target and defaults to the host, so a build that overrides the arch it is
# packaging for resolves that arch's Qt; the two Debian/Ubuntu names stay as
# the cross-arch fallback an image build can reach, and /usr/lib64 and /usr/lib
# cover Fedora and Arch. The multiarch dir comes from the arch rather than
# being spelled out, so the list cannot fall behind the arch the rest of these
# scripts already read.
appattic_qt6_cmake_prefix_path() {
    local archdir="${1:-$(uname -m)}" d extra=""
    archdir="${archdir/amd64/x86_64}"
    archdir="${archdir/arm64/aarch64}"
    for d in "/usr/lib/${archdir}-linux-gnu/cmake" \
             /usr/lib/x86_64-linux-gnu/cmake \
             /usr/lib/aarch64-linux-gnu/cmake \
             /usr/lib64/cmake \
             /usr/lib/cmake; do
        [[ -d "$d/Qt6" ]] || continue
        if [[ -z "$extra" ]]; then
            extra="$d"
        else
            extra="$extra:$d"
        fi
    done
    if [[ -n "$extra" ]]; then
        if [[ -z "${CMAKE_PREFIX_PATH:-}" ]]; then
            export CMAKE_PREFIX_PATH="$extra"
        else
            export CMAKE_PREFIX_PATH="$extra:${CMAKE_PREFIX_PATH}"
        fi
    fi
}
