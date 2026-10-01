# shellcheck shell=bash
# Sourced by every script that runs `swift build`. Requires nothing.
#
# appattic_swift_build <config> [extra swift build args...> runs the one
# spelling of the Swift build this tree uses: resolution is disabled so the
# build never fetches what Package.resolved already pins, and the build root is
# mapped out of every path the compiler would otherwise bake into the binary.
#
# Identity.swift reads #filePath to find core/src/linux-system-names.txt when
# the resource bundle is missing, so an absolute checkout path reaches the
# release binary: two checkouts in different directories gave two different
# .build/release/appattic. -Xcc -ffile-prefix-map (and its -fdebug- and
# -fmacro- siblings) rewrite every path of this root to ".", which is what
# core/build-flags.sh already does for the C and Zig builds. swiftc reports a
# driver flag it does not recognise as a hard error, so this needs a Swift
# toolchain; the callers are the scripts that require one anyway.
#
# Ceiling: -Xcc reaches the clang importer, so this maps the root out of
# Clang-imported declarations and debug info, not out of Swift metadata that
# swiftc stores itself. The regression test is build twice from two
# differently named directories and compare the binaries (see
# scripts/verify-swift-reproducible.sh); if it ever fails, the leftover is
# Swift metadata, and the upgrade path is a swift-driver flag that rewrites
# -file-prefix-map into every path form swiftc emits.
appattic_swift_build() {
    local config="$1"; shift
    local root
    root="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
    swift build -c "$config" \
        -Xcc "-ffile-prefix-map=$root=." \
        -Xcc "-fdebug-prefix-map=$root=." \
        -Xcc "-fmacro-prefix-map=$root=." \
        --disable-automatic-resolution \
        "$@"
}