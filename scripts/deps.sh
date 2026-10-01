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

# One row per SwiftPM pin: identity|SPDX license id. A pin is third-party code
# SwiftPM compiles into a shipped binary (AppAtticUI links SwiftCrossUI, which
# links everything below it), so its grant ships with it exactly as the vendored
# font's does, and `sbom` records it for the same reason. Without this a
# consumer reading the inventory cannot tell whether what is in the binary is
# MIT, Apache-2.0, or the one weak-copyleft package in the set, which is the
# question a licence review opens the file to answer.
#
# Read from each package's LICENSE at its pinned revision, not from its
# homepage: a fork can relicense, and the pin is what decides what is compiled.
# `check` fails when a pin has no row, so a new transitive pin cannot join the
# tree with its licence silently unrecorded, and fails when a row names a pin
# Package.resolved no longer carries, so a removed dependency cannot leave a
# licence on record for code that is gone.
#
# The ids here are SPDX short identifiers, which is the vocabulary CycloneDX
# licenses[].license.id takes. jpeg is MPL-2.0, which is weak copyleft at
# file level: it obliges a modified copy of that package's own files to stay
# MPL, not the whole binary, so it does not reach the rest of AppAttic. It is
# recorded rather than omitted because it is the one row a reviewer has to read
# twice, and because a future pin under a copyleft licence is a question worth
# answering out loud instead of discovering in the inventory.
SWIFTPM_LICENSES=$(cat <<'EOF'
jpeg|MPL-2.0
libpng|Libpng
libwebp|BSD-3-Clause
swift-cross-ui|MIT
swift-cwinrt|BSD-3-Clause
swift-image-formats|MIT
swift-log|Apache-2.0
swift-macro-toolkit|Apache-2.0
swift-mutex|MIT
swift-syntax|Apache-2.0
swift-uwp|BSD-3-Clause
swift-webview2core|BSD-3-Clause
swift-windowsappsdk|BSD-3-Clause
swift-windowsfoundation|BSD-3-Clause
swift-winui|BSD-3-Clause
zlib|Zlib
EOF
)

# The SPDX id for one pin, or nonzero when the table has no row for it, names
# the same identity twice with different ids, or carries a blank id.
#
# A blank id counts as no row rather than as the empty string. The two read the
# same way in the table and mean different things here: a pin whose row is
# absent is a licence nobody wrote down, and a pin whose row is present but
# blank is the same mistake left just visible enough to slip past. Neither may
# become a component carrying licenses[].license.id "", which would record a
# grant nobody granted as though it had been checked. Two spellings of one pin
# are a table bug too, and picking either silently would record a licence
# nobody chose.
swiftpm_license() {
    local want="$1" identity license found=""
    while IFS='|' read -r identity license; do
        [[ -n "$identity" ]] || continue
        [[ "$identity" == "$want" ]] || continue
        license="${license//[[:space:]]/}"
        [[ -n "$license" ]] || continue
        if [[ -n "$found" && "$found" != "$license" ]]; then
            return 1
        fi
        found="$license"
    done <<<"$SWIFTPM_LICENSES"
    [[ -n "$found" ]] || return 1
    printf '%s\n' "$found"
}

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

