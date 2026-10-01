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
  the host plugin argv matches the list core/build.sh emits,
  no `path:line` citation in the markdown, since line numbers rot silently,
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
# suppressed set -e (SC2310) want 131 and 76 rewrites, and ${var} braces
# (SC2250) and [[ ]] (SC2292) are the two style rewrites, at 1690 and 36.
# SC2317 is not listed on its own: shellcheck pulls in SC2312 with it, so
# enabling it here would fail the gate on the masked returns named above.
# Every name below is one `--list-optional` prints, and the gate below proves
# it rather than trusting it: shellcheck accepts an unknown --enable name
# silently and exits 0, so a misspelled rule reads as a passing gate that never
# ran the check it claims to. `ban-eval` is the shape of name that reads
# right and buys nothing: this shellcheck implements 11 optional rules and
# `ban-eval` is not one of them, and a bare `eval` draws nothing from it at
# all. `--list-optional` is where a name comes from.
# `shellcheck --enable=all` on this list is what the numbers above are.
shellcheck -x -P SCRIPTDIR \
    --enable=add-default-case,avoid-negated-conditions,avoid-nullary-conditions,check-unassigned-uppercase,deprecate-which,quote-safe-variables,useless-use-of-cat \
    "${shell_files[@]}"

# Every name the flag above carries is a rule this shellcheck implements. Read
# the list from the invocation rather than from a grep over this file: the
# comments here discuss --enable=all and the word "optional", and a free-text
# match picks those up instead of the flag list.
mapfile -t enabled_checks < <(
    # shellcheck disable=SC2016  # the pattern names the literal ${shell_files[@]}
    sed -n '/^shellcheck -x -P SCRIPTDIR/,/^ *"\${shell_files\[@\]}"/p' \
        "${BASH_SOURCE[0]}" | grep -o -- '--enable=[a-z0-9,-]*' \
        | sed 's/--enable=//' | tr ',' '\n' | LC_ALL=C sort -u
)
mapfile -t known_checks < <(
    shellcheck --list-optional | grep -o 'name: *[a-z0-9-]*' | sed 's/name: *//' \
        | LC_ALL=C sort -u
)
if [[ "${#enabled_checks[@]}" -eq 0 ]]; then
    echo "error: could not read the --enable list off the shellcheck line above" >&2
    exit 1
fi
bogus=0
for _check in "${enabled_checks[@]}"; do
    if ! printf '%s\n' "${known_checks[@]}" | grep -qx "$_check"; then
        echo "error: '$_check' is not an optional rule this shellcheck implements" >&2
        echo "       fix: take the name from: shellcheck --list-optional" >&2
        echo "             an unknown name is ignored silently and the gate stays green" >&2
        bogus=1
    fi
done
if [[ "$bogus" -ne 0 ]]; then
    exit 1
fi
echo "shellcheck rule names: ok (${#enabled_checks[@]} of ${#known_checks[@]} optional rules)"

# Every runnable script answers --help. A contributor who cannot list a
# script's arguments has to read it, and a script that reaches its dependency
# check before its argument parsing answers --help with the missing dependency
# instead: `scripts/cli-contract.sh` printed "no built appattic CLI found" for
# `bash scripts/cli-contract.sh --help`, on a host that had simply never built
# one. Read by running rather than by grepping: the pre-fix script mentioned
# `--help` only inside its own test cases, so a text match said nothing about
# whether the flag was handled. Discovered rather than listed, like the list
# the checker walks above, so a new script joins the gate without being added
# here. A sourced library is not an entry point and has no arguments to list;
# the header comment naming its callers is the marker, and it is what makes a
# library readable as one.
#
# timeout caps the damage if a script ignores the flag and starts its real
# work: the check then fails on the timeout rather than hanging the gate on a
# build. CI and a developer machine agree on the bound because it is here.
mapfile -t entry_scripts < <(
    printf '%s\n' "${shell_files[@]}" | while read -r f; do
        head -6 "$f" | grep -qi 'sourced by' || printf '%s\n' "$f"
    done
)
entry_help_fail=0
for f in "${entry_scripts[@]}"; do
    name="$(basename "$f")"
    # `set -e` suspends inside the condition, so a script that exits non-zero
    # for --help lands in the else rather than killing the gate before it can
    # report which script did it.
    if out="$(timeout 30 bash "$f" --help 2>&1)"; then
        rc=0
    else
        rc=$?
    fi
    if [[ "$rc" -eq 124 ]]; then
        echo "error: $name --help timed out, so it does not answer before it works" >&2
        entry_help_fail=1
    elif [[ "$rc" -ne 0 ]]; then
        echo "error: $name --help exits $rc, so a contributor asking how to run it gets a failure" >&2
        printf '       %s\n' "${out%%$'\n'*}" >&2
        entry_help_fail=1
    fi
