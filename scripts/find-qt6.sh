# shellcheck shell=bash
# Sourced by scripts/linux-deps.sh and scripts/linux-qt-link.sh. Requires ROOT.

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
