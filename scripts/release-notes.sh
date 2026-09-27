#!/usr/bin/env bash
# The AppStream <description> of one release, and nothing else.
#
# It is the only release note a user is given: it ships inside the package, it
# is the Flathub and GNOME Software text, and check-version.sh fails a release
# that carries a version without one. The GitHub release page is the other
# place a user reads before downloading, so it gets the same text rather than
# a generated list of commit subjects, which is a second changelog that says
# nothing about what a caller has to change.
#
# Usage: bash scripts/release-notes.sh [VERSION]
#   VERSION defaults to the declared version, read through check-version.sh.
#   Exits 1 when that release has no <description> to print.
set -euo pipefail

_script_dir="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$_script_dir/.." && pwd)"

METAINFO="$ROOT/packaging/org.appattic.AppAttic.metainfo.xml"

if [[ ! -f "$METAINFO" ]]; then
    echo "error: no AppStream metainfo at $METAINFO" >&2
    exit 1
fi

if [[ $# -gt 1 ]]; then
    echo "error: expected at most one version" >&2
    echo "Usage: bash scripts/release-notes.sh [VERSION]" >&2
    exit 2
fi

# A flag has to say so, not read as a version name: `--help` used to fall
# through and report "no <description> for release --help", which is exit 1
# and a message about a release nobody cut.
case "${1:-}" in
    -h|--help)
        cat <<'EOF'
Usage: bash scripts/release-notes.sh [VERSION]

  (no version)  the notes for the declared version, read through
                check-version.sh
  VERSION       the notes for that release (a v* ref name or a bare version)

Prints the AppStream <description> of the release and nothing else. Exits 1
when that release carries no notes, since a release with no note is silent.
EOF
        exit 0
        ;;
    -*)
        echo "error: unknown argument: $1" >&2
        echo "Usage: bash scripts/release-notes.sh [VERSION]" >&2
        echo "       bash scripts/release-notes.sh --help" >&2
        exit 2
        ;;
esac

version="${1:-$(bash "$_script_dir/check-version.sh")}"
version="${version#v}"

# The body between the <description> and </description> of the matching
# <release>, unindented by the common leading whitespace. A <p> spanning
# several lines stays as it is: only the first line of each carries the
# indent, so a line-based dedent would strip the paragraph's own markup
# differently from its text.
notes="$(awk -v want="$version" '
    index($0, "<release ") { inside = ($0 ~ ("version=\"" want "\"")) }
    inside && index($0, "<description>") { capturing = 1; next }
    capturing {
        line = $0
        sub(/^[ \t]+/, "", line)
        sub(/[ \t]+$/, "", line)
        if (line == "</description>") { capturing = 0; exit }
        print line
    }
' "$METAINFO")"

if [[ -z "$notes" ]]; then
    echo "error: no <description> for release $version in $METAINFO" >&2
    echo "       a release with no note is a silent release" >&2
    exit 1
fi

printf '%s\n' "$notes"
