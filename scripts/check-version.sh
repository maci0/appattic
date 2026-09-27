#!/usr/bin/env bash
# The release version is declared in three files that no tool keeps in sync.
# This is the one place that reads them, so a bump that misses one is a build
# failure instead of an artifact that reports the wrong version.
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

  Checks that the Swift, CMake, and AppStream version declarations agree,
  and that the newest AppStream release is the declared version.
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
cmake_version="$(extract "APPATTIC_VERSION" "$CMAKE" 's/^set(APPATTIC_VERSION "\([^"]*\)")$/\1/p')"
meta_version="$(extract "newest AppStream release" "$METAINFO" 's/.*<release version="\([^"]*\)".*/\1/p')"

bad=0
for pair in "appAtticVersion:$swift_version" "APPATTIC_VERSION:$cmake_version" \
    "AppStream release:$meta_version"; do
    if [[ "${pair#*:}" != "$swift_version" ]]; then
        echo "error: version mismatch: ${pair%%:*} is ${pair#*:}, appAtticVersion is $swift_version" >&2
        bad=1
    fi
done
if [[ "$bad" -ne 0 ]]; then
    echo "error: bump all three in the same commit: $UTIL, $CMAKE, $METAINFO" >&2
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
