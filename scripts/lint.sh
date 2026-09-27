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

if ! command -v yamllint >/dev/null 2>&1; then
    echo "error: yamllint missing" >&2
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
cc -O2 -Wall -Wextra -Werror -Wformat=2 -Wformat-security \
    -Wshadow -Wstrict-prototypes -Wconversion -Wpedantic -Wnull-dereference \
    -I "$ROOT/core/host" \
    -c "$ROOT/core/host/stub.c" \
    -o "$tmp/stub.o"
cc -O2 -Wall -Wextra -Werror -Wformat=2 -Wformat-security \
    -Wshadow -Wstrict-prototypes -Wconversion -Wpedantic -Wnull-dereference \
    -I "$ROOT/core/host" \
    "$ROOT/core/host/hostexec.c" \
    "$ROOT/core/host/hostexec_test.c" \
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

if ! command -v zig >/dev/null 2>&1; then
    if [[ -x /opt/zig/zig ]]; then
        export PATH="/opt/zig:${PATH:-}"
    elif [[ -x /usr/local/bin/zig ]]; then
        export PATH="/usr/local/bin:${PATH:-}"
    elif [[ -x "$ROOT/.deps/zig/zig" ]]; then
        export PATH="$ROOT/.deps/zig:${PATH:-}"
    fi
fi
if command -v zig >/dev/null 2>&1; then
    zig fmt --check "$ROOT/core/src" "$ROOT/core/bench"
else
    # A local checkout without zig skips the check, but CI must never pass on
    # the skip: the lint job installs the pinned toolchain first.
    if [[ "${CI:-}" == "true" ]]; then
        echo "error: zig missing in CI; run: bash scripts/linux-deps.sh --install-zig" >&2
        exit 1
    fi
    echo "note: zig not on PATH, skip zig fmt --check" >&2
fi