# `flatpak build-bundle` puts the runtime in the bundle unless it is told not
# to, so the runtime is in the released artifact and the runtime is the
# largest third-party thing in it. It is not a download this tree verifies: the
# manifest names a branch, and nothing here fetches its bytes, so it has no row
# in dep-checksums.sha256 and no digest in the inventory. Leaving it out would
# report a bundle that is mostly somebody else's software as if it were only
# ours, so it is listed with the pin it actually has, and the branch is named
# in appattic:pinned-by rather than left for a reader to infer from a missing
# hash. The SDK is a build input and is not in the bundle, so it is not a row.
#
# Every manifest has to name a runtime, a branch for it, and an SDK. A manifest
# that drops runtime-version resolves the runtime's default branch instead,
# which moves the bytes in the bundle without touching anything this tree
# checks, so the omission has to fail here rather than on the builder.
#
# The SDK needs the same branch. `sdk: org.kde.Sdk` is a valid ref and resolves
# the SDK's default branch, so a build that installs and verifies
# org.kde.Sdk//6.10 still compiles against whatever the default branch is.
check_flatpak_platform() {
    local manifest rel key value sdk branch
    while IFS= read -r manifest; do
        [[ -n "$manifest" ]] || continue
        rel="${manifest#"$ROOT"/}"
        for key in runtime runtime-version sdk; do
            value="$(flatpak_manifest_value "$manifest" "$key")"
            if [[ -z "$value" ]]; then
                fail "$rel has no $key; the bundle ships the runtime, and an unnamed one is not pinned"
            fi
        done
        sdk="$(flatpak_manifest_value "$manifest" sdk)"
        branch="${sdk##*//}"
        if [[ -z "$branch" || "$branch" == "$sdk" ]]; then
            fail "$rel names the sdk as $sdk with no branch; flatpak-builder resolves the default branch instead of the one the build installs"
        elif [[ "$branch" != "$(flatpak_manifest_value "$manifest" runtime-version)" ]]; then
            fail "$rel builds against sdk branch $branch and runs on runtime branch $(flatpak_manifest_value "$manifest" runtime-version); they have to be the same"
        fi
    done < <(flatpak_manifests)
}

