#!/usr/bin/env bash
# The release version has one declaration (appAtticVersion in Version.swift) and
# the packaging copies that have to keep in step: the newest AppStream release,
# the macOS bundle Info.plist, and the appattic-qt man page. CMakeLists.txt
# reads the declaration, so this is the place that checks the copies, the
# derivation, that the release has notes a user can read, and that the version
# was not already released from another commit.
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
  appattic-qt man page match appAtticVersion, that the AppStream release
  carries a date and a <description>, that CMakeLists.txt still derives
  its version from Version.swift, and that the declared version is not a
  release already published from a different commit.
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

version_gt() {
    # $1 sorts after $2, comparing each dot-separated field numerically with
    # the missing fields read as 0. Not `sort -V`: that is GNU coreutils only
    # and BSD sort (macOS) rejects it, and this script runs on both.
    local -a a=() b=()
    IFS='.' read -r -a a <<< "$1"
    IFS='.' read -r -a b <<< "$2"
    local i n="${#a[@]}"
    if (( ${#b[@]} > n )); then n=${#b[@]}; fi
    for (( i = 0; i < n; i++ )); do
        local x="${a[i]:-0}" y="${b[i]:-0}"
        x="${x%%[^0-9]*}"; x="${x:-0}"
        y="${y%%[^0-9]*}"; y="${y:-0}"
        (( 10#$x > 10#$y )) && return 0
        (( 10#$x < 10#$y )) && return 1
    done
    return 1
}

newest_version() {
    # Highest version on stdin, empty input gives empty output.
    local best="" line
    while IFS= read -r line; do
        if [[ -n "$line" ]] && { [[ -z "$best" ]] || version_gt "$line" "$best"; }; then
            best="$line"
        fi
    done
    printf '%s\n' "$best"
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
meta_version="$(sed -n 's/.*<release version="\([^"]*\)".*/\1/p' "$METAINFO" 2>/dev/null | newest_version)"
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
# The AppStream <description> is the only release note a user gets, so a
# release that carries a version and no note is a silent release: the tag
# builds, the store lists a version, and nothing says what changed. The date is
# in the same check because AppStream rejects a <release> without one, so a
# missing date is a broken entry rather than a style choice.
release_defects="$(awk -v want="$meta_version" '
    function report() {
        if (!dated) print "no date attribute"
        if (!described) print "no <description>"
    }
    index($0, "<release ") {
        inside = ($0 ~ ("version=\"" want "\""))
        dated = 0
        described = 0
        closed = 0
    }
    inside && $0 ~ /date="/ { dated = 1 }
    inside && /<description>/ { described = 1 }
    inside && /<\/release>/ { closed = 1; report(); inside = 0 }
    # A self-closing <release version="..."/> never reaches </release>.
    END { if (inside && !closed) report() }
' "$METAINFO" 2>/dev/null | sort -u | tr '\n' ' ')"
if [[ -n "$release_defects" ]]; then
    echo "error: the AppStream <release> for $meta_version in $METAINFO is $release_defects" >&2
    echo "       every release needs a date and a consumer-facing <description>:" >&2
    echo "       it is the only release note the package ships" >&2
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

# A published version is immutable: one number is one set of bytes, so the same
# version can never ship a second, different build. When the declared version is
# already tagged, that tag has to be the commit under this tree; anything else
# means the release is re-using a number users already have installed. Matching
# the tag says nothing (that is a normal release build), pointing elsewhere is
# the failure. The tags have to be in the clone for this to mean anything, which
# is why the release workflow checks out the full history; a source tarball with
# no tags is not a repository and is left alone.
if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    published_tag=""
    for candidate in "v$swift_version" "$swift_version"; do
        if git -C "$ROOT" rev-parse -q --verify "refs/tags/$candidate" >/dev/null 2>&1; then
            published_tag="$candidate"
            break
        fi
    done
    if [[ -n "$published_tag" ]]; then
        tagged_commit="$(git -C "$ROOT" rev-list -n1 "$published_tag" 2>/dev/null || true)"
        head_commit="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"
        if [[ -n "$tagged_commit" && -n "$head_commit" && "$tagged_commit" != "$head_commit" ]]; then
            echo "error: $published_tag is a published release, and it points at" >&2
            echo "       ${tagged_commit:0:12}, not this commit (${head_commit:0:12})" >&2
            echo "       a released version is immutable: bump appAtticVersion and its copies," >&2
            echo "       or check out $published_tag to build the release that tag names" >&2
            exit 1
        fi
    fi
fi

printf '%s\n' "$swift_version"
