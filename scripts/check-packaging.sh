#!/usr/bin/env bash
# Check the shipped packaging metadata against itself: the desktop entry, the
# AppStream metainfo, the man page, the Flatpak manifest, and the Qt install
# that ships them. Nothing here builds or fetches: a Flatpak or an AppImage is
# expensive to produce, so this is the gate that catches a desktop entry whose
# Exec names a binary the install does not produce, a metainfo id that no
# longer matches the Flatpak app-id, or a launchable that names a desktop file
# nobody installs.
# Runs from scripts/lint.sh, so CI blocks on it.
# Usage: bash scripts/check-packaging.sh
set -euo pipefail

_script_dir="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$_script_dir/.." && pwd)"
cd "$ROOT"
export LC_ALL=C
export LANG=C
export TZ=UTC

case "${1:-}" in
    -h|--help)
        cat <<'EOF'
Usage: bash scripts/check-packaging.sh

  Desktop entry, AppStream metainfo, man page, Flatpak manifest, and the
  Qt install rules, checked against each other. Runs desktop-file-validate
  when it is on PATH. No network, no build.
EOF
        exit 0
        ;;
    "")
        ;;
    *)
        echo "error: unknown argument: $1" >&2
        echo "Usage: $0" >&2
        echo "       $0 --help" >&2
        exit 2
        ;;
esac

APP_ID="org.appattic.AppAttic"
DESKTOP="packaging/${APP_ID}.desktop"
METAINFO="packaging/${APP_ID}.metainfo.xml"
MANPAGE="packaging/appattic-qt.1"
MANIFEST="packaging/flatpak/${APP_ID}.yml"
CMAKE="ui/linux-qt/CMakeLists.txt"
MAIN="ui/linux-qt/main.cpp"

fail() {
    echo "error: $1" >&2
    exit 1
}

# The first value of a desktop key, or nothing. Anchored so a commented-out
# or repeated key cannot stand in for the live one.
desktop_value() {
    sed -n "s/^$1=//p" "$DESKTOP" | head -n 1
}

# The first element text of a metainfo element that sits on one line.
metainfo_text() {
    sed -n "s/.*<$1>\\(.*\\)<\\/$1>.*/\\1/p" "$METAINFO" | head -n 1
}

# Whether an element is there at all, for one whose text spans lines.
metainfo_has() {
    grep -q "<$1>" "$METAINFO"
}

# Every file the shipped metadata refers to has to exist before any of it can
# be compared, so a missing one is named instead of read as an empty value.
for required in "$DESKTOP" "$METAINFO" "$MANPAGE" "$MANIFEST" "$CMAKE" "$MAIN"; do
    [[ -f "$required" ]] || fail "missing $required"
done

# The app id is declared in three places: the Flatpak manifest, the metainfo
# id, and the name of the desktop file they both resolve against. A software
# centre looks metainfo up by the id and the desktop file by its own name, so
# one rename that misses the other two hides the metadata.
manifest_app_id="$(sed -n 's/^app-id:[[:space:]]*//p' "$MANIFEST" | head -n 1)"
metainfo_id="$(metainfo_text id)"
[[ "$manifest_app_id" == "$APP_ID" ]] \
    || fail "$MANIFEST declares app-id $manifest_app_id, the name every other packaging file uses is $APP_ID"
[[ "$metainfo_id" == "$manifest_app_id" ]] \
    || fail "$METAINFO declares id $metainfo_id, $MANIFEST declares app-id $manifest_app_id"
[[ "$metainfo_id" == "$(basename "$DESKTOP" .desktop)" ]] \
    || fail "$METAINFO declares id $metainfo_id, but the desktop file is $(basename "$DESKTOP" .desktop)"

# AppStream's launchable is the desktop file the store launches. Naming one
# that is not the file that ships leaves the listing without a way to start it.
launchable="$(sed -n 's/.*<launchable type="desktop-id">\(.*\)<\/launchable>.*/\1/p' "$METAINFO" | head -n 1)"
[[ "$launchable" == "$(basename "$DESKTOP")" ]] \
    || fail "$METAINFO launchable is '$launchable', the desktop file that ships is $(basename "$DESKTOP")"

