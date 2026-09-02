# shellcheck shell=bash
# Sourced by linux-deps.sh and linux-appimage.sh.
# Looks up names in dep-checksums.sha256 next to this file and checks SHA-256.

require_sha256sum() {
    if ! command -v sha256sum >/dev/null 2>&1; then
        echo "error: sha256sum required to verify downloads" >&2
        exit 1
    fi
}

checksums_file() {
    local here
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    printf '%s\n' "${APPATTIC_CHECKSUMS:-$here/dep-checksums.sha256}"
}

checksum_for() {
    local name="$1"
    local sums
    sums="$(checksums_file)"
    if [[ ! -f "$sums" ]]; then
        echo "error: missing checksums file $sums" >&2
        return 1
    fi
    awk -v n="$name" '
        $1 ~ /^[0-9a-f]{64}$/ && $2 == n { print $1; found=1 }
        END { exit !found }
    ' "$sums"
}

file_sha256() {
    sha256sum -- "$1" | awk '{print $1}'
}

curl_fetch() {
    local url="$1"
    local dest="$2"
    if ! command -v curl >/dev/null 2>&1; then
        echo "error: curl required to download $(basename -- "$dest")" >&2
        return 1
    fi
    curl --proto '=https' --tlsv1.2 --retry 5 --retry-delay 2 --retry-connrefused -fsSL "$url" -o "$dest"
}

verify_sha256() {
    local file="$1"
    local expected="$2"
    local got
    require_sha256sum
    got="$(file_sha256 "$file")"
    if [[ "$got" != "$expected" ]]; then
        echo "error: SHA-256 mismatch for $(basename -- "$file")" >&2
        echo "  expected: $expected" >&2
        echo "  got:      $got" >&2
        return 1
    fi
}
