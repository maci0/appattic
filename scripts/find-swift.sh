# shellcheck shell=bash
# shellcheck disable=SC2154  # ROOT is set by every script that sources this one
# Sourced by build.sh and scripts/check.sh. Requires ROOT.

appattic_find_swift() {
    if command -v swift >/dev/null 2>&1; then
        return 0
    fi
    local d
    for d in /opt/swift/usr/bin "$ROOT/.deps/swift/usr/bin"; do
        if [[ -x "$d/swift" ]]; then
            PATH="$d:${PATH:-}"
            export PATH
            return 0
        fi
    done
    return 1
}

# The version the tree is built against, whether or not swift is installed,
# so a preflight can name the exact toolchain it needs. Same contract as
# appattic_zig_version: loud on a missing or empty pin.
appattic_swift_version() {
    local ver
    if [[ ! -r "$ROOT/.swift-version" ]]; then
        echo "error: missing $ROOT/.swift-version; the required Swift version is declared there" >&2
        return 1
    fi
    ver="$(tr -d '[:space:]' < "$ROOT/.swift-version")"
    if [[ -z "$ver" ]]; then
        echo "error: empty $ROOT/.swift-version" >&2
        return 1
    fi
    printf '%s\n' "$ver"
}

appattic_require_swift() {
    local want
    want="$(appattic_swift_version)" || exit 1
    if ! appattic_find_swift; then
        echo "error: swift missing (need $want, see .swift-version)" >&2
        echo "Linux: ./scripts/linux-deps.sh --install-swift" >&2
        echo "       then: export PATH=\"/opt/swift/usr/bin:\$PATH\"" >&2
        echo "       (without root: PATH=\"$ROOT/.deps/swift/usr/bin:\$PATH\")" >&2
        echo "macOS: Xcode 15.4 or https://www.swift.org/install/" >&2
        exit 1
    fi
    local ver
    ver="$(swift --version 2>/dev/null || true)"
    ver="${ver%%$'\n'*}"
    case "$ver" in
        *"Swift version $want "*|*"Apple Swift version $want "*) ;;
        *)
            echo "error: need Swift $want from .swift-version (have: $ver)" >&2
            exit 1
            ;;
    esac
}
