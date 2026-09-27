#!/usr/bin/env bash
# Dependency inventory and pin consistency for the third-party code this repo
# ships: what it fetches, what SwiftPM resolves, and what it vendors.
#
#   bash scripts/deps.sh check   verify pins agree across the tree (no args also means check)
#   bash scripts/deps.sh sbom    write a CycloneDX 1.5 SBOM for the requested output
#
# Usage: bash scripts/deps.sh sbom <out.json>
#
# The SBOM is generated from files already in the tree (dep-checksums.sha256, the
# tables below, Package.resolved), so it needs no scanner, no network, and no
# extra tool.
set -euo pipefail

_script_dir="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$_script_dir/.." && pwd)"
cd "$ROOT"
export LC_ALL=C
export LANG=C
export TZ=UTC

CHECKSUMS="scripts/dep-checksums.sha256"
APP_NAME="appattic"
APP_PURL="pkg:github/appattic/appattic"
# yamllint is not a fetched artifact (no tarball, no checksum), but CI installs
# it from PyPI at run time, so its version is a pin like any other.
YAMLLINT_VERSION="1.38.0"

usage() {
    cat <<'EOF'
Usage: bash scripts/deps.sh [check | sbom <out.json> | yamllint-version]

  check             default; pins must agree across dep-checksums.sha256,
                    scripts/, packaging/flatpak/, and the tables in this file
  sbom <out.json>   CycloneDX 1.5 inventory of fetched artifacts, SwiftPM
                    pins, and vendored third-party files
  yamllint-version  the yamllint version CI installs, for scripts/lint.sh
EOF
}

# One row per fetchable artifact:
#   name|version|purl|upstream|download url|version assignment in the fetcher
# `upstream` is the release page the artifact comes from; it must still be the
# one a script or manifest names. The last field is the shell assignment that
# carries the version, empty where a version file (`.swift-version`,
# `.zig-version`) is what pins it. check keeps this table, the checksum file,
# and the download sites in agreement; sbom turns it into the inventory.
ARTIFACTS=$(cat <<'EOF'
swift-5.10.1-RELEASE-ubuntu22.04.tar.gz|5.10.1|pkg:generic/swift|https://download.swift.org|https://download.swift.org/swift-5.10.1-release/ubuntu2204/swift-5.10.1-release/swift-5.10.1-RELEASE-ubuntu22.04.tar.gz|
swift-5.10.1-RELEASE-ubuntu22.04-aarch64.tar.gz|5.10.1|pkg:generic/swift|https://download.swift.org|https://download.swift.org/swift-5.10.1-release/ubuntu2204-aarch64/swift-5.10.1-release/swift-5.10.1-RELEASE-ubuntu22.04-aarch64.tar.gz|
zig-x86_64-linux-0.16.0.tar.xz|0.16.0|pkg:generic/zig|https://ziglang.org/download/0.16.0|https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz|
zig-aarch64-linux-0.16.0.tar.xz|0.16.0|pkg:generic/zig|https://ziglang.org/download/0.16.0|https://ziglang.org/download/0.16.0/zig-aarch64-linux-0.16.0.tar.xz|
wasmtime-v28.0.0-x86_64-linux-c-api.tar.xz|28.0.0|pkg:github/bytecodealliance/wasmtime|https://github.com/bytecodealliance/wasmtime/releases|https://github.com/bytecodealliance/wasmtime/releases/download/v28.0.0/wasmtime-v28.0.0-x86_64-linux-c-api.tar.xz|WASMTIME_C_API_VERSION:-28.0.0
wasmtime-v28.0.0-aarch64-linux-c-api.tar.xz|28.0.0|pkg:github/bytecodealliance/wasmtime|https://github.com/bytecodealliance/wasmtime/releases|https://github.com/bytecodealliance/wasmtime/releases/download/v28.0.0/wasmtime-v28.0.0-aarch64-linux-c-api.tar.xz|WASMTIME_C_API_VERSION:-28.0.0
linuxdeploy-x86_64.AppImage|1-alpha-20251107-1|pkg:github/linuxdeploy/linuxdeploy|https://github.com/linuxdeploy/linuxdeploy|https://github.com/linuxdeploy/linuxdeploy/releases/download/1-alpha-20251107-1/linuxdeploy-x86_64.AppImage|LINUXDEPLOY_VER=1-alpha-20251107-1
linuxdeploy-aarch64.AppImage|1-alpha-20251107-1|pkg:github/linuxdeploy/linuxdeploy|https://github.com/linuxdeploy/linuxdeploy|https://github.com/linuxdeploy/linuxdeploy/releases/download/1-alpha-20251107-1/linuxdeploy-aarch64.AppImage|LINUXDEPLOY_VER=1-alpha-20251107-1
linuxdeploy-plugin-qt-x86_64.AppImage|1-alpha-20250213-1|pkg:github/linuxdeploy/linuxdeploy-plugin-qt|https://github.com/linuxdeploy/linuxdeploy-plugin-qt|https://github.com/linuxdeploy/linuxdeploy-plugin-qt/releases/download/1-alpha-20250213-1/linuxdeploy-plugin-qt-x86_64.AppImage|LINUXDEPLOY_PLUGIN_QT_VER=1-alpha-20250213-1
linuxdeploy-plugin-qt-aarch64.AppImage|1-alpha-20250213-1|pkg:github/linuxdeploy/linuxdeploy-plugin-qt|https://github.com/linuxdeploy/linuxdeploy-plugin-qt|https://github.com/linuxdeploy/linuxdeploy-plugin-qt/releases/download/1-alpha-20250213-1/linuxdeploy-plugin-qt-aarch64.AppImage|LINUXDEPLOY_PLUGIN_QT_VER=1-alpha-20250213-1
appimagetool-x86_64.AppImage|1.9.1|pkg:github/AppImage/appimagetool|https://github.com/AppImage/appimagetool|https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-x86_64.AppImage|APPIMAGETOOL_VER=1.9.1
appimagetool-aarch64.AppImage|1.9.1|pkg:github/AppImage/appimagetool|https://github.com/AppImage/appimagetool|https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-aarch64.AppImage|APPIMAGETOOL_VER=1.9.1
EOF
)

