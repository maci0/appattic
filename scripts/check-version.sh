#!/usr/bin/env bash
# The release version is declared in Util.swift and the AppStream metainfo,
# which no tool keeps in sync. The Qt build reads it out of Util.swift at
# configure time, so the declaration is one. This is the one place that reads
# them, so a bump that misses one is a build failure instead of an artifact
# that reports the wrong version.
# Usage: bash scripts/check-version.sh [--tag TAG]
#   prints the declared version on stdout
#   --tag  also requires TAG (a v* ref name or a bare version) to match it
set -euo pipefail

_script_dir="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$_script_dir/.." && pwd)"

UTIL="$ROOT/Sources/AppAtticScan/Util.swift"
CMAKE="$ROOT/ui/linux-qt/CMakeLists.txt"
METAINFO="$ROOT/packaging/org.appattic.AppAttic.metainfo.xml"

TAG=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --tag)
            if [[ $# -lt 2 ]]; then
                echo "error: --tag needs a value" >&2
                exit 2
            fi
            TAG="$2"
            shift 2
            ;;
        -h|--help)
            cat <<'EOF'
Usage: bash scripts/check-version.sh [--tag TAG]

  Checks that the AppStream release is the declared Swift version, and that
  the Qt build still derives its version from the Swift declaration.
  Prints the declared version. With --tag, the tag must match it too.
EOF
            exit 0
            ;;
        *)
            echo "error: unknown argument: $1" >&2
            echo "Usage: bash scripts/check-version.sh [--tag TAG]" >&2
            exit 2
            ;;
    esac
done

extract() {
    # $1: label, $2: file, $3: sed program
    local out
    out="$(sed -n "$3" "$2" 2>/dev/null | head -n 1)"
    if [[ ! "$out" =~ ^[0-9]+(\.[0-9]+)*([A-Za-z0-9.-]*)$ ]]; then
        echo "error: no version found in $1 ($2)" >&2
        exit 1
    fi
    printf '%s\n' "$out"
}

swift_version="$(extract "appAtticVersion" "$UTIL" 's/^public let appAtticVersion = "\([^"]*\)"$/\1/p')"
meta_version="$(extract "newest AppStream release" "$METAINFO" 's/.*<release version="\([^"]*\)".*/\1/p')"

# CMake holds no version literal: ui/linux-qt/CMakeLists.txt reads
# appAtticVersion out of Util.swift at configure time. Check that derivation
# is intact, so a reworded regex fails the gate instead of quietly building a
# Qt binary with no version.
if ! grep -qF 'public let appAtticVersion = ' "$CMAKE" \
    || ! grep -qF 'CMAKE_MATCH_1' "$CMAKE"; then
    echo "error: $CMAKE no longer derives APPATTIC_VERSION from $UTIL" >&2
    echo "       keep the appAtticVersion regex and the CMAKE_MATCH_1 it reads" >&2
    exit 1
fi

if [[ "$meta_version" != "$swift_version" ]]; then
    echo "error: version mismatch: AppStream release is $meta_version, appAtticVersion is $swift_version" >&2
    echo "error: bump both in the same commit: $UTIL, $METAINFO" >&2
    exit 1
fi

if [[ -n "$TAG" ]]; then
    tag_version="${TAG#v}"
    if [[ "$tag_version" != "$swift_version" ]]; then
        echo "error: tag $TAG does not match the declared version $swift_version" >&2
        echo "       bump the version, or retag, before publishing" >&2
        exit 1
    fi
fi

printf '%s\n' "$swift_version"
