#!/usr/bin/env bash
# Shellcheck, yamllint, host C warnings-as-errors, zig fmt when zig is on PATH,
# and commit messages that credit an AI tool.
# Usage: bash scripts/lint.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export LC_ALL=C
export LANG=C
export TZ=UTC

case "${1:-}" in
    -h|--help)
        cat <<'EOF'
Usage: bash scripts/lint.sh

  shellcheck on the shell scripts, yamllint on the YAML,
  host C warnings-as-errors under every compiler on PATH,
  host C under ASan + UBSan, host C under -fanalyzer and clang --analyze,
  hostexec warnings-as-errors, dependency pin consistency,
  the system-name list matches across the Zig core and the Swift library,
  desktop entry, AppStream metainfo, man page, Flatpak manifest,
  zig fmt --check, no AI tool credit in commit messages
EOF
        exit 0
        ;;
    "")
        ;;
    *)
        echo "error: unknown argument: $1" >&2
        echo "Usage: bash scripts/lint.sh" >&2
        echo "       bash scripts/lint.sh --help" >&2
        exit 2
        ;;
esac

if ! command -v shellcheck >/dev/null 2>&1; then
    echo "error: shellcheck missing" >&2
    echo "Linux: bash scripts/linux-deps.sh --install-shellcheck" >&2
    echo "macOS: xcode-select --install, then bash scripts/lint.sh again" >&2
    exit 1
fi
# Discovered, not listed: a script added anywhere in the tree joins the gate
# without someone having to remember to name it here. The prunes are build
# output and vendored trees, which hold no first-party shell.
mapfile -t shell_files < <(
    find "$ROOT" \
        \( -name .git -o -name .zig-cache -o -name .zig-cache-local \
           -o -name .build -o -name .deps -o -name build \) -prune \
        -o -type f -name '*.sh' -print | LC_ALL=C sort
)
if [[ "${#shell_files[@]}" -eq 0 ]]; then
    echo "error: no shell script found to check" >&2
    exit 1
fi
# The optional checks are off unless named, and --enable=optional does not name
# them: shellcheck lists each by name, and the group keyword is not a list of
# them. So the ones the tree passes are named one by one below. The rest stay
# off because the tree does not pass them: masked return (SC2312) and
# suppressed set -e (SC2310) want 120 and 81 rewrites, and ${var} braces
# (SC2250) and [[ ]] (SC2292) are the two style rewrites, at 1502 and 32.
# `shellcheck --enable=all` on the list above is what the four numbers are.
shellcheck -x -P SCRIPTDIR \
    --enable=add-default-case,avoid-negated-conditions,avoid-nullary-conditions,check-unassigned-uppercase,deprecate-which,quote-safe-variables,useless-use-of-cat \
    "${shell_files[@]}"

# One declared version, three copies to keep in step (AppStream release,
# Info.plist, the qt man page), plus a CFBundleVersion that is a rising build
# number. Mismatch means an artifact reports one number while the packaging
# record says another.
bash "$ROOT/scripts/check-version.sh" >/dev/null

# One system-name list, two trees. core/src/linux-system-names.txt is the
# declaration docs/THREAT_MODEL.md cites. Zig embeds it with @embedFile and
# SwiftPM copies it as a resource, and neither can reach outside its own tree,
# so the file under Sources/AppAtticScan is a mirror. Nothing compared the two,
# so a name added on one side silently stops classifying on the other, and a
# credential tree reaches the cleanup script on the stale side.
if ! cmp -s "$ROOT/core/src/linux-system-names.txt" \
        "$ROOT/Sources/AppAtticScan/linux-system-names.txt"; then
    echo "error: the system-name list differs between the Zig core and the Swift scan library" >&2
    echo "       fix: cp core/src/linux-system-names.txt Sources/AppAtticScan/linux-system-names.txt" >&2
    exit 1
fi
echo "system-name list mirror: ok"

# One page vocabulary, two shells. StartPage.swift declares the sidebar page
# names and both windows read APPATTIC_PAGE, but the names are spelled out a
# second time in the Qt window's page table and in the warning it prints for an
# unknown one. The two trees cannot share a constant across the language
# boundary and nothing compared them, so a page added in Swift leaves the Qt
# window opening the overview and quoting a value list that no longer matches.
swift_pages="$(sed -n '/^public enum StartPage/,/^}/p' \
    "$ROOT/Sources/AppAtticScan/StartPage.swift" \
    | sed -n 's/^    case \([a-z]*\)$/\1/p')"
