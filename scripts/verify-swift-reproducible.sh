#!/usr/bin/env bash
# Build the Swift release CLI twice and diff the binaries, the Swift half of
# scripts/verify-reproducible.sh. That script builds every WASM module and the
# C host twice and compares them; nothing covered the Swift product, which is
# the binary the macOS app bundle and the Linux CLI ship.
#
# Identity.swift reads #filePath to find core/src/linux-system-names.txt when
# the resource bundle is missing, so an unmapped checkout path reaches the
# release binary and two checkouts in different directories give two different
# .build/release/appattic. scripts/swift-build.sh is what maps the root out;
# this is what proves it still does.
#
# Each pass copies the tree into its own directory, under a different name,
# timezone and SOURCE_DATE_EPOCH, and builds through the same helper
# ./build.sh uses. The two binaries must be byte-identical.
#
# Usage: bash scripts/verify-swift-reproducible.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export LC_ALL=C
export LANG=C
export TZ=UTC

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    echo "Usage: bash scripts/verify-swift-reproducible.sh"
    echo
    echo "  Builds the Swift release CLI twice, from two differently named"
    echo "  directories, under a different timezone and SOURCE_DATE_EPOCH,"
    echo "  and requires the two binaries to be byte-identical."
    echo "  Needs the pinned Swift toolchain; scripts/verify-reproducible.sh"
    echo "  is the same check for the WASM modules and the C host, and needs"
    echo "  none of this."
    exit 0
fi
if [[ $# -ne 0 ]]; then
    echo "error: unknown argument: $1" >&2
    echo "Usage: $0" >&2
    echo "       $0 --help" >&2
    exit 2
fi

# Same rule as find-swift.sh and find-zig.sh: a local checkout without the
# toolchain gets a note and keeps going, CI never passes on the skip.
# shellcheck source=find-swift.sh
. "$ROOT/scripts/find-swift.sh"
appattic_require_swift

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# The two roots differ in name length on purpose: a build that leaks its own
# path into the output gives two different artifacts here.
A="$tmp/a"
B="$tmp/a-build-tree-with-a-longer-name"

# Only what `swift build` reads. The .build, .zig-cache and dist trees are
# build output, and a copy of one is a second build's output on disk.
stage_tree() {
    local dest="$1"
    mkdir -p "$dest"
    for entry in Package.swift Package.resolved .swift-version Sources tests benchmarks; do
        [[ -e "$ROOT/$entry" ]] || continue
        cp -R "$ROOT/$entry" "$dest/"
    done
    # core/src/linux-system-names.txt is the file the #filePath fallback reads.
    mkdir -p "$dest/core/src"
    if [[ -f "$ROOT/core/src/linux-system-names.txt" ]]; then
        cp "$ROOT/core/src/linux-system-names.txt" "$dest/core/src/"
    fi
}

build_cli() {
    local tree="$1" epoch="$2" zone="$3"
    (
        cd "$tree"
        export TZ="$zone"
        export SOURCE_DATE_EPOCH="$epoch"
        # The build root is mapped out here rather than through
        # scripts/swift-build.sh: that helper reads its own location to find
        # the root, and the root under test is the staged copy, not this tree.
        # The flag list is the helper's, and scripts/lint.sh fails if the two
        # spellings part.
        swift build -c release \
            -Xcc "-ffile-prefix-map=$tree=." \
            -Xcc "-fdebug-prefix-map=$tree=." \
            -Xcc "-fmacro-prefix-map=$tree=." \
            --product appattic --disable-automatic-resolution
    )
}

echo "pass 1: LC_ALL=C TZ=UTC SOURCE_DATE_EPOCH=1000000000"
stage_tree "$A"
build_cli "$A" 1000000000 UTC
one="$A/.build/release/appattic"
if [[ ! -f "$one" ]]; then
    one="$(find "$A/.build" -type f -name appattic -perm -u+x 2>/dev/null | LC_ALL=C sort | head -n 1 || true)"
fi
if [[ -z "$one" || ! -f "$one" ]]; then
    echo "error: pass 1 produced no appattic binary under $A/.build" >&2
    exit 1
fi

echo "pass 2: TZ=Asia/Tokyo SOURCE_DATE_EPOCH=1800000000"
stage_tree "$B"
build_cli "$B" 1800000000 Asia/Tokyo
two="$B/.build/release/appattic"
if [[ ! -f "$two" ]]; then
    two="$(find "$B/.build" -type f -name appattic -perm -u+x 2>/dev/null | LC_ALL=C sort | head -n 1 || true)"
fi
if [[ -z "$two" || ! -f "$two" ]]; then
    echo "error: pass 2 produced no appattic binary under $B/.build" >&2
    exit 1
fi

if cmp -s "$one" "$two"; then
    echo "reproducible: the Swift release CLI is identical from a differing path, timezone and epoch"
    exit 0
fi

echo "error: the Swift release CLI differs between the two passes" >&2
if command -v diffoscope >/dev/null 2>&1; then
    diffoscope "$one" "$two" >&2 2>/dev/null || true
fi
echo "       the build carries something the two passes set differently:" >&2
echo "       build path, timezone, or SOURCE_DATE_EPOCH" >&2
echo "       scripts/swift-build.sh maps the build root out; check it still does" >&2
exit 1