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
  host C warnings-as-errors, hostexec warnings-as-errors,
  dependency pin consistency, zig fmt --check,
  no AI tool credit in commit messages
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
shellcheck -x -P SCRIPTDIR "$ROOT/build.sh" "$ROOT/run.sh" "$ROOT/core/build.sh" \
    "$ROOT/core/bench.sh" "$ROOT/scripts"/*.sh

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
yamllint -c "$ROOT/.yamllint" "$ROOT"/.github/workflows/*.yml "$ROOT"/packaging/flatpak/*.yml

echo "== dependency pins =="
bash "$ROOT/scripts/deps.sh" check

if ! command -v cc >/dev/null 2>&1; then
    echo "error: cc missing" >&2
    exit 1
fi
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cflags=(-O2 -Wall -Wextra -Werror -Wformat=2 -Wformat-security
    -Wshadow -Wstrict-prototypes -Wconversion -Wpedantic -Wnull-dereference)
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
