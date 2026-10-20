# shellcheck shell=bash
# Sourced by every script that runs `swift build`. Requires nothing.
#
# appattic_swift_build <config> [extra swift build args...> runs the one
# spelling of the Swift build this tree uses: resolution is disabled so the
# build never fetches what Package.resolved already pins, and the build root is
# mapped out of every path the compiler would otherwise bake into the binary.
#
# Map both Swift metadata and the Clang importer's paths; -Xcc alone leaves
# Swift source paths in the release binary.
# Clang module breadcrumbs reference build-only caches whose hashes vary by root.
appattic_swift_build() {
    local config="$1"; shift
    local root
    root="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
    swift build -c "$config" \
        -Xswiftc -file-prefix-map -Xswiftc "$root=." \
        -Xswiftc -debug-prefix-map -Xswiftc "$root=." \
        -Xswiftc -Xfrontend -Xswiftc -no-clang-module-breadcrumbs \
        -Xcc "-ffile-prefix-map=$root=." \
        -Xcc "-fdebug-prefix-map=$root=." \
        -Xcc "-fmacro-prefix-map=$root=." \
        --disable-automatic-resolution \
        "$@"
}