# One row per third-party file that lives in the tree instead of being fetched,
# because it ships inside the binary:
#   name|path|sha256|purl|SPDX license id|license text path|upstream
# A vendored file is pinned by its own content, so the hash belongs here beside
# the path rather than in dep-checksums.sha256, which pins downloads. The font
# is compiled into the Qt resource, so its grant has to ship too: OFL 1.1 wants
# the license to travel with the font software, which
# ui/linux-qt/CMakeLists.txt installs next to it. sbom lists the row with its
# license; check fails when the bytes, the license text, or the row set drifts.
# No version column: the upstream font carries none to record, and a made-up
# one is worse than none.
VENDORED=$(cat <<'EOF'
Michroma-Regular.ttf|ui/linux-qt/fonts/Michroma-Regular.ttf|b62301163788bc5b7f8fcac0b74b184e34e1827e577b499ecb724da065098f87|pkg:generic/michroma|OFL-1.1|ui/linux-qt/fonts/Michroma-OFL.txt|https://github.com/googlefonts/Michroma-font
EOF
)

FAILURES=0
fail() {
    echo "error: $1" >&2
    FAILURES=$((FAILURES + 1))
}

# JSON emitted here holds only names, versions, purls, and https URLs, so the
# character set is fixed instead of escaped. Anything else is a bug, not input.
JSON_SAFE='^[A-Za-z0-9._~:/@%?#=+,-]+$'
assert_json_safe() {
    local field="$1" value="$2"
    if [[ ! "$value" =~ $JSON_SAFE ]]; then
        fail "$field has characters that cannot be written to JSON unescaped: $value"
    fi
}

# name -> "hash|version|purl|url", straight from the table.
table_row() {
    local want="$1" name version purl upstream url anchor
    while IFS='|' read -r name version purl upstream url anchor; do
        [[ "$name" == "$want" ]] || continue
        printf '%s|%s|%s|%s\n' "$(checksum_for "$name")" "$version" "$purl" "$url"
        return 0
    done <<<"$ARTIFACTS"
    return 1
}

# The single version a name glob pins, or nonzero when the table names
# different versions under one glob.
table_version_for() {
    local want="$1" name version purl upstream url anchor found=""
    while IFS='|' read -r name version purl upstream url anchor; do
        # shellcheck disable=SC2053  # the glob is meant to match the name
        [[ "$name" == $want ]] || continue
        if [[ -n "$found" && "$found" != "$version" ]]; then
            return 1
        fi
        found="$version"
    done <<<"$ARTIFACTS"
    [[ -n "$found" ]] || return 1
    printf '%s\n' "$found"
}

