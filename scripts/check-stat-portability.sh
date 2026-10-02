#!/usr/bin/env bash
# Drive run.sh through the two stat spellings it has to survive.
#
# `stat` is the one command in this tree whose two spellings differ by libc
# rather than by kernel: GNU takes `-c %Y`, BSD and macOS take `-f %m`.
# run.sh reads a build's mtime to decide which of two binaries is newer, so
# reading it wrong does not fail loudly -- `stat` errors, the empty string
# compares as 0 against an initial best_mtime of 0, `>=` makes every
# candidate a tie, and the first one wins. That is how the pre-fix code
# launched the OLDER build on a host whose stat is not GNU's, with only a
# stray `stat: illegal option -- c` on stderr to say so.
#
# A grep over run.sh's source cannot see any of that: it can only prove the
# probe text is still there. This runs the real script instead, against a
# stand-in `stat` that behaves the way a BSD one does, and asserts which
# build got launched.
#
# No network, no build, no dependency beyond bash and a stub interpreter.
# Runs from scripts/lint.sh, so CI blocks on it.
# Usage: bash scripts/check-stat-portability.sh
set -euo pipefail

_script_dir="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$_script_dir/.." && pwd)"

case "${1:-}" in
    -h|--help)
        cat <<'EOF'
Usage: bash scripts/check-stat-portability.sh

  Runs run.sh against a GNU stat and against a stand-in BSD stat, and
  asserts that each time it launches the newer of two builds. No network,
  no build.
EOF
        exit 0
        ;;
    "")
        ;;
    *)
        echo "error: unknown argument: $1" >&2
        echo "Usage: $0" >&2
        echo "       $0 --help" >&2
        exit 2
        ;;
esac

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail=0
ok() { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; fail=1; }

# A stand-in for a BSD/macOS stat: it takes -f %m and rejects the GNU -c the
# pre-fix code reached for. The mtime comes from `find -printf %T@`, a GNU
# extension, and this stub stands in for the GNU-host toolchain the tree's own
# AppImage build already requires (`touch -h -d @epoch` in
# scripts/linux-appimage.sh), so the stub runs where the checks run. What is
# under test is run.sh's choice of spelling, not the stub's.
mkdir -p "$WORK/bsd-bin"
cat > "$WORK/bsd-bin/stat" <<'STUB'
#!/bin/sh
# BSD-style stat for the check: -f %m prints the mtime, -c is rejected.
bsd=no
for arg in "$@"; do
    case "$arg" in
        -c) echo "stat: illegal option -- c" >&2; exit 1 ;;
        -f) bsd=yes ;;
    esac
done
if [ "$bsd" = yes ]; then
    for target do :; done
    find "$target" -maxdepth 0 -printf '%T@\n' 2>/dev/null | cut -d. -f1
    exit 0
fi
echo "stat: unsupported" >&2
exit 1
STUB
chmod +x "$WORK/bsd-bin/stat"

# A tree with two builds: release is the newer one and says so when it runs.
# The label a script prints IS the answer, so the assertion reads directly.
make_tree() {
    local dir="$1"
    rm -rf "$dir"
    mkdir -p "$dir/.build/release" "$dir/.build/debug"
    printf '#!/bin/sh\necho "newer-release-build"\n' > "$dir/.build/release/appattic"
    printf '#!/bin/sh\necho "older-debug-build"\n' > "$dir/.build/debug/appattic"
    chmod +x "$dir/.build/release/appattic" "$dir/.build/debug/appattic"
    touch -d "@1500000000" "$dir/.build/release/appattic"
    touch -d "@1000000000" "$dir/.build/debug/appattic"
    cp "$ROOT/run.sh" "$dir/run.sh"
    chmod +x "$dir/run.sh"
}

# The stand-in has to behave, or the check passes for the wrong reason.
probe_out="$("$WORK/bsd-bin/stat" -f %m "$ROOT/run.sh" 2>/dev/null || true)"
probe_rc=$("$WORK/bsd-bin/stat" -c %Y "$ROOT/run.sh" >/dev/null 2>&1; echo $?)
if [[ "$probe_rc" -eq 0 ]]; then
    echo "error: the stand-in BSD stat accepted the GNU -c spelling, so it cannot" >&2
    echo "       stand in for a BSD stat and this check would prove nothing" >&2
    exit 1
fi
if [[ -z "$probe_out" || "$probe_out" -eq 0 ]]; then
    echo "error: the stand-in BSD stat printed no mtime, so a script reading it has" >&2
    echo "       nothing to compare and this check would prove nothing" >&2
    exit 1
fi

# The real assertion: one run per stat spelling, each must launch the newer build.
for spelling in gnu bsd; do
    make_tree "$WORK/tree"
    if [[ "$spelling" == gnu ]]; then
        out="$(cd "$WORK/tree" && ./run.sh report --all 2>/dev/null)"
    else
        out="$(cd "$WORK/tree" && PATH="$WORK/bsd-bin:$PATH" ./run.sh report --all 2>/dev/null)"
    fi
    if [[ "$out" == "newer-release-build" ]]; then
        ok "run.sh launched the newer build under a ${spelling} stat"
    else
        bad "run.sh launched '${out:-<nothing>}' under a ${spelling} stat; it must launch the newer build"
        echo "       run.sh reads a build's mtime to pick between .build/release and" >&2
        echo "       .build/debug. A stat it cannot read leaves the comparison empty," >&2
        echo "       which ties and launches whichever came first. See file_mtime in" >&2
        echo "       run.sh: it must probe for the spelling this host accepts." >&2
    fi
done

if [[ "$fail" -ne 0 ]]; then
    exit 1
fi
echo "stat portability: ok (run.sh reads mtimes under both GNU and BSD spellings)"
