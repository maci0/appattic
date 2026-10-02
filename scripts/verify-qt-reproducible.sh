#!/usr/bin/env bash
# Build the Qt 6 release binary twice and diff it, the third of the tree's
# three double-build gates. The other two cover the artifacts the release ships
# beside it, and neither reaches this one:
#
#   scripts/verify-reproducible.sh        every WASM module and the C host
#   scripts/verify-swift-reproducible.sh  the Swift release CLI
#
# appattic-qt is the binary scripts/linux-appimage.sh packs into the AppImage
# and CMakeLists.txt installs on a plain `cmake --install`, so it is the
# primary shipped Linux artifact and the one a rebuild most needs to match.
# Nothing compared two of its builds: a prefix map dropped from
# ui/linux-qt/CMakeLists.txt, a Qt moc/rcc output that picks up the build
# directory, or an automoc ordering change would all have shipped green and
# made two builds of one source two different artifacts.
#
# The mapping already in CMakeLists.txt maps APPATTIC_ROOT and CMAKE_BINARY_DIR
# out of every path the compiler would bake in. This is what proves it still
# does, the way the other two prove theirs.
#
# Each pass copies the tree into its own directory, under a different name,
# timezone and SOURCE_DATE_EPOCH, configures and builds Release exactly as
# scripts/linux-appimage.sh does, and the two binaries must be byte-identical.
#
# Usage: bash scripts/verify-qt-reproducible.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export LC_ALL=C
export LANG=C
export TZ=UTC

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    echo "Usage: bash scripts/verify-qt-reproducible.sh"
    echo
    echo "  Builds the Qt 6 release binary twice, from two differently named"
    echo "  directories, under a different timezone and SOURCE_DATE_EPOCH,"
    echo "  and requires the two binaries to be byte-identical."
    echo "  Needs Linux, Qt 6, cmake and the Wasmtime C API"
    echo "  (scripts/linux-deps.sh --install, --install-wasmtime);"
    echo "  scripts/verify-reproducible.sh needs none of the Qt half and is"
    echo "  the same check for the WASM modules and the C host."
    exit 0