done
if [[ "$entry_help_fail" -ne 0 ]]; then
    echo "       fix: handle -h|--help in the argument parsing, before any dependency" >&2
    echo "             or missing-binary check, print the usage, and exit 0" >&2
    exit 1
fi
echo "entry-point help: ok (${#entry_scripts[@]} scripts)"

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

# One shadow-root list, two trees. The Zig plugin decides `path-shadow`'s
# presence tag from the roots it queries, and so does the Qt window, but the
# two live in different languages and nothing compared them. A root added to
# the Qt table alone leaves the plugin ACTIVE on a machine whose only overlay
# lives in that root, and the scan then reports no shadows, which reads as a
# clean machine. `defaultOverlayShadowRoots` in the Swift scan library is the
# same roots a third time; it is named here rather than read, because a Swift
# array literal and a Zig comptime list are not one text to compare.
zig_shadow_roots="$(sed -n '/^const overlay_local_bin = /,/^const package_usr_local_applications = /p' \
    "$ROOT/core/src/path_shadow.zig" \
    | grep -o 'pstore.home_sentinel ++ "[^"]*"' \
    | sed 's/.*++ "//; s/"$//; s|^/*||')"
qt_shadow_roots="$(sed -n '/^static const HomeRule kHomeRules/,/^};/p' \
    "$ROOT/ui/linux-qt/corehost.cpp" \
    | sed -n '/path_shadow/,/},/p' \
    | grep -o '"\.[a-z/._]*"\|"bin"' | tr -d '"')"
if [[ -z "$zig_shadow_roots" || -z "$qt_shadow_roots" ]]; then
    echo "error: could not read the shadow overlay roots from either tree" >&2
    echo "       fix: keep the 'const overlay_* = pstore.home_sentinel ++ ...' lines in" >&2
    echo "             core/src/path_shadow.zig and the path_shadow entry in kHomeRules" >&2
    echo "             in ui/linux-qt/corehost.cpp"
    exit 1
fi
if [[ "$(printf '%s\n' "$zig_shadow_roots" | LC_ALL=C sort)" \
        != "$(printf '%s\n' "$qt_shadow_roots" | LC_ALL=C sort)" ]]; then
    echo "error: the shadow overlay roots differ between the Zig plugin and the Qt window" >&2
    echo "       zig: $(printf '%s' "$zig_shadow_roots" | tr '\n' ' ')" >&2
    echo "       qt:  $(printf '%s' "$qt_shadow_roots" | tr '\n' ' ')" >&2
    echo "       fix: the same roots in core/src/path_shadow.zig, kHomeRules in" >&2
    echo "             ui/linux-qt/corehost.cpp, and defaultOverlayShadowRoots in" >&2
    echo "             Sources/AppAtticScan/Overlays.swift"
    exit 1
fi
echo "shadow overlay roots: ok ($(printf '%s\n' "$zig_shadow_roots" | wc -l) roots)"

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

# The same rule names what "surrounding blanks" means, and the three trees had
# three different answers: env_flag skips a space and a tab, the scan library
# trimmed .whitespaces (which is also a newline, a carriage return, a form
# feed, a vertical tab, and every Unicode space), and the manifest trimmed
# .whitespacesAndNewlines. A value like a newline-wrapped "1" was therefore read
# as on by the report and as off by the core host that runs the query, so the
# check above passed on the spellings while the two disagreed on the value. The
# set is now U+0009 and U+0020 in all three; the C host is the authority because
# it is what decides between canned fixtures and a live execvp.
#
# The C host spells the two blanks as the C escapes ' ' and '\t' on one line;
# the manifest and the library spell them as a `charactersIn:` literal holding
# the same two characters. Each side is decoded to its raw bytes and shown as
# hex, so the comparison is on the characters and not on how they are written.
# `|| true` so a moved or renamed line reaches the error below naming both
# empty sets, rather than aborting the whole lint on a bare grep miss.
c_trim_line="$(sed -n '/^static int env_flag/,/^}/p' "$ROOT/core/host/hostexec.c" \
    | grep -m1 "raw == ' '" || true)"
# `while (*raw == ' ' || *raw == '\t')` -> the two char literals after `== `.
c_trim="$(grep -oE "== '[^']*'" <<<"$c_trim_line" | cut -d "'" -f2 \
    | while IFS= read -r lit; do printf '%b' "$lit"; done \
    | od -An -tx1 | tr -d ' \n' | fold -w2 | LC_ALL=C sort -u | tr '\n' ' ')"
