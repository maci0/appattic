#!/usr/bin/env bash
# Run AppAtticScanTests. This is the script the CI jobs run, so a local run
# and a workflow run cannot drift apart.
# Usage: bash scripts/test.sh [<filter>]
#   (no filter)  AppAtticScanTests
#   <filter>     one class or one test, e.g. DiskSizeTests
#                 DiskSizeTests/testParseDuKBRequiresLeadingInteger
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export LC_ALL=C
export LANG=C
export TZ=UTC

case "${1:-}" in
    -h|--help)
        cat <<'EOF'
Usage: bash scripts/test.sh [<filter>]

  (no filter)  every AppAtticScanTests test
  <filter>     one class or one test, e.g. DiskSizeTests
               DiskSizeTests/testParseDuKBRequiresLeadingInteger

The CI jobs call this script, so a green run here is the same run there.
It adds --disable-automatic-resolution, APPATTIC_NO_MAC_UI=1 on macOS, and a
check that the toolchain is the one .swift-version declares. `swift test`
builds every target in the package, and AppAtticUI needs a Swift 6 compiler
while .swift-version pins 5.10.1, so a bare `swift test` cannot build on the
pinned toolchain.

A filter that matches no test fails rather than reporting a pass: swift test
exits 0 having run zero tests, and core/build.sh refuses the same condition
for zig test, so a renamed test class is a red run and not a green one.
EOF
        exit 0
        ;;
    "") FILTER=AppAtticScanTests ;;
    -*) 
        echo "error: unknown argument: $1" >&2
        echo "Usage: $0 [<filter>]" >&2
        echo "       $0 --help" >&2
        exit 2
        ;;
    *) FILTER="$1" ;;
esac
if [[ $# -gt 1 ]]; then
    echo "error: expected at most one filter, got $#" >&2
    echo "Usage: $0 [<filter>]" >&2
    echo "       $0 --help" >&2
    exit 2
fi

# shellcheck source=find-swift.sh
. "$ROOT/scripts/find-swift.sh"
appattic_require_swift

if [[ "$(uname -s)" == "Darwin" ]]; then
    export APPATTIC_NO_MAC_UI=1
fi

# A filter that matches nothing is the silent-green failure this loop must not
# have, and `swift test` does not catch it: XCTest exits 0 having run zero
# tests, so a typo in the filter reports a pass. The Zig loop already refuses
# this for `zig test` (core/build.sh, its `--test-filter` block), and the two
# single-test loops should behave the same. core/build.sh fails on the same
# condition, so the rule is not new to the tree, only missing from this script.
#
# The output still streams: a filter that ran nothing is only detectable after
# the run, and the contributor reading a single test's progress wants to see it
# as it happens. tee writes it through and leaves a copy to match against, and
# the pipeline's own status is the test run's, not tee's.
log="$(mktemp)"
trap 'rm -f "$log"' EXIT
set +e
swift test --filter "$FILTER" --disable-automatic-resolution 2>&1 | tee "$log"
rc="${PIPESTATUS[0]}"
set -e
if [[ "$rc" -ne 0 ]]; then
    exit "$rc"
fi
# XCTest prints "Executed N test(s), ..." once per suite, the outermost last.
# The largest N any line reports is the whole run's count; a filter matching
# nothing reports none at all, or a bare zero.
executed="$(grep -oE 'Executed [0-9]+ tests?' "$log" | grep -oE '[0-9]+' | sort -n | tail -1)"
if [[ -z "$executed" || "$executed" -eq 0 ]]; then
    echo "error: no test matched '$FILTER'; nothing ran, and that is not a pass" >&2
    echo "note: the filter is a class, or Class/testName. For example:" >&2
    echo "      DiskSizeTests" >&2
    echo "      DiskSizeTests/testParseDuKBRequiresLeadingInteger" >&2
    echo "      (find the name: rg -n 'func test' tests/AppAtticScanTests/)" >&2
    exit 1
fi