fi
if [[ $# -ne 0 ]]; then
    echo "error: unknown argument: $1" >&2
    echo "Usage: $0" >&2
    echo "       $0 --help" >&2
    exit 2
fi

if [[ "$(uname -s)" != Linux ]]; then
    echo "error: the Qt 6 window is a Linux build; run this on Linux" >&2
    echo "       scripts/verify-reproducible.sh covers the WASM and C artifacts" >&2
    echo "       on any host, and is the check to run elsewhere." >&2
    exit 3
fi

# Same rule as find-zig.sh: a host without the toolchain gets a named skip, a
# CI run never passes on it. The `CI` check is what turns a local skip into a
# CI failure, the same way appattic_require_zig does.
command -v cmake >/dev/null 2>&1 || {
    echo "error: cmake missing" >&2
    echo "       bash scripts/linux-deps.sh --install" >&2
    exit 1
}

# shellcheck source=find-qt6.sh
. "$ROOT/scripts/find-qt6.sh"
if ! appattic_qt6_pkg_config_ok && ! appattic_qt6_cmake_ok; then
    echo "note: Qt 6 not found; skipping the Qt release double-build" >&2
    if [[ "${CI:-}" == "true" ]]; then
        echo "error: Qt 6 missing in CI; run: bash scripts/linux-deps.sh --install" >&2
        exit 1
    fi
    exit 0
fi

# shellcheck source=find-wasmtime.sh
. "$ROOT/scripts/find-wasmtime.sh"
if ! appattic_find_wasmtime; then
    echo "note: wasmtime C API not found; skipping the Qt release double-build" >&2
    if [[ "${CI:-}" == "true" ]]; then
        echo "error: wasmtime C API missing in CI; run:" >&2
        echo "       bash scripts/linux-deps.sh --install-wasmtime" >&2
        exit 1
    fi
    exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# The two roots differ in name length on purpose: a build that leaks its own
# path into the output gives two different artifacts here. Same shape, and the
# same reason, as the two gates above.
A="$tmp/a"
B="$tmp/a-build-tree-with-a-longer-name"

# Only what the configure and the build read. .build, core/out, dist and the
# ui/linux-qt build trees are build output, and a copy of one is a second
# build's output on disk.
stage_tree() {
    local dest="$1"
    mkdir -p "$dest"
    # `cp -R` of ui would carry whatever the local link left in
    # ui/linux-qt/build, which is a build tree this one is about to replace
    # and a source of a second build's objects.
    mkdir -p "$dest/ui/linux-qt"
    for f in "$ROOT"/ui/linux-qt/*; do
        case "$(basename "$f")" in
            build|build-release) continue ;;
            # The two build trees and nothing else: every other entry under
            # ui/linux-qt is a source the configure reads, and dropping one
            # because a new case was forgotten would fail the configure rather
            # than skip a file quietly.
            *) cp -R "$f" "$dest/ui/linux-qt/" ;;
        esac
    done
    # packaging/org.appattic.AppAttic.desktop and appattic.svg are installed by
    # the rules this configure reads, and the fonts/ directory is compiled in
    # by appattic.qrc.
    cp -R "$ROOT/packaging" "$dest/"
    # core/host, because the target compiles embed.c and hostexec.c from it.
    # core/src is not needed to compile, but core/out is what the install rules
    # copy and the AppImage bundles, and an empty one is the honest starting
    # state: the modules are build output, and scripts/verify-reproducible.sh
    # is the gate that proves two of them match.
    mkdir -p "$dest/core/host"
    cp -R "$ROOT/core/host/." "$dest/core/host/"
    mkdir -p "$dest/core/src" "$dest/core/out"
    # Sources/AppAtticScan/Version.swift is a hard configure-time input:
    # CMakeLists.txt reads appAtticVersion out of it and FATAL_ERRORs without
    # it, so a staged tree that left Sources behind fails to configure rather
    # than diffing two binaries.
    mkdir -p "$dest/Sources/AppAtticScan"
    cp "$ROOT/Sources/AppAtticScan/Version.swift" "$dest/Sources/AppAtticScan/"
}

build_qt() {
    local tree="$1" epoch="$2" zone="$3"
    (
        cd "$tree"
        export TZ="$zone"
        export SOURCE_DATE_EPOCH="$epoch"
        # The same configure scripts/linux-appimage.sh runs, minus the WASM
        # rebuild: the modules are build output this check compares elsewhere
        # (scripts/verify-reproducible.sh) and are not read by the compile.
        # Release, because that is what the AppImage packs and what a
        # `cmake --install --strip` ships; a debug build has assertions and no
        # optimization and is not the artifact.
        cmake -S "$tree/ui/linux-qt" -B "$tree/_qt" -G Ninja \
            -DCMAKE_BUILD_TYPE=Release \
            -DWASMTIME_ROOT="$WASMTIME_DIR" \
            >"$tree/configure.log" 2>&1 || {
                echo "error: cmake configure failed" >&2
                cat "$tree/configure.log" >&2
                exit 1
            }
        cmake --build "$tree/_qt" --target appattic-qt --parallel \
            >"$tree/build.log" 2>&1 || {
                echo "error: cmake build failed" >&2
                cat "$tree/build.log" >&2
                exit 1
            }
    )
}

echo "pass 1: LC_ALL=C TZ=UTC SOURCE_DATE_EPOCH=1000000000"
stage_tree "$A"
build_qt "$A" 1000000000 UTC
one="$A/_qt/appattic-qt"
if [[ ! -f "$one" ]]; then
    echo "error: pass 1 produced no appattic-qt under $A/_qt" >&2
    exit 1
fi

echo "pass 2: TZ=Asia/Tokyo SOURCE_DATE_EPOCH=1800000000"
stage_tree "$B"
build_qt "$B" 1800000000 Asia/Tokyo
two="$B/_qt/appattic-qt"
if [[ ! -f "$two" ]]; then
    echo "error: pass 2 produced no appattic-qt under $B/_qt" >&2
    exit 1
fi

if cmp -s "$one" "$two"; then
    echo "reproducible: the Qt 6 release binary is identical from a differing path, timezone and epoch"
    exit 0
fi

echo "error: the Qt 6 release binary differs between the two passes" >&2
if command -v diffoscope >/dev/null 2>&1; then
    diffoscope "$one" "$two" >&2 2>/dev/null || true
fi
echo "       the build carries something the two passes set differently:" >&2
echo "       build path, timezone, or SOURCE_DATE_EPOCH" >&2
echo "       ui/linux-qt/CMakeLists.txt maps APPATTIC_ROOT and CMAKE_BINARY_DIR" >&2
echo "       out of the binary; check it still does, and that a moc/rcc" >&2
echo "       generated file is not carrying a path of its own" >&2
exit 1