# AppStream requires these; a missing one is rejected by appstream-util and
# rejected by nothing here, so it is named. <description> runs over several
# lines, so it is checked as a tag.
for element in name summary metadata_license project_license; do
    [[ -n "$(metainfo_text "$element")" ]] || fail "$METAINFO has no <$element>"
done
metainfo_has description || fail "$METAINFO has no <description>"

# Exec names a binary the install has to produce. A desktop entry that names
# something cmake never installs shows up in a menu and does nothing.
exec_name="$(desktop_value Exec)"
[[ -n "$exec_name" ]] || fail "$DESKTOP has no Exec="
case "$exec_name" in
    */*) fail "$DESKTOP Exec=$exec_name is a path; a desktop entry names a binary on PATH" ;;
    *) ;;  # a bare name, checked against the install rules below
esac
grep -qE "install\(TARGETS[[:space:]]+${exec_name}[[:space:]]" "$CMAKE" \
    || fail "$DESKTOP runs $exec_name, which $CMAKE does not install"
manifest_command="$(sed -n 's/^command:[[:space:]]*//p' "$MANIFEST" | head -n 1)"
[[ "$manifest_command" == "$exec_name" ]] \
    || fail "$MANIFEST command is '$manifest_command', $DESKTOP runs $exec_name"

# Icon names a file that has to reach an icon theme directory, or the entry
# renders as a generic placeholder on a machine that never saw the AppDir.
icon_name="$(desktop_value Icon)"
[[ -n "$icon_name" ]] || fail "$DESKTOP has no Icon="
[[ -f "packaging/${icon_name}.svg" ]] \
    || fail "$DESKTOP Icon=$icon_name, but packaging/${icon_name}.svg is not in the tree"
grep -q "packaging/${icon_name}\.svg" "$CMAKE" \
    || fail "$DESKTOP Icon=$icon_name, but $CMAKE never installs packaging/${icon_name}.svg"

# flatpak-builder rewrites the exported entry to Icon=<app-id> and renames the
# icon to match. Without rename-icon the Flatpak exports an entry pointing at
# an icon name the prefix does not have.
manifest_rename_icon="$(sed -n 's/^rename-icon:[[:space:]]*//p' "$MANIFEST" | head -n 1)"
if [[ "$icon_name" != "$APP_ID" ]]; then
    [[ "$manifest_rename_icon" == "$APP_ID" ]] \
        || fail "$MANIFEST has no rename-icon: $APP_ID, which the desktop entry's Icon=$icon_name needs"
fi

# Qt publishes this as GTK_APPLICATION_ID and KDE_NET_WM_DESKTOP_FILE, and a
# Wayland compositor reads it as the app id, so the name the window carries has
# to be the desktop file that installs. Anything else leaves the window without
# a taskbar icon on every platform, and the two names live in different files.
window_desktop_file="$(sed -n 's/.*setDesktopFileName(QStringLiteral("\([^"]*\)")).*/\1/p' \
    "$MAIN" | head -n 1)"
[[ -n "$window_desktop_file" ]] || fail "$MAIN has no setDesktopFileName"
[[ "$window_desktop_file" == "$(basename "$DESKTOP" .desktop)" ]] \
    || fail "the window names desktop file '$window_desktop_file', the one that ships is $(basename "$DESKTOP" .desktop)"

# Qt derives WM_CLASS from the setDesktopFileName name when that is set, so the
# window's WM_CLASS is that basename, not the executable. An X11 panel matches
# StartupWMClass against it to group the window and pick its icon, so a stale
# value leaves the taskbar entry with no icon and no grouping while the file
# still validates. Tying it to the basename the check above already ties to the
# code is what keeps the two from disagreeing.
startup_wm_class="$(desktop_value StartupWMClass)"
[[ -n "$startup_wm_class" ]] || fail "$DESKTOP has no StartupWMClass"
[[ "$startup_wm_class" == "$window_desktop_file" ]] \
    || fail "$DESKTOP StartupWMClass=$startup_wm_class, but the window reports WM_CLASS=$window_desktop_file"