# shellcheck source=verify-sha256.sh
. "$_script_dir/verify-sha256.sh"

# Names of every downloaded artifact, plus the hash and version each one pins.
parse_checksums() {
    awk '
        /^[[:space:]]*#/ || NF == 0 { next }
        {
            if (length($1) != 64 || $1 !~ /^[0-9a-f]+$/ || NF != 2) {
                printf "BAD\t%s\n", $0
                next
            }
            printf "OK\t%s\t%s\n", $2, $1
        }
    ' "$CHECKSUMS"
}

check_checksum_file() {
    local status name
    local declared=0
    while IFS=$'\t' read -r status name; do
        case "$status" in
            OK) declared=$((declared + 1)) ;;
            *) fail "$CHECKSUMS: line is not '<64 hex> <name>': $name" ;;
        esac
    done < <(parse_checksums)
    local listed
    listed="$(grep -cvE '^[[:space:]]*(#|$)' "$CHECKSUMS" || true)"
    if [[ "$declared" -ne "$listed" ]]; then
        fail "$CHECKSUMS: $listed pinned lines, $declared parseable"
    fi
    local dupes
    dupes="$(parse_checksums | awk -F'\t' '$1 == "OK" { print $2 }' | sort | uniq -d)"
    if [[ -n "$dupes" ]]; then
        fail "$CHECKSUMS: duplicate artifact names: $(printf '%s' "$dupes" | tr '\n' ' ')"
    fi
}

# Every table row has a hash, and every hash has a table row.
check_table_coverage() {
    local name version purl upstream url anchor
    while IFS='|' read -r name version purl upstream url anchor; do
        if ! table_row "$name" >/dev/null; then
            fail "table entry $name has no hash in $CHECKSUMS"
            continue
        fi
        assert_json_safe "table purl" "$purl"
        assert_json_safe "table version" "$version"
        assert_json_safe "table url" "$url"
    done <<<"$ARTIFACTS"
    local listed
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        if ! table_row "$name" >/dev/null; then
            fail "$name is pinned in $CHECKSUMS but absent from the table in scripts/deps.sh"
        fi
    done < <(parse_checksums | awk -F'\t' '$1 == "OK" { print $2 }')
}

# Paths of every vendored file, one per line, for the coverage check below.
vendored_paths() {
    awk -F'|' 'NF >= 2 && $2 != "" { print $2 }' <<<"$VENDORED"
}

# Paths of the license texts those files are covered by. A grant is not an
# asset of its own: it is the row's own license_path, and shipping it is the
# install rule's job, not a second inventory entry.
vendored_license_paths() {
    awk -F'|' 'NF >= 6 && $6 != "" { print $6 }' <<<"$VENDORED"
}

