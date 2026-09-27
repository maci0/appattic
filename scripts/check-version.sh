#!/usr/bin/env bash
# The release version has one declaration (appAtticVersion in Version.swift) and
# the packaging copies that have to keep in step: the newest AppStream release,
# the macOS bundle Info.plist, and the appattic-qt man page. CMakeLists.txt
# reads the declaration, so this is the place that checks the copies and the
# derivation.
# Usage: bash scripts/check-version.sh [--tag TAG]
#   prints the declared version on stdout
#   --tag  also requires TAG (a v* ref name or a bare version) to match it
set -euo pipefail

_script_dir="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$_script_dir/.." && pwd)"

VERSION_SRC="$ROOT/Sources/AppAtticScan/Version.swift"
CMAKE="$ROOT/ui/linux-qt/CMakeLists.txt"
METAINFO="$ROOT/packaging/org.appattic.AppAttic.metainfo.xml"
PLIST="$ROOT/packaging/Info.plist"
MANPAGE="$ROOT/packaging/appattic-qt.1"

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

  Checks that the AppStream release, the macOS Info.plist, and the
  appattic-qt man page match appAtticVersion, and that CMakeLists.txt still
  derives its version from Version.swift.
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

plist_string() {
    # $1: label, $2: key, $3: file. The value is the <string> on the line after
    # the <key>, which is how a plist written one key per line spells a string.
    local out
    out="$(sed -n "/<key>$2<\\/key>/{n;s/.*<string>\\([^<]*\\)<\\/string>.*/\\1/p}" "$3" 2>/dev/null | head -n 1)"
    if [[ -z "$out" ]]; then
        echo "error: no $2 string in $1 ($3)" >&2
        exit 1
    fi
    printf '%s\n' "$out"
}

swift_version="$(extract "appAtticVersion" "$VERSION_SRC" 's/^public let appAtticVersion = "\([^"]*\)"$/\1/p')"
# The newest release by version, not by position: an entry appended out of
# order must not leave an older one looking like the release of record.
meta_version="$(sed -n 's/.*<release version="\([^"]*\)".*/\1/p' "$METAINFO" 2>/dev/null | sort -V | tail -n 1)"
if [[ -z "$meta_version" ]]; then
    echo "error: no <release> found in the AppStream metainfo ($METAINFO)" >&2
    exit 1
fi
plist_short="$(plist_string "Info.plist" CFBundleShortVersionString "$PLIST")"
plist_build="$(plist_string "Info.plist" CFBundleVersion "$PLIST")"
plist_version="$plist_short"
man_version="$(extract "man page" "$MANPAGE" 's/^\.TH [^ ]* 1 "[^"]*" "[^ ]* \([^"]*\)" .*/\1/p')"

# CMakeLists.txt has no version of its own: it reads appAtticVersion out of
# $VERSION_SRC with string(REGEX MATCH). There is no copy of it to compare, so
# check that the derivation is still there and that no literal crept back in.
if grep -qE '^[[:space:]]*set\(APPATTIC_VERSION[[:space:]]+"[0-9]' "$CMAKE"; then
    echo "error: $CMAKE declares APPATTIC_VERSION literally; it must read appAtticVersion from $VERSION_SRC" >&2
    exit 1
fi
if ! grep -qF 'public let appAtticVersion' "$CMAKE" \
    || ! grep -qF 'CMAKE_MATCH_1' "$CMAKE"; then
    echo "error: $CMAKE no longer derives APPATTIC_VERSION from $VERSION_SRC" >&2
    echo "       keep the appAtticVersion regex and the CMAKE_MATCH_1 it reads" >&2
    exit 1
fi

# One declaration, three copies to keep in step. A stale copy ships a package
# that reports the wrong version, so each one is compared here.
if [[ "$meta_version" != "$swift_version" ]]; then
    echo "error: version mismatch: AppStream release is $meta_version, appAtticVersion is $swift_version" >&2
    echo "error: bump both in the same commit: $VERSION_SRC, $METAINFO" >&2
    exit 1
fi
if [[ "$plist_version" != "$swift_version" ]]; then
    echo "error: version mismatch: CFBundleShortVersionString is $plist_version, appAtticVersion is $swift_version" >&2
    echo "error: bump both in the same commit: $VERSION_SRC, $PLIST" >&2
    exit 1
fi
if [[ "$man_version" != "$swift_version" ]]; then
    echo "error: version mismatch: appattic-qt.1 header is $man_version, appAtticVersion is $swift_version" >&2
    echo "error: bump both in the same commit: $VERSION_SRC, $MANPAGE" >&2
    exit 1
fi

# build.sh copies this plist into AppAttic.app unchanged, so its short version
# is what Finder and macOS read, not appAtticVersion.
if [[ "$plist_short" != "$swift_version" ]]; then
    echo "error: version mismatch: $PLIST CFBundleShortVersionString is $plist_short, appAtticVersion is $swift_version" >&2
    echo "error: bump all three in the same commit: $VERSION_SRC, $METAINFO, $PLIST" >&2
    exit 1
fi

# The build number is the other half of a bundle version: macOS orders updates
# by (short version, build number) and refuses a reinstall at or below the one
# it already has, so it goes up on every release even for a patch.
if [[ ! "$plist_build" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: $PLIST CFBundleVersion is '$plist_build', which is not a build number" >&2
    echo "error: it is a positive integer that rises every release, not the semver version" >&2
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