qt_pages="$(sed -n '/initialPageFromName/,/^    }/p' "$ROOT/ui/linux-qt/main.cpp" \
    | sed -n 's/^ *{QStringLiteral("\([a-z]*\)"), Page::.*/\1/p')"
qt_valid_values="$(sed -n 's/.*Valid values: \([a-z, .]*\)\\n".*/\1/p' \
    "$ROOT/ui/linux-qt/main.cpp" | tr -d ' .\n')"
if [[ -z "$swift_pages" || -z "$qt_pages" ]]; then
    echo "error: could not read the StartPage cases or the Qt page table" >&2
    echo "       fix: keep 'case <page>' lines in the StartPage enum and the" >&2
    echo "             {QStringLiteral(\"<page>\"), Page::...} table in main.cpp" >&2
    exit 1
fi
if [[ "$(LC_ALL=C sort <<<"$swift_pages")" != "$(LC_ALL=C sort <<<"$qt_pages")" ]]; then
    echo "error: the sidebar page names differ between StartPage.swift and the Qt page table" >&2
    echo "       swift: $(LC_ALL=C sort <<<"$swift_pages" | tr '\n' ' ')" >&2
    echo "       qt:    $(LC_ALL=C sort <<<"$qt_pages" | tr '\n' ' ')" >&2
    exit 1
fi
if [[ "$qt_valid_values" != "$(tr '\n' ',' <<<"$swift_pages" | sed 's/,$//')" ]]; then
    echo "error: the Qt 'Valid values' list does not match the StartPage cases" >&2
    echo "       qt: $qt_valid_values" >&2
    exit 1
fi
echo "page vocabulary: ok"

# One on/off spelling, three trees. `configBoolSwitch` in the scan library
# reports what `core/host/hostexec.c` will do with the two host-exec switches,
# and Package.swift reads APPATTIC_NO_MAC_UI at manifest time, where it cannot
# import the library that declares the rule. Nothing compared the lists, so a
# value the README calls on (`yes`) can be read as off by the core host while
# the report calls it on, and APPATTIC_NO_MAC_UI grew a third spelling.
switch_on_words() {
    grep -o '"[a-z0-9]*"' <<<"$1" | tr -d '"' | LC_ALL=C sort -u | tr '\n' ' '
}
# The C host writes the off-branch first and the on-branch second, and each
# branch's spellings sit on the lines ending at the branch's `return`. The
# on-branch is the `eq_ignore_case` names immediately before `return 1;`.
c_on="$(sed -n '/^static int env_flag/,/^}/p' "$ROOT/core/host/hostexec.c" \
    | grep -B2 'return 1;' | grep 'eq_ignore_case')"
swift_on="$(switch_on_words "$(sed -n '/^func configBoolSwitch/,/^}/p' \
    "$ROOT/Sources/AppAtticScan/Settings.swift" | grep 'return')")"
manifest_on="$(switch_on_words "$(sed -n '/^private func envSwitchIsOn/,/^}/p' \
    "$ROOT/Package.swift" | grep 'return')")"
c_on="$(switch_on_words "$c_on")"
if [[ -z "$swift_on" || "$swift_on" != "$c_on" || "$swift_on" != "$manifest_on" ]]; then
    echo "error: the on/off switch spellings differ between the trees" >&2
    echo "       swift (configBoolSwitch): $swift_on" >&2
    echo "       c      (env_flag):        $c_on" >&2
    echo "       manifest (Package.swift): $manifest_on" >&2
    exit 1
fi
echo "switch spellings: ok"

# The desktop entry, the AppStream metainfo, the man page, and the Flatpak
# manifest have to name the same app, the same binary, and the same icon, and
# the install has to produce what they name. Nothing builds a Flatpak or an
# AppImage on every change, so this is where a rename that misses one of those
# files is caught.
bash "$ROOT/scripts/check-packaging.sh"

if ! command -v yamllint >/dev/null 2>&1; then
    # The pin lives in deps.sh, which also fails when the workflow and that pin
    # disagree, so name it here rather than sending the contributor to CI.
    yl="$(bash "$ROOT/scripts/deps.sh" yamllint-version)"
    echo "error: yamllint missing (CI lints with yamllint $yl)" >&2
    echo "install: pipx install \"yamllint==$yl\"   (or: uv tool install \"yamllint==$yl\")" >&2
    exit 1