flatpak_manifests() {
    local manifest
    for manifest in "$ROOT"/packaging/flatpak/*.yml; do
        [[ -f "$manifest" ]] || continue
        printf '%s\n' "$manifest"
    done
}

# The value of one top-level key of a flatpak manifest, quotes stripped:
# `runtime: org.kde.Platform` and `runtime-version: "6.10"` are the same answer
# to the reader that asks for the runtime and for the branch it names.
flatpak_manifest_value() {
    local manifest="$1" key="$2"
    sed -n "s/^${key}:[[:space:]]*\"\{0,1\}\([^\"}[:space:]]*\)\"\{0,1\}[[:space:]]*\$/\1/p" "$manifest"
}

# name|branch for every runtime a manifest names, read out of the manifest
# itself: a second table here would be a third copy of the pin to keep in
# step with the other two, and nothing would notice when they parted.
flatpak_platform_rows() {
    local manifest name branch
    while IFS= read -r manifest; do
        [[ -n "$manifest" ]] || continue
        name="$(flatpak_manifest_value "$manifest" runtime)"
        branch="$(flatpak_manifest_value "$manifest" runtime-version)"
        [[ -n "$name" && -n "$branch" ]] || continue
        printf '%s\t%s\n' "$name" "$branch"
    done < <(flatpak_manifests)
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

# Every `uses:` in a workflow is third-party code the runner downloads and runs
# with the job's token, so it belongs in the same review as every other pin: a
# tag or a branch is a moving name, and a `uses:` on one is a dependency nobody
# looked at. The commit SHA is the pin; the `# vX.Y.Z` comment is what makes a
# bump reviewable, and Dependabot reads both (.github/dependabot.yml), so this
# is what keeps a new action from joining the tree unmentioned.
#
# A local action (`uses: ./path`) needs no pin: it is this tree. A `uses:`
# inside a comment is prose about a step rather than a step, and a `uses:` line
# inside a `run: |` block is script text the runner passes to a shell, so
# neither is a dependency.
check_action_pins() {
    local workflow line ref pin in_block block_indent line_indent
    for workflow in "$ROOT"/.github/workflows/*.yml; do
        [[ -f "$workflow" ]] || continue
        in_block=0
        block_indent=0
        # The whole file, not a grep of it: a `run: |` line is what closes a
        # block body, so filtering it out before the read would leave the
        # state machine below with no way to open or close a block.
        while IFS= read -r line || [[ -n "$line" ]]; do
            line_indent="${line%%[![:space:]]*}"
            [[ -n "$line_indent" ]] || line_indent="0"
            line_indent="${#line_indent}"
            # Block scalar body: a blank line, or one indented past the `run:`
            # that opened the block. Nothing in it is a workflow key, and a
            # gate that read a shell line as a step would fail a workflow over
            # a command it never runs. A dedent closes the block, which is how
            # the next step is reached.
            if [[ "$in_block" -eq 1 ]]; then
                if [[ -z "${line//[[:space:]]/}" ]] || [[ "$line_indent" -gt "$block_indent" ]]; then
                    continue
                fi
                in_block=0
            fi
            if [[ "$line" =~ ^[[:space:]]*(-[[:space:]]+)?run:[[:space:]]*(\||>)[0-9+-]*[[:space:]]*$ ]]; then
                in_block=1
                block_indent="$line_indent"
                continue
            fi
            [[ -n "$line" ]] || continue
            # Indent and YAML list item off, then only a line whose first word
            # is `uses:`.
            line="${line#"${line%%[![:space:]]*}"}"
            line="${line#- }"
            line="${line#"${line%%[![:space:]]*}"}"
            [[ "$line" == "uses:"* ]] || continue
            ref="${line#uses:}"
            ref="${ref%%#*}"
            ref="${ref#"${ref%%[![:space:]]*}"}"
            ref="${ref%"${ref##*[![:space:]]}"}"
            ref="${ref%\"}"
            ref="${ref%\'}"
            [[ -n "$ref" ]] || continue
            [[ "$ref" == ./* ]] && continue
            # 40 hex characters: GitHub's commit SHA-1. A length test rather
            # than a bracket expression, which cannot be written portably for
            # "exactly forty of these".
            pin="${ref##*@}"
            if [[ "${#pin}" -ne 40 || "$pin" == *[!0-9a-f]* ]]; then
                fail "${workflow#"$ROOT"/}: $ref is not pinned to a 40-character commit SHA; a tag or branch moves and the job would run code this tree never reviewed"
            elif [[ "$line" != *"#"* ]]; then
                fail "${workflow#"$ROOT"/}: $ref carries no # vX.Y.Z comment, so the pin cannot be read back to a release and Dependabot has nothing to update"
            fi
        done < "$workflow"
    done
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
            wasmtime-*.tar.xz)
                # Wasmtime has no version file in the tree. Its anchor is the
                # table's own last column, checked by the version-in-tree
                # scan below and by the checksum file.
                ;;
            *)
                # A family with no version file is pinned by the shell
                # assignment in the last column, and that assignment is what
                # a script or workflow fetching the artifact reads. An empty
                # one means nothing states where this version comes from, and
                # a new family would reach this loop with no arm at all.
                [[ -n "$anchor" ]] \
                    || fail "$name is in the artifact table with an empty version anchor; give it one or name a version file"
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
                *)
                    # A pinned name this scan cannot read a version out of, so
                    # a stale repeat of it would pass unnoticed.
                    fail "${manifest#"$ROOT"/}: $found matches no artifact name in the table; the scan cannot read a version from it"
                    ;;
            esac
        done < <(grep -rhoE '(zig|wasmtime)[a-zA-Z0-9._-]*\.tar\.xz' "$manifest" || true)
    done
}

# Every uv- or pipx-installed tool is pinned to the version declared here, so a
# lint run cannot pick up a different release than the one the config was
# written for. Both spellings are accepted: the workflows install yamllint with
# pipx (the runner image ships pipx and no uv), and the local instructions use
# `uv tool install`. Neither is allowed to leave the version off the spec.
check_tool_pins() {
    local workflow line spec
    for workflow in "$ROOT"/.github/workflows/*.yml; do
        [[ -f "$workflow" ]] || continue
        while IFS= read -r line; do
            # $line is `N:<indent>...` from grep -n. Drop the number first, then
            # the YAML list item and indentation, so a comment is recognised as
            # one whether it is the whole line or the value of a `run:` key: a
            # comment may name either spelling while explaining the choice, and
            # only a real command line can install anything.
            line="${line#*:}"
            line="${line#"${line%%[![:space:]]*}"}"
            line="${line#- }"
            line="${line#"${line%%[![:space:]]*}"}"
            [[ "$line" == "#"* ]] && continue
            line="${line#run: }"
            # A spec written as `yamllint==$(bash scripts/deps.sh yamllint-version)`
            # reads this file's own pin back through the subcommand, so it is
            # the pin, and comparing it against the pin it expanded from would
            # fail every run on a literal that is not a version. The pin is
            # still checked: this function is what the caller of that
            # subcommand is, and the literal form below is still required to
            # match. What is refused is an unexpanded shell substitution in the
            # version, which would let anything in the environment name a
            # different linter than the one the config was written for.
            # shellcheck disable=SC2016  # the literal text, not an expansion
            if [[ "$line" == *'yamllint==$('*')'* ]]; then
                case "$line" in
                    *'yamllint==$(bash scripts/deps.sh yamllint-version)'*) ;;
                    *) fail "${workflow#"$ROOT"/}: expands the yamllint pin through something other than 'bash scripts/deps.sh yamllint-version': $line" ;;
                esac
                continue
            fi
            spec=""
            case "$line" in
                *"uv tool install"*)
                    spec="$(printf '%s' "$line" | sed -n 's/.*uv tool install "\([^"]*\)".*/\1/p')"
                    if [[ -z "$spec" ]]; then
                        spec="$(printf '%s' "$line" | sed -n 's/.*uv tool install \(.*\)/\1/p')"
                    fi
                    ;;
                *"pipx install"*)
                    spec="$(printf '%s' "$line" | sed -n 's/.*pipx install \(--global \)\?"\([^"]*\)".*/\2/p')"
                    if [[ -z "$spec" ]]; then
                        spec="$(printf '%s' "$line" | sed -n 's/.*pipx install \(--global \)\?\([^"]*\).*/\2/p')"
                    fi
                    ;;
                *) continue ;;
            esac
            [[ "$spec" == "yamllint==${YAMLLINT_VERSION}" ]] || fail \
                "${workflow#"$ROOT"/}: installs '$spec', deps.sh pins yamllint==${YAMLLINT_VERSION}"
        done < <(grep -nE 'uv tool install|pipx install' "$workflow" || true)
    done
}