# The library keeps the set in configBoolSwitchTrimSet; the manifest inlines the
# same two characters, so that literal is read when the binding is not there.
swift_trim_src="$(sed -n '/^let configBoolSwitchTrimSet/,+0p' \
    "$ROOT/Sources/AppAtticScan/Settings.swift")"
# `|| true` so a moved or renamed line reaches the error below naming both
# empty sets, rather than aborting the whole lint on a bare grep miss.
[[ -n "$swift_trim_src" ]] || swift_trim_src="$(sed -n '/^private func envSwitchIsOn/,/^}/p' \
    "$ROOT/Package.swift" | grep 'charactersIn' || true)"
# A \t in the Swift literal is the two characters backslash-t; printf %b turns
# the escapes back into the byte they name before they are compared.
swift_trim="$(printf '%s' "$swift_trim_src" | cut -d '"' -f2 \
    | while IFS= read -r lit; do printf '%b' "$lit"; done \
    | od -An -tx1 | tr -d ' \n' | fold -w2 | LC_ALL=C sort -u | tr '\n' ' ')"
if [[ -z "$c_trim" || "$c_trim" != "$swift_trim" ]]; then
    echo "error: the on/off switch trim sets differ between the trees" >&2
    echo "       swift (configBoolSwitchTrimSet): $swift_trim" >&2
    echo "       c      (env_flag):               $c_trim" >&2
    exit 1
fi
# The set the check accepts is the C host's, named here so a future change there
# is a deliberate edit in all three trees rather than a silent disagreement.
if [[ "$c_trim" != "09 20 " ]]; then
    echo "error: env_flag no longer trims exactly a tab and a space" >&2
    echo "       got: $c_trim" >&2
    echo "       the switch rule, Package.swift, and the report must move with it" >&2
    exit 1
fi
echo "switch trim set: ok"

# One plugin list, three trees. `wasm_sources` in core/build.sh is the
# declaration the spec names, and the argv the build derives from it is copied
# into core/README.md and into the spec's Host load list. The two documents are
# hand-maintained copies of generated text and nothing compared them, so a
# plugin added to wasm_sources leaves both quoting an argv the build no longer
# prints, and the README says so in prose while the argv itself drifts. The
# argv is rebuilt here from core/build.sh (its artifact-name function and its
# tag case, read out of the file rather than restated) so the check follows a
# tag rule or a rename that changes.
build_try_line() {
    local out=./core/out src dst
    local artifact_fn tag_case
    artifact_fn="$(sed -n '/^wasm_artifact_name() {/,/^}/p' "$ROOT/core/build.sh")"
    # shellcheck disable=SC2016  # the pattern names a literal "$dst" in build.sh
    tag_case="$(sed -n '/^    case "\$dst" in/,/^    esac/p' "$ROOT/core/build.sh")"
    if [[ -z "$artifact_fn" || -z "$tag_case" ]]; then
        echo "error: could not read wasm_artifact_name or the tag case out of core/build.sh" >&2
        echo "       fix: keep the function and the 'case \"\$dst\" in' block build.sh has" >&2
        exit 1
    fi
    eval "$artifact_fn"
    try_line="$out/host $out/appattic_core.wasm"
    while read -r src; do
        [[ -n "$src" ]] || continue
        # shellcheck disable=SC2034  # $dst is what the evaluated case reads
        dst="$(wasm_artifact_name "$src")"
        eval "$tag_case"
    done < <(sed -n '/^wasm_sources=(/,/^)/p' "$ROOT/core/build.sh" \
        | grep -o '[a-z0-9_]*\.zig')
    printf '%s\n' "$try_line"
}