fi
# --strict: without it yamllint exits 0 on warnings, so a rule downgraded to a
# warning is a rule nothing fails on. The file list is discovered, like the
# shell list above: a workflow in a new directory, or a file written as .yaml
# instead of .yml, would otherwise leave the gate without anyone noticing.
# .yamllint is itself YAML and linted here, so a rule edit cannot break the
# config the gate runs on.
mapfile -t yaml_files < <(
    find "$ROOT" \
        \( -name .git -o -name .zig-cache -o -name .zig-cache-local \
           -o -name .build -o -name .deps -o -name build -o -name dist \) -prune \
        -o -type f \( -name '*.yml' -o -name '*.yaml' \) -print \
        | LC_ALL=C sort
)
if [[ "${#yaml_files[@]}" -eq 0 ]]; then
    echo "error: no YAML file found to check" >&2
    exit 1
fi
yamllint --strict -c "$ROOT/.yamllint" "${yaml_files[@]}"

echo "== dependency pins =="
bash "$ROOT/scripts/deps.sh" check

if ! command -v cc >/dev/null 2>&1; then
    echo "error: cc missing" >&2
    exit 1
fi
# The same sources under every compiler on PATH. One compiler's silence is not
# the other's: the two disagree on what they diagnose, so a gate that compiles
# with whichever cc resolves to passes a defect the shipped toolchain warns
# about. cc is the one that must exist; clang joins when present, and a host
# without it says so rather than reporting a pass it did not earn. The CI lint
# runner has both.
compilers=(cc)
if command -v clang >/dev/null 2>&1; then
    compilers+=(clang)
else
    echo "note: clang missing, C sources are compiled with cc only" >&2
    echo "      install: bash scripts/linux-deps.sh --install" >&2
fi
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# One warning set for every compile below, so no compiler in the loop and no
# later build can drift into diagnosing less. Every flag is GCC 10+ and
# clang 10+, checked against both. core/build.sh and the Qt CMakeLists carry a
# smaller set for the shipped binary; this gate is the strictest of the three,
# so a warning here is a warning there too.
strict_cflags=(-Wall -Wextra -Werror
    -Wformat=2 -Wformat-security -Wshadow -Wstrict-prototypes -Wconversion
    -Wpedantic -Wnull-dereference
    -Wcast-qual -Wundef -Wmissing-prototypes -Wold-style-definition
    -Wredundant-decls -Wswitch-enum -Wswitch-default -Wdouble-promotion
    -Wfloat-equal -Wtautological-compare)
# `-Wjump-misses-init` is GCC's alone, and clang refuses the whole invocation
# over a warning option it does not know — under `-Werror` that is a failed
# gate, not a note — so it joins the list for the compiler that has it.
gcc_only_cflags=(-Wjump-misses-init)
cflags=(-O2 "${strict_cflags[@]}")
compiler_cflags() {
    if [[ "$1" == clang* ]]; then
        printf '%s\n' "${cflags[@]}"
    else
        printf '%s\n' "${cflags[@]}" "${gcc_only_cflags[@]}"
    fi
}
embed_compiler_cflags() {
    if [[ "$1" == clang* ]]; then
        printf '%s\n' "${embed_cflags[@]}"
    else
        printf '%s\n' "${embed_cflags[@]}" "${gcc_only_cflags[@]}"
    fi
}
# Every C file under core/host is compiled here, so a new one cannot join the
# tree without also joining the gate. Discovered, not listed: a new
# subdirectory of core/host otherwise compiles with warnings nothing fails on.
mapfile -t c_sources < <(
    find "$ROOT/core/host" -type d \( -name build -o -name out \) -prune \
        -o -type f -name '*.c' -print | LC_ALL=C sort
)
if [[ "${#c_sources[@]}" -eq 0 ]]; then
    echo "error: no C source found under core/host to check" >&2
    exit 1