# The Swift toolchain is declared in .swift-version and repeated in two
# places per workflow: every setup-swift step, and the tag of a swift: job
# container, and once more in the FROM of each Dockerfile. CI and the images
# must build with the declared version, so a bump that misses any of those
# spellings has to fail here rather than on the runner. A container job or an
# image is the worse half to miss, because nothing in it reads the pin back.
check_pinned_swift_versions() {
    local declared workflow image pinned
    declared="$(tr -d '[:space:]' < "$ROOT/.swift-version")"
    for workflow in "$ROOT"/.github/workflows/*.yml; do
        [[ -f "$workflow" ]] || continue
        while IFS= read -r pinned; do
            if [[ "$pinned" != "$declared" ]]; then
                fail "${workflow#"$ROOT"/} pins setup-swift to $pinned, .swift-version says $declared"
            fi
        done < <(sed -n 's/^[[:space:]]*swift-version:[[:space:]]*"\([^"]*\)".*/\1/p' "$workflow")
        while IFS= read -r pinned; do
            if [[ "$pinned" != "$declared" ]]; then
                fail "${workflow#"$ROOT"/} runs a swift:$pinned job container, .swift-version says $declared"
            fi
        done < <(sed -n 's/^[[:space:]]*container:[[:space:]]*swift:\([0-9][0-9.]*\).*$/\1/p' "$workflow")
    done
    for image in "$ROOT/Dockerfile" "$ROOT/Dockerfile.arch"; do
        [[ -f "$image" ]] || continue
        while IFS= read -r pinned; do
            if [[ "$pinned" != "$declared" ]]; then
                fail "${image#"$ROOT"/} builds FROM swift:$pinned, .swift-version says $declared"
            fi
        done < <(sed -n 's/^[[:space:]]*FROM[[:space:]]\{1,\}swift:\([0-9][0-9.]*\).*$/\1/p' "$image")
    done
}

