#!/usr/bin/env bash
# Run AppAttic's threaded code under ThreadSanitizer.
#
# Two places in this tree run their own threads, and both are the kind of code
# a data race hides in rather than reveals:
#
#   core/host/hostexec.c   the UI applies the user PATH on the thread that
#                          starts a scan and restores it on the thread that ran
#                          it, so apply/restore runs concurrently. The statics
#                          behind it (g_user_path, g_user_path_prev) are exactly
#                          what a torn write would put a truncated PATH into the
#                          environment with, and the test hammers the pair from
#                          four threads (check_user_path_concurrent).
#
#   ui/linux-qt            diskusage.cpp defers a directory's subtree to a
#                          worker pool, and finding.cpp measures leftover sizes
#                          on a pool too. Both hand a partition of a shared
#                          vector to the workers and fold the results back
#                          afterwards, so a lost update, a double fold, or a row
#                          measured by two threads all read as one plausible
#                          number rather than a crash. tests/race_tests.cpp
#                          asserts those totals and every row's own size, which
#                          is what fails when the ordering is wrong.
#
# A sanitizer trace is the strongest race evidence a run can give, so both are
# built and run under one. Nothing here installs anything: a missing toolchain
# is a named skip, never a download.
#
# Usage: scripts/race-check.sh [--qt]
#   (default)  the C host concurrency test under TSan (needs only cc)
#   --qt       also the Qt worker-pool tests under TSan (needs Qt 6)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export LC_ALL=C
export LANG=C
export TZ=UTC

RUN_QT=0
for arg in "$@"; do
    case "$arg" in
        --qt) RUN_QT=1 ;;
        -h|--help)
            cat <<'EOF'
Usage: scripts/race-check.sh [--qt]

  (default)  ThreadSanitizer run of the C host concurrency test (core/host),
             which needs only a C compiler.
  --qt       additionally build and run ui/linux-qt/tests/race_tests.cpp under
             ThreadSanitizer, which covers the diskusage.cpp walk and the
             finding.cpp leftover-size pool. Needs Qt 6 and CMake; Wasmtime is
             not required for this one, unlike the Qt helper tests.

Exits 1 on a sanitizer report or a failed assertion, so it is usable as a CI
step. A toolchain that is absent is a named skip, not a failure.
EOF
            exit 0
            ;;
        *)
            echo "error: unknown argument: $arg" >&2
            echo "Usage: $0 [--qt]" >&2
            echo "       $0 --help" >&2
            exit 2
            ;;
    esac
done

# TSAN_OPTIONS: halt_on_error=0 so the report is printed in full rather than
# truncated at the first race, and a nonzero exit code so a report still fails
# the step even when the instrumented binary's own assertions happen to pass.
export TSAN_OPTIONS="${TSAN_OPTIONS:-halt_on_error=0 exitcode=66}"

CC="${CC:-cc}"
if ! command -v "$CC" >/dev/null 2>&1; then
    echo "race-check: no C compiler (\$CC=$CC); skipping the C host check"
    CC=""
fi

# Under TSan the build is slower and the instrumented PATH hammer runs 2000
# apply/restore pairs per thread, so the binary is built out of tree. The
# output directory lives under the system temp dir and is removed on exit so a
# run leaves nothing behind and two concurrent runs cannot share a binary.
OUT="$(mktemp -d "${TMPDIR:-/tmp}/appattic-race.XXXXXX")"
cleanup() { rm -rf "$OUT"; }
trap cleanup EXIT

HOST_RAN=0
if [[ -n "$CC" ]]; then
    echo "== C host under ThreadSanitizer =="
    # The Linux fixtures, exactly as core/build.sh sets them: hostexec.c
    # defaults to the fixtures on Darwin only.
    export APPATTIC_HOST_EXEC_FIXTURE=1
    "$CC" -fsanitize=thread -g -O1 \
        -I"$ROOT/core/host" \
        "$ROOT/core/host/hostexec.c" \
        "$ROOT/core/host/tests/hostexec_test.c" \
        -o "$OUT/hostexec_test" -lpthread
    "$OUT/hostexec_test"
    HOST_RAN=1
fi

QT_RAN=0
if [[ "$RUN_QT" -eq 1 ]]; then
    echo "== Qt worker pools under ThreadSanitizer =="
    # shellcheck source=find-wasmtime.sh
    . "$ROOT/scripts/find-wasmtime.sh"
    if ! command -v cmake >/dev/null 2>&1; then
        echo "race-check: cmake not found; skipping the Qt check"
    elif ! pkg-config --exists Qt6Widgets 2>/dev/null; then
        echo "race-check: Qt 6 not found; skipping the Qt check"
        echo "           Linux: scripts/linux-deps.sh (see CONTRIBUTING.md)"
    elif ! appattic_find_wasmtime; then
        # The Qt project's CMakeLists resolves the wasmtime C API before it
        # defines any target, so configuring it needs Wasmtime even though
        # these two test targets do not link it. Same dependency the Qt link
        # itself has, and the same helper that finds it.
        echo "race-check: wasmtime C API not found; skipping the Qt check"
        echo "           Linux: scripts/linux-deps.sh --install-wasmtime"
    else
        BUILD="$OUT/qt"
        # -fsanitize=thread has to be on the compile and on the link of the
        # target under test, which is why it goes through CMAKE_CXX_FLAGS and
        # CMAKE_EXE_LINKER_FLAGS rather than a single variable.
        if ! cmake -S "$ROOT/ui/linux-qt" -B "$BUILD" \
            -DCMAKE_BUILD_TYPE=Debug \
            -DWASMTIME_ROOT="$WASMTIME_DIR" \
            -DCMAKE_CXX_FLAGS="-fsanitize=thread -g -O1" \
            -DCMAKE_EXE_LINKER_FLAGS="-fsanitize=thread" \
            >"$OUT/configure.log" 2>&1; then
            echo "race-check: cmake configure failed; see $OUT/configure.log"
            cat "$OUT/configure.log" >&2
            exit 1
        fi
        if ! cmake --build "$BUILD" --target appattic-qt-race-tests \
            -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)" \
            >"$OUT/build.log" 2>&1; then
            echo "race-check: build failed; see $OUT/build.log"
            cat "$OUT/build.log" >&2
            exit 1
        fi
        # The disk walk uses QFile/QDir and a temp dir but never opens a
        # window, so it runs without a display; set the platform anyway so a
        # machine with a broken display cannot make this step flaky.
        QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-offscreen}" "$BUILD/appattic-qt-race-tests"
        QT_RAN=1
    fi
fi

if [[ "$HOST_RAN" -eq 0 && "$QT_RAN" -eq 0 ]]; then
    echo "race-check: nothing ran (no toolchain for either check)"
    exit 1
fi
if [[ "$HOST_RAN" -eq 1 && "$QT_RAN" -eq 0 && "$RUN_QT" -eq 1 ]]; then
    echo "note: the Qt worker-pool check was skipped; only the C host ran"
fi
echo "race-check: no sanitizer reports"