fi
# embed.c is the Wasmtime loader, and it was the one source this gate skipped:
# it needs the Wasmtime C API headers, and the lint job did not install them.
# It is now installed there, so embed.c compiles here like every other source.
# The flags are the ones the Qt CMakeLists already gives it for the shipped
# binary, so the gate cannot demand more than the shipped build passes. A host
# without the headers says which file went unchecked and how to get them.
wasmtime_include=""
for hint in "${WASMTIME_DIR:-}" /opt/wasmtime-c-api "$ROOT/.deps/wasmtime-c-api" \
            /opt/homebrew /usr/local; do
    if [[ -n "$hint" && -f "$hint/include/wasmtime.h" ]]; then
        wasmtime_include="$hint/include"
        break
    fi
done
embed_cflags=(-O2 -Wall -Wextra -Werror -Wformat=2 -Wformat-security -Wshadow
    -Wstrict-prototypes -Wconversion -Wpedantic -Wnull-dereference)
if [[ -z "$wasmtime_include" ]]; then
    echo "note: Wasmtime C API headers not found, embed.c not compiled here" >&2
    echo "      install: bash scripts/linux-deps.sh --install-wasmtime" >&2
fi
for comp in "${compilers[@]}"; do
    mapfile -t comp_cflags < <(compiler_cflags "$comp")
    mapfile -t comp_embed_cflags < <(embed_compiler_cflags "$comp")
    for src in "${c_sources[@]}"; do
        base="$(basename "$src")"
        obj="$tmp/${comp}-${base%.c}.o"
        if [[ "$base" == embed.c ]]; then
            if [[ -z "$wasmtime_include" ]]; then
                continue
            fi
            # -isystem for the third-party headers: they are not this tree's
            # to fix, and their own warnings — `wasi.h` under
            # -Wstrict-prototypes, in a warnings-as-errors pass — would
            # otherwise fail the gate on code the gate does not own. Our own
            # sources are still checked with the strict set.
            "$comp" "${comp_embed_cflags[@]}" -I "$ROOT/core/host" \
                -isystem "$wasmtime_include" -c "$src" -o "$obj"
            continue
        fi
        "$comp" "${comp_cflags[@]}" -I "$ROOT/core/host" -c "$src" -o "$obj"
    done
done

# The same sources under the compiler's static analyzer. Everything above
# asks whether the code compiles clean; this asks whether the paths the
# compiler never took are sound, which is the question a C host running
# fork, pipe, poll and exec under another process's PATH cannot answer by
# reading the warnings. It runs at -O0 because the analyzer follows the
# source CFG, and at -O2 GCC bails out of most of this file with
# "terminating analysis for this program point" and reports nothing.
#
# -fanalyzer is GCC's alone. clang has no such option and warns about the
# unknown one, which under -Werror fails the gate, so the pass runs only for a
# GCC driver and says so otherwise rather than reporting a pass it did not
# earn.
gcc_analyzer=""
for comp in "${compilers[@]}"; do
    if "$comp" --version 2>/dev/null | head -1 | grep -qi gcc; then
        gcc_analyzer="$comp"
        break
    fi
done
if [[ -z "$gcc_analyzer" ]]; then
    echo "note: no GCC on PATH, the C static analyzer pass did not run" >&2
    echo "      install: bash scripts/linux-deps.sh --install" >&2
else
    echo "== C host under -fanalyzer =="
    # -Wno-analyzer-too-complex: the analyzer reporting that it gave up on a
    # path is the analyzer's limit, not a defect in this tree, and under
    # -Werror it would fail the gate on the very file it could not finish.
    analyzer_cflags=(-O0 -fanalyzer -Wno-analyzer-too-complex
        -Wall -Wextra -Werror)
    for src in "${c_sources[@]}"; do
        base="$(basename "$src")"
        # embed.c keeps the compile pass's rule: it needs the Wasmtime C API
        # headers, and a source this gate cannot compile is a source it cannot
        # analyze. A host without them says which file went unchecked.
        if [[ "$base" == embed.c ]]; then
            continue
        fi
        "$gcc_analyzer" "${analyzer_cflags[@]}" -I "$ROOT/core/host" \
            -c "$src" -o "$tmp/analyzer-${base%.c}.o"
    done
    echo "analyzer: ok"
fi

# The GCC pass above and this one are not the same analyzer reading the same
# code. GCC's -fanalyzer follows the CFG out of one function; clang's walks
# paths through the whole translation unit, so it is what catches a store that
# nothing reads and a value that reaches a call on a path GCC never took. The
# C host forks, pipes and execs under another process's PATH, which is exactly
# the shape where a second opinion is worth the seconds it costs.
#
# clang --analyze prints its findings and still exits 0, and -Werror does not
# reach them: a gate that only looked at the exit status would report every
# finding as a pass. So the findings are captured and matched here, the way
# core/build.sh reads zig test's log for the same reason.
if [[ -z "$(command -v clang || true)" ]]; then
    echo "note: clang missing, the clang static analyzer pass did not run" >&2
    echo "      install: bash scripts/linux-deps.sh --install" >&2