# SwiftPM pins the whole tree by commit revision, so an unpinned pin means a
# build that resolves a different source than the one reviewed.
check_swiftpm_pins() {
    local resolved="$ROOT/Package.resolved"
    if [[ ! -f "$resolved" ]]; then
        # Package.swift declares its dependencies per platform, and SwiftPM
        # writes no lockfile for a manifest that declares none. The Linux arm
        # declares no package, so an absent Package.resolved is the correct
        # state there and failing on it turns the lint job permanently red. A
        # platform whose arm does declare packages still has to carry one.
        if [[ "$(manifest_declarations | wc -l)" -eq 0 ]]; then
            return
        fi
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
        check_swiftpm_license "$identity"
    done < <(swiftpm_pins)
    check_swiftpm_license_spelling
    check_swiftpm_pin_spelling
    check_swiftpm_declarations
}

# Every pin's grant, in both directions. A pin with no row is third-party code
# SwiftPM compiles into the shipped binary whose licence nobody recorded, and a
# row with no pin is a licence on record for code that is no longer there. One
# gate on both, so neither drift is something a reader has to notice.
check_swiftpm_license() {
    local identity="$1" license
    if ! license="$(swiftpm_license "$identity")"; then
        fail "SwiftPM pin $identity has no row in SWIFTPM_LICENSES; add the SPDX id its LICENSE grants, read at the pinned revision"
        return
    fi
    assert_json_safe "swiftpm license" "$license"
}

# A row naming a pin Package.resolved does not carry. Removing a dependency
# leaves its licence behind otherwise, and the inventory keeps claiming a
# grant for code no build links.
check_swiftpm_license_spelling() {
    local identity license
    while IFS='|' read -r identity license; do
        [[ -n "$identity" ]] || continue
        if [[ -z "$license" ]]; then
            fail "SWIFTPM_LICENSES row $identity has no SPDX id; an unpinned licence is not a licence"
            continue
        fi
        if ! swiftpm_pins | awk -F'\t' -v i="$identity" '$1 == i { found = 1 } END { exit !found }'; then
            fail "SWIFTPM_LICENSES names $identity, which Package.resolved does not pin"
        fi
        assert_json_safe "swiftpm license" "$license"
    done <<<"$SWIFTPM_LICENSES"
}