# Every vendored file exists, still hashes to the pinned value, and names a
# license text that is in the tree. The hash is what catches a binary asset
# being replaced under the pin, which nothing else here would notice.
check_vendored() {
    require_sha256sum
    local name path hash purl license license_path upstream dir file rel
    while IFS='|' read -r name path hash purl license license_path upstream; do
        [[ -n "$name" ]] || continue
        if [[ -z "$path" || -z "$hash" || -z "$purl" || -z "$license" \
            || -z "$license_path" || -z "$upstream" ]]; then
            fail "vendored $name leaves a column empty; a shipped file needs a hash, a purl, a license, and its text"
            continue
        fi
        assert_json_safe "vendored name" "$name"
        assert_json_safe "vendored purl" "$purl"
        assert_json_safe "vendored license" "$license"
        if [[ ! -f "$ROOT/$path" ]]; then
            fail "vendored $name is declared at $path, which is not in the tree"
            continue
        fi
        if [[ "$(file_sha256 "$ROOT/$path")" != "$hash" ]]; then
            fail "vendored $name does not match its pinned SHA-256; the file changed under the pin"
        fi
        if [[ ! -s "$ROOT/$license_path" ]]; then
            fail "vendored $name names license text $license_path, which is missing or empty"
        fi
    done <<<"$VENDORED"

    # A file dropped beside a vendored one joins the binary through the qrc, so
    # an undeclared file is third-party code shipping with no hash and no
    # license. Only this direction needs checking: the rows themselves were
    # verified against the tree above.
    local licenses
    licenses="$(vendored_license_paths)"
    while IFS='|' read -r name path _; do
        [[ -n "$name" ]] || continue
        dir="${path%/*}"
        [[ -d "$ROOT/$dir" ]] || continue
        for file in "$ROOT/$dir"/*; do
            [[ -f "$file" ]] || continue
            rel="${file#"$ROOT"/}"
            if printf '%s\n' "$licenses" | grep -qxF -- "$rel"; then
                continue
            fi
            if ! vendored_paths | grep -qxF -- "$rel"; then
                fail "$rel sits in the vendored set but has no row in scripts/deps.sh: no hash, no license"
            fi
        done
    done <<<"$VENDORED"
}

# The Flatpak manifest carries its own sha256 field, which flatpak-builder
# checks. Two copies of a hash drift, so both must be in dep-checksums.sha256.
check_flatpak_hashes() {
    local manifest hash
    for manifest in packaging/flatpak/*.yml; do
        [[ -f "$manifest" ]] || continue
        while IFS= read -r hash; do
            [[ -n "$hash" ]] || continue
            if ! awk -v h="$hash" '$1 == h { found = 1 } END { exit !found }' "$CHECKSUMS"; then
                fail "$manifest pins sha256 $hash, absent from $CHECKSUMS"
            fi
        done < <(awk '/sha256:/ { print $2 }' "$manifest")
    done
}

# Every table row must name a release site and a version that a script or
# manifest in the tree still uses. This file is excluded from the search: the
# table would otherwise match itself.
check_urls() {
    local name version purl upstream url anchor
    local fetchers=(
        "$ROOT/scripts/linux-deps.sh"
        "$ROOT/scripts/linux-appimage.sh"
        "$ROOT/scripts/linux-flatpak.sh"
        "$ROOT/packaging/flatpak"
    )
    while IFS='|' read -r name version purl upstream url anchor; do
        if ! grep -rqF "$upstream" "${fetchers[@]}"; then
            fail "no download site names the $name upstream $upstream"
        fi
        if [[ -n "$anchor" ]] && ! grep -rqF "$anchor" "${fetchers[@]}"; then
            fail "$name pins $version but no download site carries '$anchor'"
        fi
    done <<<"$ARTIFACTS"
}

# Zig and Swift versions are read from version files that must agree with the
# pinned artifact names.
check_version_anchors() {
    local zig swift_version
    zig="$(tr -d '[:space:]' <"$ROOT/.zig-version")"
    swift_version="$(tr -d '[:space:]' <"$ROOT/.swift-version")"
    local name version purl upstream url anchor
    while IFS='|' read -r name version purl upstream url anchor; do
        case "$name" in
            zig-*.tar.xz)
                [[ "$version" == "$zig" ]] || fail "$name pins $version, .zig-version says $zig"
                ;;
            swift-*.tar.gz)
                [[ "$version" == "$swift_version" ]] \
                    || fail "$name pins $version, .swift-version says $swift_version"
                ;;
        esac
    done <<<"$ARTIFACTS"
}

# No file in the tree may spell a Zig or Wasmtime artifact version that differs
# from the table above: the flatpak script and manifest repeat those names, and
# a stale repeat would fetch something the checksum file does not cover.
check_artifact_versions_in_tree() {
    local manifest zig wasmtime
    zig="$(tr -d '[:space:]' <"$ROOT/.zig-version")"
    wasmtime="$(table_version_for 'wasmtime-*')" || {
        fail "the table pins no Wasmtime version to compare the tree against"
        return
    }
    for manifest in "$ROOT"/.github/workflows/*.yml "$ROOT"/scripts/*.sh \
        "$ROOT"/packaging/flatpak/*.yml "$ROOT"/Dockerfile "$ROOT"/Dockerfile.arch; do
        [[ -f "$manifest" ]] || continue
        # This file is the table the check compares against; it would only
        # report each pin against itself.
        [[ "$manifest" == "$_script_dir/deps.sh" ]] && continue
        local found name_version
        while IFS= read -r found; do
            [[ -n "$found" ]] || continue
            case "$found" in
                zig-*-linux-*.tar.xz)
                    name_version="${found#*-linux-}"
                    name_version="${name_version%.tar.xz}"
                    [[ "$name_version" == "$zig" ]] \
                        || fail "${manifest#"$ROOT"/}: $found, .zig-version says $zig"
                    ;;
                wasmtime-v*.tar.xz)
                    name_version="${found#wasmtime-v}"
                    name_version="${name_version%%-*}"
                    [[ "$name_version" == "$wasmtime" ]] \
                        || fail "${manifest#"$ROOT"/}: $found, the table pins $wasmtime"
                    ;;
            esac
        done < <(grep -rhoE '(zig|wasmtime)[a-zA-Z0-9._-]*\.tar\.xz' "$manifest" || true)
    done
}

# Every uv-installed tool is pinned to the version declared here, so a lint run
# cannot pick up a different release than the one the config was written for.
check_tool_pins() {
    local workflow line spec
    for workflow in "$ROOT"/.github/workflows/*.yml; do
        [[ -f "$workflow" ]] || continue
        while IFS= read -r line; do
            [[ "$line" == *"uv tool install"* ]] || continue
            spec="$(printf '%s' "$line" | sed -n 's/.*uv tool install "\([^"]*\)".*/\1/p')"
            if [[ -z "$spec" ]]; then
                spec="$(printf '%s' "$line" | sed -n 's/.*uv tool install \(.*\)/\1/p')"
            fi
            [[ "$spec" == "yamllint==${YAMLLINT_VERSION}" ]] || fail \
                "${workflow#"$ROOT"/}: installs '$spec', deps.sh pins yamllint==${YAMLLINT_VERSION}"
        done < <(grep -n 'uv tool install' "$workflow" || true)
    done
}