# The argv a document quotes, as one line of ./core/out/... tokens. The block
# is the fenced run starting at the host line; the build line the spec block
# opens with is above it and is not part of the argv. The host line carries two
# tokens, every other line one, so each is taken on its own rather than by
# rewriting the line.
doc_try_line() {
    # grep exiting 1 on no match is the empty-block answer the caller checks
    # for, not a failure to report, so it does not end the run here.
    { sed -n '/^\.\/core\/out\/host /,/^```/p' "$1" \
        | grep -o '\./core/out/[a-z0-9_.]*=[0-9]*\|\./core/out/[a-z0-9_.]*' \
        || true; } | tr '\n' ' ' | sed 's/ $//'
}

build_try_line_out="$(build_try_line)"
if [[ -z "$build_try_line_out" ]]; then
    echo "error: core/build.sh yielded an empty host argv" >&2
    echo "       fix: wasm_sources is the plugin list the documents quote" >&2
    exit 1
fi
plugin_argv_docs=(
    "$ROOT/core/README.md"
    "$ROOT/docs/specs/2026-08-26-zig-wasm-core-design.md"
)
for _doc in "${plugin_argv_docs[@]}"; do
    _doc_line="$(doc_try_line "$_doc")"
    if [[ -z "$_doc_line" ]]; then
        echo "error: no host argv block found in ${_doc#"$ROOT"/}" >&2
        echo "       fix: quote the argv core/build.sh prints, fenced, from" >&2
        printf "             the './core/out/host ./core/out/appattic_core.wasm \\\\' line\n" >&2
        exit 1
    fi
    if [[ "$_doc_line" != "$build_try_line_out" ]]; then
        echo "error: the host argv in ${_doc#"$ROOT"/} is not the one core/build.sh prints" >&2
        echo "       build:   $build_try_line_out" >&2
        echo "       ${_doc#"$ROOT"/}: $_doc_line" >&2
        echo "       fix: paste the 'try:' line core/build.sh prints" >&2
        exit 1
    fi
done
echo "host plugin argv: ok"

# No `path:line` citation in a markdown doc. A line number in prose rots
# silently: nothing fails when an edit shifts one, and the doc still reads as
# though it had been checked, so a reader following a stale citation lands on
# whatever moved onto that line. The symbol is what a reader greps for, and it
# does not go stale. The spec cited twelve of these and six had already drifted
# by the time this check landed.
doc_cite_files=(
    "$ROOT/README.md"
    "$ROOT/DESIGN.md"
    "$ROOT/CONTRIBUTING.md"
    "$ROOT/core/README.md"
    "$ROOT/docs/specs/README.md"
    "$ROOT/docs/specs/2026-08-26-zig-wasm-core-design.md"
    "$ROOT/docs/privacy.md"
    "$ROOT/docs/tmog-design-language.md"
    "$ROOT/docs/runbooks/state-recovery.md"
)
cite_bad=0
for _cite_src in "${doc_cite_files[@]}"; do
    while IFS= read -r _cite; do
        echo "error: ${_cite_src#"$ROOT"/} cites a line number: $_cite" >&2
        cite_bad=1
    done < <(rg -N -o '`[A-Za-z0-9_./-]+\.(zig|swift|cpp|h|c|sh|sh):[0-9]+`' "$_cite_src" 2>/dev/null \
        | sort -u || true)
done
if [[ "$cite_bad" -ne 0 ]]; then
    echo "       fix: name the symbol and the file, without the line:" >&2
    # The backticks are the form being asked for, not a command.
    # shellcheck disable=SC2016
    echo '             (`groupLinuxLeftovers`, `ui/linux-qt/finding.cpp`)' >&2
    exit 1
fi
echo "doc citations: ok (no line numbers to go stale)"

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
# It is now installed there, so embed.c compiles here too, still skipped when a
# host lacks the headers.
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