# swiftpm_declared() reads one spelling: .package(url: "...", .exact("x")) with
# the url and the version on the same line. A version range, a branch, or a
# revision writes the pin in some other spelling, and then the declaration is
# not in the list the cross-check below compares against, so the cross-check
# runs over an empty set and passes: an unpinned dependency, in a tree whose
# only claim is that its pins were reviewed. A count of declarations alone
# cannot see it either, so the declarations are read here and named, and the
# count is against the rows the reader actually produced. Comment lines go
# first, because prose about a package is not a declaration, and the file is
# joined into a single line so a call broken across lines is still one
# declaration to report.
check_swiftpm_pin_spelling() {
    local code declaration total parsed
    code="$(manifest_declarations_joined)"
    total="$(printf '%s' "$code" | grep -oE '\.package\([[:space:]]*url:' | wc -l || true)"
    parsed="$(swiftpm_declared | wc -l || true)"
    while IFS= read -r declaration; do
        [[ -n "$declaration" ]] || continue
        if [[ "$declaration" != *'.exact('* ]]; then
            fail "Package.swift declares ${declaration} with no inline .exact(\"version\") pin"
        fi
    done < <(printf '%s' "$code" | grep -oE '\.package\([[:space:]]*url:[[:space:]]*"[^"]*"[^)]*\)' || true)
    if [[ "$parsed" -ne "$total" ]]; then
        fail "Package.swift has $total .package(url:) declaration(s) and the pin reader sees $parsed; keep the url and its .exact(\"version\") on one line"
    fi
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

# url|version for every .package(url:, .exact()) the platform compiles out of
# Package.swift. The manifest gates its dependency list on the platform, so the
# swift-cross-ui package sits in an arm a Linux build never compiles: reading the
# file as plain text would report that dependency on Linux, where SwiftPM
# resolves nothing and writes no lockfile. Dropping the #else arm of the one
# `#if os(Linux)` block on Linux reads the manifest the way the platform does.
manifest_declarations() {
    if [[ "$(uname -s)" != Linux ]]; then
        manifest_package_lines <"$ROOT/Package.swift"
        return
    fi
    manifest_source | manifest_package_lines
}

# The same platform-filtered source as manifest_declarations, with the comment
# lines dropped and the rest joined, so a declaration broken across lines is
# still one declaration to count.
manifest_source() {
    if [[ "$(uname -s)" != Linux ]]; then
        cat "$ROOT/Package.swift"
        return
    fi
    awk '
        /^#if /   { arm = "if"; next }
        /^#else/  { arm = "else"; next }
        /^#endif/ { arm = ""; next }
        arm == "else" { next }
        { print }
    ' "$ROOT/Package.swift"
}

manifest_declarations_joined() {
    manifest_source | grep -v '^[[:space:]]*//' | tr '\n' ' ' || true
}

manifest_package_lines() {
    sed -n 's/.*\.package(url:[[:space:]]*"\([^"]*\)"[[:space:]]*,[[:space:]]*\.exact("\([^"]*\)").*/\1\t\2/p'
}

# identity|version|url for every .package(url:, .exact()) in Package.swift.
# SwiftPM derives a package identity from the URL by dropping the scheme and
# the .git suffix, and by lowercasing what is left, so this reads the same key
# Package.resolved records: a URL whose last component has capitals in it still
# matches the pin instead of reporting one that is not there. A declaration
# spelled any other way never reaches this function, and
# check_swiftpm_pin_spelling() is what makes that fail rather than pass.
swiftpm_declared() {
    local url version identity
    while IFS=$'\t' read -r url version; do
        [[ -n "$url" ]] || continue
        identity="${url##*/}"
        identity="${identity%.git}"
        identity="$(printf '%s' "$identity" | tr '[:upper:]' '[:lower:]')"
        printf '%s\t%s\t%s\n' "$identity" "$version" "$url"
    done < <(manifest_declarations)
}

# identity|version|location|revision, one per pin, tab separated. SwiftPM
# writes no revision for a branch or a plain range, so that column is empty
# and the check has to reject it.
#
# Two rules keep every pin in the inventory. A record ends when the next one
# begins, so the last one needs an END flush: without it the final pin leaves
# the check, the count, and the SBOM. And the file carries a top-level
# "version" (its format number) at two spaces, where a pin's keys sit at six
# and its state at eight, so a key rule has to match an indented line or that
# number lands on the last pin as its version.
swiftpm_pins() {
    # A platform that resolves no packages has no lockfile, and the reader has
    # to say so with no rows rather than an awk error on a missing path. The
    # gate that needs a lockfile says so itself, in check_swiftpm_pins.
    [[ -f "$ROOT/Package.resolved" ]] || return 0
    awk '
        function flush() {
            if (identity != "") {
                printf "%s\t%s\t%s\t%s\n", identity, version, location, revision
            }
            identity = ""; version = ""; revision = ""; location = ""
        }
        /^   +"identity"/ { flush(); identity = value() }
        /^   +"location"/ { location = value() }
        /^   +"revision"/ { revision = value() }
        /^   +"version"/  { version = value() }
        END { flush() }
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
    check_flatpak_platform
    check_urls
    check_version_anchors
    check_artifact_versions_in_tree
    check_tool_pins
    check_action_pins
    check_pinned_swift_versions
    check_swiftpm_pins
    if [[ "$FAILURES" -ne 0 ]]; then
        echo "deps: $FAILURES problem(s) with third-party pins" >&2
        return 1
    fi
    echo "deps: pins ok ($(parse_checksums | awk -F'\t' '$1 == "OK"' | wc -l) artifacts, $(vendored_paths | wc -l) vendored, $(swiftpm_pins | wc -l) SwiftPM pins, $(flatpak_platform_rows | wc -l) runtimes)"
}

# Epoch seconds to ISO 8601 UTC. GNU date takes `-d @epoch`; BSD (macOS) has
# no `-d` and takes `-r epoch`. Probe the GNU spelling, fall back to BSD.
epoch_iso8601() {
    local epoch="$1" out
    if out="$(date -u -d "@${epoch}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"; then
        printf '%s\n' "$out"
        return 0
    fi
    date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ
}

# CycloneDX 1.5. No scanner, no network: the inventory is read out of the
# files that already decide what gets fetched.
run_sbom() {
    local out="$1"
    local name version purl url hash row
    local epoch timestamp app_version
    epoch="${SOURCE_DATE_EPOCH:-0}"
    [[ "$epoch" =~ ^[0-9]+$ ]] || epoch=0
    timestamp="$(epoch_iso8601 "$epoch")"
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
        components+=("$(artifact_component "$name" "$version" "$purl" "$url" "$hash" SHA-256 "$(artifact_arch_qualifier "$name" "$url")")")
    done < <(parse_checksums | awk -F'\t' '$1 == "OK" { print $2 }' | sort)

    local identity rev location purl license
    while IFS=$'\t' read -r identity version location rev; do
        [[ -n "$identity" ]] || continue
        if [[ -z "$rev" ]]; then
            fail "cannot build SBOM: $identity has no pinned revision"
            return 1
        fi
        # The licence is what the package grants at the revision being shipped,
        # not a guess from its owner: it is the field a compliance reader opens
        # this file for, and it comes from SWIFTPM_LICENSES, which `check`
        # keeps in step with the pins.
        if ! license="$(swiftpm_license "$identity")"; then
            fail "cannot build SBOM: $identity has no recorded SPDX licence"
            return 1
        fi
        assert_json_safe "sbom swiftpm identity" "$identity"
        assert_json_safe "sbom swiftpm version" "$version"
        assert_json_safe "sbom swiftpm location" "$location"
        assert_json_safe "sbom swiftpm license" "$license"
        purl="$(swiftpm_purl "$location")"
        assert_json_safe "sbom swiftpm purl" "$purl"
        components+=("$(swiftpm_component "$identity" "$version" "$purl" "$location" "$rev" "$license")")
    done < <(swiftpm_pins | sort)

    # The runtime the Flatpak bundle carries, which the other two loops cannot
    # see: it is neither a download this tree pins nor a file it vendors. It
    # ships in the bundle, so an inventory that stops at the toolchain and the
    # vendored font reports a bundle that is mostly somebody else's software as
    # if it were only ours.
    local platform platform_branch
    while IFS=$'\t' read -r platform platform_branch; do
        [[ -n "$platform" ]] || continue
        assert_json_safe "sbom runtime name" "$platform"
        assert_json_safe "sbom runtime version" "$platform_branch"
        components+=("$(platform_component "$platform" "$platform_branch")")
    done < <(flatpak_platform_rows)

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

# The purl a consumer matches a Swift package by, without its version, which
# artifact_component appends. It carries the host and the owner as well as the
# package name: pkg:swift/swift-log names no source to fetch, and two packages
# called swift-log under different owners would carry the same purl, so the
# inventory would list one component twice and a scanner would read the first.
# The location is the source SwiftPM resolved the pin from, so the namespace
# is read out of it rather than kept in a second table that could disagree.
swiftpm_purl() {
    local namespace="${1#https://}"
    namespace="${namespace%.git}"
    namespace="${namespace%/}"
    printf 'pkg:swift/%s' "$namespace"
}

# One release of an artifact is fetched once per architecture, and every other
# field a purl carries is the same for both. Without the qualifier the two rows
# have one purl, and a consumer that matches on it holds whichever row it read
# first, with the digest of the other architecture's file. How a download site
# spells an architecture is not one vocabulary: a tarball carries it in its own
# name, and download.swift.org names the aarch64 build in the release path and
# leaves the x86_64 one unnamed. Both spellings are named here rather than
# guessed at, and a row that matches neither gets no qualifier, which
# testSBOMPurlsAreUnique fails on when the two rows then collide.
artifact_arch_qualifier() {
    case "$1 $2" in
        *aarch64*|*arm64*) printf '?arch=aarch64' ;;
        *x86_64*|*amd64*|*/ubuntu2204/*) printf '?arch=x86_64' ;;
        *) printf '' ;;
    esac
}

artifact_component() {
    local name="$1" version="$2" purl="$3" url="$4" hash="$5" alg="$6" qualifier="$7"
    printf '    {\n'
    printf '      "type": "library",\n'
    printf '      "name": "%s",\n' "$name"
    printf '      "version": "%s",\n' "$version"
    printf '      "purl": "%s@%s%s",\n' "$purl" "$version" "$qualifier"
    printf '      "hashes": [\n'
    printf '        { "alg": "%s", "content": "%s" }\n' "$alg" "$hash"
    printf '      ],\n'
    printf '      "externalReferences": [\n'
    printf '        { "type": "distribution", "url": "%s" }\n' "$url"
    printf '      ]\n'
    printf '    }'
}

# A Swift package: artifact_component's shape, plus the SPDX licence, because
# unlike a downloaded toolchain this code is compiled into the binary the
# release ships, so its grant travels with it the way the vendored font's does.
swiftpm_component() {
    local name="$1" version="$2" purl="$3" url="$4" rev="$5" license="$6"
    printf '    {\n'
    printf '      "type": "library",\n'
    printf '      "name": "%s",\n' "$name"
    printf '      "version": "%s",\n' "$version"
    printf '      "purl": "%s@%s",\n' "$purl" "$version"
    printf '      "hashes": [\n'
    printf '        { "alg": "SHA-1", "content": "%s" }\n' "$rev"
    printf '      ],\n'
    printf '      "licenses": [\n'
    printf '        { "license": { "id": "%s" } }\n' "$license"
    printf '      ],\n'
    printf '      "externalReferences": [\n'
    printf '        { "type": "distribution", "url": "%s" }\n' "$url"
    printf '      ]\n'
    printf '    }'
}

# A Flatpak runtime: the branch the manifest names, and no hash. A branch is
# not a digest, and nothing in this tree can produce one, so a hash field here
# would be a number nobody could check against the bytes in the bundle. The
# branch is recorded as a property instead, which is the difference a consumer
# needs: a component that says how it is pinned can be resolved and compared,
# and one that quietly carries no hash looks like an omission.
platform_component() {
    local name="$1" branch="$2" purl
    purl="pkg:generic/$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')@${branch}"
    printf '    {\n'
    printf '      "type": "library",\n'
    printf '      "name": "%s",\n' "$name"
    printf '      "version": "%s",\n' "$branch"
    printf '      "purl": "%s",\n' "$purl"
    printf '      "properties": [\n'
    printf '        { "name": "appattic:pinned-by", "value": "branch" }\n'
    printf '      ],\n'
    printf '      "externalReferences": [\n'
    printf '        { "type": "distribution", "url": "https://flathub.org/apps/%s" }\n' "$name"
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