# The Swift toolchain is declared twice: in .swift-version, and in every
# setup-swift step. CI must build with the declared version, so a bump that
# misses a workflow has to fail here rather than on the runner.
check_workflow_swift_versions() {
    local declared workflow step
    declared="$(tr -d '[:space:]' < "$ROOT/.swift-version")"
    for workflow in "$ROOT"/.github/workflows/*.yml; do
        [[ -f "$workflow" ]] || continue
        while IFS= read -r step; do
            if [[ "$step" != "$declared" ]]; then
                fail "${workflow#"$ROOT"/} pins setup-swift to $step, .swift-version says $declared"
            fi
        done < <(sed -n 's/^[[:space:]]*swift-version:[[:space:]]*"\([^"]*\)".*/\1/p' "$workflow")
    done
}

# SwiftPM pins the whole tree by commit revision, so an unpinned pin means a
# build that resolves a different source than the one reviewed.
check_swiftpm_pins() {
    local resolved="$ROOT/Package.resolved"
    if [[ ! -f "$resolved" ]]; then
        fail "Package.resolved is missing; SwiftPM pins would not be reviewed"
        return
    fi
    local identity count
    count="$(swiftpm_pins | wc -l)"
    if [[ "$count" -eq 0 ]]; then
        fail "Package.resolved parsed as zero pins"
    fi
    while IFS= read -r identity; do
        [[ -n "$identity" ]] || continue
        if [[ "$identity" == *"$APP_NAME"* ]]; then
            fail "SwiftPM pin $identity shadows the $APP_NAME project name"
        fi
    done < <(swiftpm_pins | awk -F'\t' '{ print $1 }')
    # A revision is last, so an absent one is a trailing empty field: bash
    # folds runs of tab, and a gap in the middle would shift the columns.
    while IFS=$'\t' read -r identity version location revision; do
        [[ -n "$identity" ]] || continue
        if [[ -z "$revision" ]]; then
            fail "SwiftPM pin $identity carries no revision; a branch pin is not a pin"
        fi
    done < <(swiftpm_pins)
    check_swiftpm_declarations
}

# Every dependency Package.swift declares must resolve to the version the
# manifest pins, from the URL the manifest names. A resolved file that
# disagrees is the one SwiftPM silently rewrites, so nothing else would
# notice the drift until a build fetched different source.
check_swiftpm_declarations() {
    local identity version url resolved resolved_version resolved_location
    while IFS=$'\t' read -r identity version url; do
        [[ -n "$identity" ]] || continue
        resolved="$(swiftpm_pins | awk -F'\t' -v i="$identity" '$1 == i { print $2 "\t" $3 }')"
        if [[ -z "$resolved" ]]; then
            fail "Package.swift declares $identity, Package.resolved pins no such package"
            continue
        fi
        resolved_version="${resolved%%$'\t'*}"
        resolved_location="${resolved#*$'\t'}"
        [[ "$resolved_version" == "$version" ]] || fail \
            "Package.swift pins $identity $version, Package.resolved pins $resolved_version"
        [[ "$resolved_location" == "$url" ]] || fail \
            "Package.swift fetches $identity from $url, Package.resolved pins $resolved_location"
    done < <(swiftpm_declared)
}

