# shellcheck shell=bash
# shellcheck disable=SC2154  # ROOT is set by every script that sources this one
# Sourced by core/build.sh, core/bench.sh, scripts/lint.sh, scripts/check.sh,
# scripts/linux-qt-link.sh and scripts/linux-appimage.sh. Requires ROOT.

appattic_find_zig() {
    if command -v zig >/dev/null 2>&1; then
        return 0
    fi
    local d
    for d in /opt/zig /usr/local/bin "$ROOT/.deps/zig"; do
        if [[ -x "$d/zig" ]]; then
            PATH="$d:${PATH:-}"
            export PATH
            return 0
        fi
    done
    return 1
}

# The version the tree is built against, whether or not zig is installed:
# ZIG_VERSION overrides the pin the way the Docker builds use it, and the
# installer scripts need the string for a download URL. Exits loud on a
# missing or empty pin, so a caller that downloads a tarball never names
# ziglang.org/download//.
appattic_zig_version() {
    local ver
    if [[ -n "${ZIG_VERSION:-}" ]]; then
        printf '%s\n' "$ZIG_VERSION"
        return 0
    fi
    if [[ ! -r "$ROOT/.zig-version" ]]; then
        echo "error: missing $ROOT/.zig-version; the required Zig version is declared there" >&2
        return 1
    fi
    ver="$(tr -d '[:space:]' < "$ROOT/.zig-version")"
    if [[ -z "$ver" ]]; then
        echo "error: empty $ROOT/.zig-version" >&2
        return 1
    fi
    printf '%s\n' "$ver"
}

# Same rule as scripts/lint.sh: a local checkout without zig gets a note and
# keeps going, CI never passes on the skip.
appattic_require_zig() {
    if ! appattic_find_zig; then
        if [[ "${CI:-}" == "true" ]]; then
            echo "error: zig missing in CI; run: bash scripts/linux-deps.sh --install-zig" >&2
            exit 1
        fi
        echo "note: zig not on PATH, skip the Zig checks" >&2
        return 1
    fi
    # The pin, not the override: this gate asks whether the installed toolchain
    # is the one the tree declares, and ZIG_VERSION only names what to fetch.
    if [[ ! -r "$ROOT/.zig-version" ]]; then
        echo "error: missing $ROOT/.zig-version; the required Zig version is declared there" >&2
        exit 1
    fi
    local want ver
    want="$(tr -d '[:space:]' < "$ROOT/.zig-version")"
    if [[ -z "$want" ]]; then
        echo "error: empty $ROOT/.zig-version" >&2
        exit 1
    fi
    ver="$(zig version)"
    if [[ "$ver" != "$want" ]]; then
        echo "error: need zig $want from .zig-version (have $ver). scripts/linux-deps.sh --install-zig" >&2
        exit 1
    fi
    return 0
}
