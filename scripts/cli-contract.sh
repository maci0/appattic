#!/usr/bin/env bash
# Assert the built CLI's contract: exit codes, stdout vs stderr, and that a
# result a script needs is on stdout. This is the check that catches a stream
# mix-up or a wrong exit code — the failures a script consuming this CLI cannot
# see until something downstream breaks.
#
# Hermetic and safe: it runs against a temporary HOME and XDG_* tree and a
# temporary directory for `disk`, so the real account's settings and scan cache
# are never read, written, or erased (`erase` here can only resolve a snapshot
# path inside that temp tree, where there is nothing to remove). It never runs
# `update`, which executes a real package script, nor a full scan command
# (report/leftovers/stale/outdated/packages, which walk the filesystem); every
# case here answers in well under a second.
#
# Usage: bash scripts/cli-contract.sh [appattic-binary]
# -euo pipefail, the spelling every other runnable script in this tree carries.
# The CLI under test exits 2 on a usage error and 1 on a failed disk root, so
# `set -e` would abort the run on the first case this script exists to assert;
# the deliberate nonzero exits below are captured and checked by hand.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# --help has to answer before the binary lookup below, or asking how to run
# this prints "no built appattic CLI found" instead: the question is about the
# script, and answering it needs nothing built. Same spelling every other
# script here takes.
for arg in "$@"; do
    case "$arg" in
        -h|--help)
            cat <<'EOF'
Usage: bash scripts/cli-contract.sh [appattic-binary]

  (no binary)     check .build/debug/appattic, else .build/release/appattic
  <binary>        check that one instead

Asserts the built CLI's exit codes and which stream each result lands on.
Hermetic: it runs against a temporary HOME and XDG_* tree, never runs
`update`, and never runs a command that walks the filesystem.
scripts/check.sh builds the CLI and runs this.
EOF
            exit 0
            ;;
        -*)
            echo "error: unknown argument: $arg" >&2
            echo "Usage: $0 [appattic-binary]" >&2
            echo "       $0 --help" >&2
            exit 2
            ;;
        # A bare path names the binary.
        *) ;;
    esac
done

# Only the first argument names the binary, and the loop above scans the rest
# for -h. A second path would be dropped, so a mistyped pair checks the binary
# the first path named instead of failing.
if [[ $# -gt 1 ]]; then
    echo "error: unexpected argument: $2" >&2
    echo "Usage: $0 [appattic-binary]" >&2
    echo "       $0 --help" >&2
    exit 2
fi

BIN="${1:-$ROOT/.build/debug/appattic}"
if [[ ! -x "$BIN" ]]; then
    BIN="$ROOT/.build/release/appattic"
fi
if [[ ! -x "$BIN" ]]; then
    echo "error: no built appattic CLI found (run 'bash scripts/check.sh' or 'swift build -c debug --product appattic')" >&2
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
export XDG_DATA_HOME="$TMP/xdg-data"
export XDG_CONFIG_HOME="$TMP/xdg-config"
export XDG_CACHE_HOME="$TMP/xdg-cache"
export LC_ALL=C
export LANG=C
export TZ=UTC
# Color off so the piped bytes are exactly what is on the stream.
export TERM=dumb
unset COLORFGBG NO_COLOR 2>/dev/null || true

fails=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fails=$((fails + 1)); }

# run <expected-exit> <name> <args...>: run the CLI, capture stdout and stderr
# separately, and assert the exit code. Sets OUT and ERR.
run() {
    local want="$1" name="$2" got; shift 2
    # `set +e` around the one command whose nonzero exit is the thing under
    # test: with -e on, the first `run 2 ...` aborts the script instead of
    # failing a case, and the report names a line rather than a contract.
    set +e
    OUT="$("$BIN" "$@" 2>"$TMP/stderr")"; got=$?
    set -e
    ERR="$(cat "$TMP/stderr")"
    if [[ "$got" -eq "$want" ]]; then
        ok "$name (exit $got)"
    else
        bad "$name: exit $got, want $want"
    fi
}

# want_out <label> <substring>: OUT contains <substring>.
want_out() { if [[ "$OUT" == *"$2"* ]]; then ok "$1"; else bad "$1 (stdout: ${OUT:0:120})"; fi; }
# want_err <label> <substring>: ERR contains <substring>.
want_err() { if [[ "$ERR" == *"$2"* ]]; then ok "$1"; else bad "$1 (stderr: ${ERR:0:120})"; fi; }

# --- --help and --version answer a question on stdout and exit 0 -----------
run 0 "--help" --help
want_out "--help prints usage on stdout" "usage:"
if [[ -z "$ERR" ]]; then ok "--help is quiet on stderr"; else bad "--help wrote to stderr: $ERR"; fi

run 0 "--version" --version
want_out "--version prints on stdout" "appattic "

run 0 "help word" help
want_out "'help' word prints usage on stdout" "usage:"

# --- a usage error exits 2, names the token, and stays off stdout ----------
run 2 "unknown option" --nope
want_err "unknown option names the token" "unknown option: --nope"
want_err "usage error prints the hint" "Try 'appattic --help'"
if [[ -z "$OUT" ]]; then ok "usage error writes nothing to stdout"; else bad "usage error wrote to stdout: $OUT"; fi

run 2 "unknown command" bogus
want_err "unknown command names the token" "unknown command: bogus"

run 2 "scoped flag on wrong command" stale --top 5
want_err "scoped flag reports its commands" "--top only applies to"

# --- --help wins over a bad token on the same line -------------------------
run 0 "--help after bad token" --nope --help
want_out "--help wins over a bad token" "usage:"

# --- a command's result is on stdout, progress on stderr -------------------
# `config` reports what the machine resolves; the result belongs on stdout so it
# can be piped. Nothing is scanned and HOME is a temp dir, so it is safe.
run 0 "config" config
if [[ -n "$OUT" ]]; then ok "config prints its result on stdout"; else bad "config printed nothing to stdout"; fi

# `disk` on a temp directory: the tree (the result) on stdout, the "scanning"
# progress line on stderr. Also the fast proof that a piped stdout carries no
# SGR escape despite colour being available on a TTY.
mkdir -p "$TMP/tree/sub"; echo hi > "$TMP/tree/sub/f.txt"
run 0 "disk tree" disk "$TMP/tree"
# The root row is the folder's name, like every row below it; the full path is
# on the stderr "scanning" line.
want_out "disk prints the root row on stdout" 'tree  '
want_out "disk prints the nested file on stdout" '    f.txt  '
want_err "disk progress goes to stderr" "scanning"
if [[ "$OUT" == *$'\033['* ]]; then
    bad "disk piped: ANSI escape on stdout despite TERM=dumb"
else
    ok "piped stdout carries no ANSI escape"
fi

# A disk root that does not exist is a usage error (exit 2), not exit 0.
run 2 "disk missing root" disk "$TMP/tree/does-not-exist"
want_err "disk missing root says so" "no such directory"

# `erase` reports what it did, and that result belongs on stdout with every
# other command's, so `appattic erase` and `appattic erase | grep snapshot`
# work. It used to go to stderr, which left the whole result off stdout and
# the command unpipeable. The temp XDG_DATA_HOME/HOME means this can only
# remove a temp snapshot that does not exist; the real account's cache is
# never touched.
run 0 "erase" erase
want_out "erase reports its result on stdout" "no scan snapshot at"

if [[ "$fails" -eq 0 ]]; then
    echo "cli-contract: ok"
    exit 0
fi
echo "cli-contract: $fails failure(s)" >&2
exit 1