# identity|version|url for every .package(url:, .exact()) in Package.swift.
# SwiftPM derives a package identity from the URL by dropping the scheme and
# the .git suffix, so this reads the same key Package.resolved records.
swiftpm_declared() {
    local url version identity
    while IFS=$'\t' read -r url version; do
        [[ -n "$url" ]] || continue
        identity="${url##*/}"
        identity="${identity%.git}"
        printf '%s\t%s\t%s\n' "$identity" "$version" "$url"
    done < <(
        sed -n 's/.*\.package(url:[[:space:]]*"\([^"]*\)"[[:space:]]*,[[:space:]]*\.exact("\([^"]*\)").*/\1\t\2/p' \
            "$ROOT/Package.swift"
    )
}

# identity|version|location|revision, one per pin, tab separated. SwiftPM
# writes no revision for a branch or a plain range, so that column is empty
# and the check has to reject it.
swiftpm_pins() {
    awk '
        function flush() {
            if (identity != "") {
                printf "%s\t%s\t%s\t%s\n", identity, version, location, revision
            }
            identity = ""; version = ""; revision = ""; location = ""
        }
        /"identity"/    { flush(); identity = value() }
        /"location"/    { location = value() }
        /"revision"/    { revision = value() }
        /"version"/     { version = value() }
        function value(   line) {
            line = $0
            sub(/^[^"]*"[^"]*"[[:space:]]*:[[:space:]]*"/, "", line)
            sub(/",?[[:space:]]*$/, "", line)
            return line
        }
    ' "$ROOT/Package.resolved"
}

run_check() {
    check_checksum_file
    check_table_coverage
    check_vendored
    check_flatpak_hashes
    check_urls
    check_version_anchors
    check_artifact_versions_in_tree
    check_tool_pins
    check_workflow_swift_versions
    check_swiftpm_pins
    if [[ "$FAILURES" -ne 0 ]]; then
        echo "deps: $FAILURES problem(s) with third-party pins" >&2
        return 1
    fi
    echo "deps: pins ok ($(parse_checksums | awk -F'\t' '$1 == "OK"' | wc -l) artifacts, $(vendored_paths | wc -l) vendored, $(swiftpm_pins | wc -l) SwiftPM pins)"
}

# CycloneDX 1.5. No scanner, no network: the inventory is read out of the
# files that already decide what gets fetched.
run_sbom() {
    local out="$1"
    local name version purl url hash row
    local epoch timestamp app_version
    epoch="${SOURCE_DATE_EPOCH:-0}"
    [[ "$epoch" =~ ^[0-9]+$ ]] || epoch=0
    timestamp="$(date -u -d "@${epoch}" +%Y-%m-%dT%H:%M:%SZ)"
    app_version="$(git describe --tags --exact-match 2>/dev/null || printf '0.0.0')"
    app_version="${app_version#v}"

    local components=()
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        if ! row="$(table_row "$name")"; then
            fail "cannot build SBOM: $name has no table row"
            return 1
        fi
        IFS='|' read -r hash version purl url <<<"$row"
        assert_json_safe "sbom name" "$name"
        components+=("$(artifact_component "$name" "$version" "$purl" "$url" "$hash" SHA-256)")
    done < <(parse_checksums | awk -F'\t' '$1 == "OK" { print $2 }' | sort)

    local identity rev location
    while IFS=$'\t' read -r identity version location rev; do
        [[ -n "$identity" ]] || continue
        if [[ -z "$rev" ]]; then
            fail "cannot build SBOM: $identity has no pinned revision"
            return 1
        fi
        assert_json_safe "sbom swiftpm identity" "$identity"
        assert_json_safe "sbom swiftpm version" "$version"
        assert_json_safe "sbom swiftpm location" "$location"
        components+=("$(artifact_component "$identity" "$version" "pkg:swift/${identity}" "$location" "$rev" SHA-1)")
    done < <(swiftpm_pins | sort)

    # Vendored files are already in the binary, so an inventory that stops at
    # the downloaded artifacts would under-report what the release ships.
    require_sha256sum
    local vname vpath vhash vpurl vlicense vlicense_path vupstream
    while IFS='|' read -r vname vpath vhash vpurl vlicense vlicense_path vupstream; do
        [[ -n "$vname" ]] || continue
        if [[ ! -f "$ROOT/$vpath" ]] || [[ "$(file_sha256 "$ROOT/$vpath")" != "$vhash" ]]; then
            fail "cannot build SBOM: vendored $vname is missing or does not match its pinned SHA-256"
            return 1
        fi
        if [[ ! -s "$ROOT/$vlicense_path" ]]; then
            fail "cannot build SBOM: vendored $vname names license text $vlicense_path, which is missing or empty"
            return 1
        fi
        assert_json_safe "sbom vendored name" "$vname"
        assert_json_safe "sbom vendored license" "$vlicense"
        components+=("$(vendored_component "$vname" "$vpurl" "$vupstream" "$vhash" "$vlicense")")
    done < <(awk -F'|' 'NF' <<<"$VENDORED")

    mkdir -p "$(dirname "$out")"
    {
        printf '{\n'
        printf '  "bomFormat": "CycloneDX",\n'
        printf '  "specVersion": "1.5",\n'
        printf '  "version": 1,\n'
        printf '  "metadata": {\n'
        printf '    "timestamp": "%s",\n' "$timestamp"
        printf '    "component": {\n'
        printf '      "type": "application",\n'
        printf '      "name": "%s",\n' "$APP_NAME"
        printf '      "version": "%s",\n' "$app_version"
        printf '      "purl": "%s"\n' "$APP_PURL"
        printf '    }\n'
        printf '  },\n'
        printf '  "components": [\n'
        local i last
        last=$((${#components[@]} - 1))
        for i in "${!components[@]}"; do
            printf '%s' "${components[$i]}"
            if [[ "$i" -lt "$last" ]]; then printf ',\n'; else printf '\n'; fi
        done
        printf '  ]\n'
        printf '}\n'
    } >"$out"
    if [[ "$FAILURES" -ne 0 ]]; then
        rm -f "$out"
        echo "deps: $FAILURES problem(s); SBOM not written" >&2
        return 1
    fi
    echo "deps: wrote $out (${#components[@]} components)"
}

artifact_component() {
    local name="$1" version="$2" purl="$3" url="$4" hash="$5" alg="$6"
    printf '    {\n'
    printf '      "type": "library",\n'
    printf '      "name": "%s",\n' "$name"
    printf '      "version": "%s",\n' "$version"
    printf '      "purl": "%s@%s",\n' "$purl" "$version"
    printf '      "hashes": [\n'
    printf '        { "alg": "%s", "content": "%s" }\n' "$alg" "$hash"
    printf '      ],\n'
    printf '      "externalReferences": [\n'
    printf '        { "type": "distribution", "url": "%s" }\n' "$url"
    printf '      ]\n'
    printf '    }'
}

# Same shape as artifact_component, plus the license and no version: a vendored
# file has no release the manifest can name, and a consumer reading the
# license is the point of listing it at all.
vendored_component() {
    local name="$1" purl="$2" upstream="$3" hash="$4" license="$5"
    printf '    {\n'
    printf '      "type": "library",\n'
    printf '      "name": "%s",\n' "$name"
    printf '      "purl": "%s",\n' "$purl"
    printf '      "hashes": [\n'
    printf '        { "alg": "SHA-256", "content": "%s" }\n' "$hash"
    printf '      ],\n'
    printf '      "licenses": [\n'
    printf '        { "license": { "id": "%s" } }\n' "$license"
    printf '      ],\n'
    printf '      "externalReferences": [\n'
    printf '        { "type": "distribution", "url": "%s" }\n' "$upstream"
    printf '      ]\n'
    printf '    }'
}

CMD="${1:-check}"
case "$CMD" in
    check)
        [[ $# -le 1 ]] || { usage >&2; exit 2; }
        run_check
        ;;
    sbom)
        if [[ $# -ne 2 ]]; then
            echo "error: sbom needs an output path" >&2
            usage >&2
            exit 2
        fi
        run_sbom "$2"
        ;;
    yamllint-version)
        # scripts/lint.sh names the pin when yamllint is missing, so the
        # version stays declared here with the rest of the tool pins.
        [[ $# -le 1 ]] || { usage >&2; exit 2; }
        printf '%s\n' "$YAMLLINT_VERSION"
        ;;
    -h | --help | help)
        usage
        ;;
    *)
        echo "error: unknown command: $CMD" >&2
        usage >&2
        exit 2
        ;;
esac
