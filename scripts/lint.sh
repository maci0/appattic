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
  host C warnings-as-errors, host C under ASan + UBSan,
  hostexec warnings-as-errors, dependency pin consistency,
  zig fmt --check, no AI tool credit in commit messages
EOF
        exit 0
        ;;
    "")
        ;;
    *)
        echo "error: unknown argument: $1" >&2
        echo "Usage: bash scripts/lint.sh" >&2
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
shellcheck -x -P SCRIPTDIR "${shell_files[@]}"

# One declared version, three copies to keep in step (AppStream release,
# Info.plist, the qt man page), plus a CFBundleVersion that is a rising build
# number. Mismatch means an artifact reports one number while the packaging
# record says another.
bash "$ROOT/scripts/check-version.sh" >/dev/null

if ! command -v yamllint >/dev/null 2>&1; then
    # The pin lives in deps.sh, which also fails when the workflow and that pin
    # disagree, so name it here rather than sending the contributor to CI.
    yl="$(bash "$ROOT/scripts/deps.sh" yamllint-version)"
    echo "error: yamllint missing (CI lints with yamllint $yl)" >&2
    echo "install: uv tool install \"yamllint==$yl\"" >&2
    exit 1
fi
# --strict: without it yamllint exits 0 on warnings, so a rule downgraded to a
# warning is a rule nothing fails on.
yamllint --strict -c "$ROOT/.yamllint" "$ROOT"/.github/*.yml \
    "$ROOT"/.github/workflows/*.yml "$ROOT"/packaging/flatpak/*.yml

echo "== dependency pins =="
bash "$ROOT/scripts/deps.sh" check

if ! command -v cc >/dev/null 2>&1; then
    echo "error: cc missing" >&2
    exit 1
fi
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# One warning set for both builds below, so the sanitizer build cannot drift
# into compiling sources the plain build would have rejected. Every flag is
# GCC 10+ and clang 10+, checked against both. core/build.sh and the Qt
# CMakeLists carry a smaller set for the shipped binary; this gate is the
# strictest of the three, so a warning here is a warning there too.
strict_cflags=(-Wall -Wextra -Werror
    -Wformat=2 -Wformat-security -Wshadow -Wstrict-prototypes -Wconversion
    -Wpedantic -Wnull-dereference
    -Wcast-qual -Wundef -Wmissing-prototypes -Wold-style-definition
    -Wredundant-decls -Wswitch-enum -Wdouble-promotion -Wfloat-equal
    -Wjump-misses-init -Wtautological-compare)
cflags=(-O2 "${strict_cflags[@]}")
# Every C file under core/host is compiled here, so a new one cannot join the
# tree without also joining the gate. embed.c is the exception: it needs the
# Wasmtime C API headers, which the lint job does not install. CMake compiles it
# for the Qt app with -Wall -Wextra.
skip_c="embed.c"
for src in "$ROOT"/core/host/*.c "$ROOT"/core/host/tests/*.c; do
    base="$(basename "$src")"
    case " $skip_c " in
        *" $base "*) continue ;;
    esac
    cc "${cflags[@]}" -I "$ROOT/core/host" -c "$src" -o "$tmp/${base%.c}.o"
done
cc "${cflags[@]}" \
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
