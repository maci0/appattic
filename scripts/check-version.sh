#!/usr/bin/env bash
# The release version has one declaration (appAtticVersion in Util.swift) and
# one copy to keep in step (the newest AppStream release). CMakeLists.txt reads
# the declaration, so this is the place that checks the copy and the derivation.
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

  Checks that the newest AppStream release matches appAtticVersion, and that
  CMakeLists.txt still derives its version from Util.swift.
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

# CMakeLists.txt has no version of its own: it reads appAtticVersion out of
# $UTIL with string(REGEX MATCH). There is no third declaration to compare, so
# check that the derivation is still there and that no literal crept back in.
if grep -qE '^[[:space:]]*set\(APPATTIC_VERSION[[:space:]]+"[0-9]' "$CMAKE"; then
    echo "error: $CMAKE declares APPATTIC_VERSION literally; it must read appAtticVersion from $UTIL" >&2
    exit 1
fi
if ! grep -qF 'public let appAtticVersion' "$CMAKE" \
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