# The binary ships a man page, so the install has to ship it: a page that only
# exists in the repository documents an installed command that has none.
grep -q "$MANPAGE" "$CMAKE" \
    || fail "$MANPAGE is not installed by $CMAKE, so $exec_name ships with no man page"

# Every metadata file the AppImage script copies has to be in the tree. It
# fails the build on a missing desktop entry or icon, but the metainfo copy is
# guarded, so a renamed file silently ships without it.
for copied in "$DESKTOP" "$METAINFO" "packaging/appattic.svg"; do
    grep -q "$copied" scripts/linux-appimage.sh \
        || fail "scripts/linux-appimage.sh no longer copies $copied into the AppImage"
done

# The zsync transport makes AppImageUpdate download the URL in the update
# information and read a zsync header from it, so that URL has to name the
# .zsync the release workflow publishes beside the image. Pointed at the image
# itself, every update check parses a squashfs as a zsync header and fails,
# and the image still builds, so nothing else in this tree notices. The URL is
# a shell expansion, so the check is that it is built from the .zsync path.
update_url="$(sed -n 's/^UPDATE_URL=//p' scripts/linux-appimage.sh | head -n 1)"
[[ -n "$update_url" ]] || fail "scripts/linux-appimage.sh has no UPDATE_URL"
# shellcheck disable=SC2016  # the literal source text, not an expansion
[[ "$update_url" == *'${UPDATE_ZSYNC#'* ]] \
    || fail "scripts/linux-appimage.sh builds UPDATE_URL from the image, not from UPDATE_ZSYNC"

# The AppImage bundles no shell, so AppRun runs under whatever /bin/sh the
# user's machine has. A bash shebang or a bashism there makes the image refuse
# to start on a host with no bash, and the CI --smoke cannot see it: that runs
# on the build host, which has bash. The body is the heredoc patch_apprun
# writes, between the here-document opener and its terminator.
appimage_script="scripts/linux-appimage.sh"
apprun_body="$(sed -n "/^    cat > \"\$apprun\" <<'EOF'$/,/^EOF$/p" "$appimage_script" | sed '1d;$d')"
[[ -n "$apprun_body" ]] || fail "$appimage_script has no AppRun here-document, so patch_apprun ships nothing"
apprun_shebang="$(printf '%s\n' "$apprun_body" | sed -n '1p')"
[[ "$apprun_shebang" == "#!/bin/sh" ]] \
    || fail "the AppRun $appimage_script writes starts with '$apprun_shebang', not #!/bin/sh; the image bundles no shell, so it runs under the host's /bin/sh"
if command -v shellcheck >/dev/null 2>&1; then
    # SC1090 is the dynamic `. "$hook"`, which is the point of the loop.
    if ! apprun_out="$(printf '%s\n' "$apprun_body" | shellcheck -s sh -e SC1090 - 2>&1)"; then
        printf '%s\n' "$apprun_out" | sed 's/^/error: /' >&2
        fail "the AppRun $appimage_script writes is not POSIX sh"
    fi
else
    echo "note: shellcheck not found, the AppRun body was not checked for bashisms" >&2
fi

if command -v desktop-file-validate >/dev/null 2>&1; then
    if ! validate_out="$(desktop-file-validate "$DESKTOP" 2>&1)"; then
        printf '%s\n' "$validate_out" | sed 's/^/error: /' >&2
        fail "$DESKTOP does not validate"
    fi
    if [[ -n "$validate_out" ]]; then
        # Hints are advisory and print here rather than failing: a category
        # that could carry a second main category is a placement choice, and
        # $DESKTOP records the one it made.
        printf '%s\n' "$validate_out" | sed 's/^/note: /' >&2
    fi
else
    echo "note: desktop-file-validate not found, the desktop entry was not validated" >&2
fi

echo "packaging metadata: ok ($APP_ID, $(basename "$DESKTOP"), $(basename "$MANPAGE"))"