else
    echo "== C host under clang --analyze =="
    for src in "${c_sources[@]}"; do
        base="$(basename "$src")"
        # embed.c for the reason the compile pass above gives.
        if [[ "$base" == embed.c ]]; then
            continue
        fi
        log="$tmp/analyzer-${base%.c}.log"
        if ! clang --analyze -Xclang -analyzer-output=text \
                -std=gnu11 -I "$ROOT/core/host" "$src" -o /dev/null \
                >"$log" 2>&1; then
            echo "error: clang --analyze failed on $src" >&2
            cat "$log" >&2
            exit 1
        fi
        if grep -q '^[^ ].*: warning:' "$log"; then
            echo "error: clang --analyze found something in $src" >&2
            cat "$log" >&2
            exit 1
        fi
    done
    echo "clang analyzer: ok"
fi
mapfile -t cc_cflags < <(compiler_cflags cc)
cc "${cc_cflags[@]}" \
    -I "$ROOT/core/host" \
    "$ROOT/core/host/hostexec.c" \
    "$ROOT/core/host/tests/hostexec_test.c" \
    -o "$tmp/hostexec_test"
case "$(uname -s)" in
    Linux) APPATTIC_HOST_EXEC_FIXTURE=1 "$tmp/hostexec_test" ;;
    *) "$tmp/hostexec_test" ;;
esac

# The same C sources again under ASan and UBSan. The suite above proves the
# tests pass; this proves they pass without a heap overflow, a use-after-free
# or undefined behaviour hiding behind a passing result. -fno-sanitize-recover
# makes a UBSan finding fail the run instead of printing and continuing.
echo "== C host under ASan + UBSan =="
# shellcheck disable=SC2054  # the comma belongs to -fsanitize, not the array
san_cflags=(-O1 -g -fno-omit-frame-pointer
    -fsanitize=address,undefined -fno-sanitize-recover=undefined
    "${strict_cflags[@]}")
if ! cc "${san_cflags[@]}" \
    -I "$ROOT/core/host" \
    "$ROOT/core/host/hostexec.c" \
    "$ROOT/core/host/tests/hostexec_test.c" \
    -o "$tmp/hostexec_test_san" 2>"$tmp/san_build.log"; then
    echo "error: the C host does not build with -fsanitize=address,undefined" >&2
    cat "$tmp/san_build.log" >&2
    exit 1
fi
case "$(uname -s)" in
    Linux) APPATTIC_HOST_EXEC_FIXTURE=1 "$tmp/hostexec_test_san" ;;
    *) "$tmp/hostexec_test_san" ;;
esac
echo "sanitizers: ok"

check_commit_messages() {
    local pattern
    pattern='^(co-authored-by|generated-by|built-with|assisted-by|helped-by):.*(claude|anthropic|copilot|codex|chatgpt|openai|gpt-[0-9]|gemini|cursor|codeium|windsurf|devin|qwen|llama|grok|perplexity)'
    if ! command -v git >/dev/null 2>&1 || ! git rev-parse --git-dir >/dev/null 2>&1; then
        echo "note: not a git checkout, skip commit-message check" >&2
        return 0
    fi
    local seen bad
    seen="$(git rev-list --count HEAD 2>/dev/null || printf '0')"
    bad="$(git log --format='%s%n%b' | grep -Ei "$pattern" || true)"
    if [[ -n "$bad" ]]; then
        echo "error: commit message credits an AI tool:" >&2
        printf '%s\n' "$bad" >&2
        echo "fix: reword that commit (git rebase -i, reword) and drop the trailer" >&2
        exit 1
    fi
    echo "commit messages: ok ($seen commits)"
}
check_commit_messages

# A local checkout without zig skips the check, but CI must never pass on the
# skip: the lint job installs the pinned toolchain first.
# shellcheck source=find-zig.sh
. "$ROOT/scripts/find-zig.sh"
if appattic_require_zig; then
    zig fmt --check "$ROOT/core/src" "$ROOT/core/bench"
fi
