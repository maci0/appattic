#!/usr/bin/env bash
# Run AppAtticScanTests. This is the script the CI jobs run, so a local run
# and a workflow run cannot drift apart.
# Usage: bash scripts/test.sh [<filter>]
#   (no filter)  AppAtticScanTests
#   <filter>     one class or one test, e.g. DiskSizeTests
#                 DiskSizeTests/testDirectorySize
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
               DiskSizeTests/testDirectorySize

The CI jobs call this script, so a green run here is the same run there.
It adds --disable-automatic-resolution, APPATTIC_NO_MAC_UI=1 on macOS, and a
check that the toolchain is the one .swift-version declares. `swift test`
builds every target in the package, and AppAtticUI needs a Swift 6 compiler
while .swift-version pins 5.10.1, so a bare `swift test` cannot build on the
pinned toolchain.
EOF
        exit 0
        ;;
    "") FILTER=AppAtticScanTests ;;
    -*) 
        echo "error: unknown argument: $1" >&2
        echo "Usage: $0 [<filter>]" >&2
        exit 2
        ;;
    *) FILTER="$1" ;;
esac
if [[ $# -gt 1 ]]; then
    echo "error: expected at most one filter, got $#" >&2
    echo "Usage: $0 [<filter>]" >&2
    exit 2
fi

# shellcheck source=find-swift.sh
. "$ROOT/scripts/find-swift.sh"
appattic_require_swift

if [[ "$(uname -s)" == "Darwin" ]]; then
    export APPATTIC_NO_MAC_UI=1
fi

exec swift test --filter "$FILTER" --disable-automatic-resolution
