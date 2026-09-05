# shellcheck shell=bash
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

appattic_require_swift() {
    local want
    want="$(tr -d '[:space:]' < "$ROOT/.swift-version" 2>/dev/null || true)"
    if [[ -z "$want" ]]; then
        want="5.10.1"
    fi
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
