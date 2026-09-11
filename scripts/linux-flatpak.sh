#!/usr/bin/env bash
# Build a user Flatpak of the Qt 6 Linux UI (org.appattic.AppAttic).
# Needs flatpak-builder and org.kde.Sdk (Qt 6). Exit 3 on Darwin.
# Usage: bash scripts/linux-flatpak.sh
set -euo pipefail

_script_dir="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$_script_dir/.." && pwd)"
cd "$ROOT"
export LC_ALL=C
export LANG=C
export TZ=UTC

for arg in "$@"; do
    case "$arg" in
        -h|--help)
            cat <<'EOF'
Usage: bash scripts/linux-flatpak.sh

  Needs Linux, flatpak-builder, and org.kde.Platform/Sdk (default 6.10).
  Installs the SDK from Flathub if it is missing.
  Writes dist/AppAttic.flatpak and runs --smoke inside the sandbox.
EOF
            exit 0
            ;;
        *)
            echo "error: unknown argument: $arg" >&2
            echo "Usage: bash scripts/linux-flatpak.sh" >&2
            echo "       bash scripts/linux-flatpak.sh --help" >&2
            exit 2
            ;;
    esac
done

OS="$(uname -s)"
ARCH="$(uname -m)"
if [[ "$OS" != Linux ]]; then
    echo "blocked: not Linux ($OS $ARCH). Flatpak is a Linux package." >&2
    exit 3
fi

APP_ID="org.appattic.AppAttic"
KDE_RUNTIME="${KDE_RUNTIME:-6.10}"
MANIFEST="$ROOT/packaging/flatpak/${APP_ID}.yml"
DIST="$ROOT/dist"
WORK="$DIST/flatpak-work"
STATE="$DIST/flatpak-state"
REPO="$DIST/flatpak-repo"
BUILD="$DIST/flatpak-build"
BUNDLE="$DIST/AppAttic.flatpak"
EXTRA="$DIST/flatpak-extra"

# shellcheck source=verify-sha256.sh
. "$_script_dir/verify-sha256.sh"

if [[ ! -f "$MANIFEST" ]]; then
    echo "error: missing $MANIFEST" >&2
    exit 1
fi

command -v flatpak >/dev/null 2>&1 || {
    echo "error: flatpak missing" >&2
    echo "Arch: pacman -S flatpak flatpak-builder" >&2
    exit 2
}
command -v flatpak-builder >/dev/null 2>&1 || {
    echo "error: flatpak-builder missing" >&2
    echo "Arch: pacman -S flatpak-builder" >&2
    exit 2
}
command -v rsync >/dev/null 2>&1 || {
    echo "error: rsync missing" >&2
    exit 2
}

ensure_kde_sdk() {
    if flatpak info "org.kde.Sdk//${KDE_RUNTIME}" >/dev/null 2>&1 \
        && flatpak info "org.kde.Platform//${KDE_RUNTIME}" >/dev/null 2>&1; then
        echo "runtime: org.kde.Platform ${KDE_RUNTIME}"
        return 0
    fi
    echo "installing org.kde.Platform/${KDE_RUNTIME} and Sdk from Flathub…"
    if ! flatpak remote-list --columns=name | grep -qx flathub; then
        flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
    fi
    if ! flatpak install -y --user flathub \
        "org.kde.Platform//${KDE_RUNTIME}" \
        "org.kde.Sdk//${KDE_RUNTIME}"; then
        flatpak install -y flathub \
            "org.kde.Platform//${KDE_RUNTIME}" \
            "org.kde.Sdk//${KDE_RUNTIME}"
    fi
}

ensure_kde_sdk

prefetch_archive() {
    local name="$1"
    local url="$2"
    local dest="$EXTRA/$name"
    local expected
    expected="$(checksum_for "$name")" || {
        echo "error: no pinned SHA-256 for $name" >&2
        exit 1
    }
    if [[ -f "$dest" ]] && [[ "$(file_sha256 "$dest")" == "$expected" ]]; then
        echo "cached $name"
        return 0
    fi
    echo "fetching $name…"
    rm -f "$dest"
    curl_fetch "$url" "$dest"
    verify_sha256 "$dest" "$expected"
}

case "$ARCH" in
    x86_64|amd64) FP_ARCH=x86_64 ;;
    aarch64|arm64) FP_ARCH=aarch64 ;;
    *)
        echo "error: unsupported ARCH=$ARCH" >&2
        exit 2
        ;;
esac
mkdir -p "$EXTRA"
if [[ "$FP_ARCH" == x86_64 ]]; then
    prefetch_archive "wasmtime-v28.0.0-x86_64-linux-c-api.tar.xz" \
        "https://github.com/bytecodealliance/wasmtime/releases/download/v28.0.0/wasmtime-v28.0.0-x86_64-linux-c-api.tar.xz"
    prefetch_archive "zig-x86_64-linux-0.16.0.tar.xz" \
        "https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz"
else
    prefetch_archive "wasmtime-v28.0.0-aarch64-linux-c-api.tar.xz" \
        "https://github.com/bytecodealliance/wasmtime/releases/download/v28.0.0/wasmtime-v28.0.0-aarch64-linux-c-api.tar.xz"
    prefetch_archive "zig-aarch64-linux-0.16.0.tar.xz" \
        "https://ziglang.org/download/0.16.0/zig-aarch64-linux-0.16.0.tar.xz"
fi

echo "staging sources in $WORK"
rm -rf "$WORK"
mkdir -p "$WORK"
rsync -a \
    --exclude '.git/' \
    --exclude '.build/' \
    --exclude '.deps/' \
    --exclude 'dist/' \
    --exclude '.zig-cache/' \
    --exclude '.zig-cache-local/' \
    --exclude 'ui/linux-qt/build/' \
    --exclude 'ui/linux-qt/build-release/' \
    "$ROOT/" "$WORK/"

if ! grep -q "runtime-version: \"${KDE_RUNTIME}\"" "$WORK/packaging/flatpak/${APP_ID}.yml"; then
    echo "error: manifest runtime-version is not ${KDE_RUNTIME}" >&2
    exit 1
fi

mkdir -p "$DIST"
rm -rf "$BUILD"
echo "flatpak-builder: ${APP_ID}"
# rofiles-fuse leftover mounts from a killed build fail the next run.
if mountpoint -q "$STATE/rofiles" 2>/dev/null; then
    fusermount3 -u "$STATE/rofiles" 2>/dev/null || fusermount -u "$STATE/rofiles" 2>/dev/null || true
fi
find "$STATE" -maxdepth 2 -type d -name 'rofiles-*' 2>/dev/null | while read -r mp; do
    fusermount3 -u "$mp" 2>/dev/null || fusermount -u "$mp" 2>/dev/null || true
done

flatpak-builder \
    --user \
    --force-clean \
    --disable-rofiles-fuse \
    --install \
    --state-dir "$STATE" \
    --repo "$REPO" \
    --extra-sources "$EXTRA" \
    "$BUILD" \
    "$WORK/packaging/flatpak/${APP_ID}.yml"

rm -f "$BUNDLE"
echo "bundle: $BUNDLE"
flatpak build-bundle "$REPO" "$BUNDLE" "$APP_ID"
if [[ ! -f "$BUNDLE" ]]; then
    echo "error: bundle not created: $BUNDLE" >&2
    exit 1
fi

export APPATTIC_HOST_EXEC_FIXTURE=1
export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-offscreen}"
echo "smoke: QT_QPA_PLATFORM=$QT_QPA_PLATFORM flatpak run $APP_ID --smoke"
set +e
dump="$(flatpak run --command=appattic-qt "$APP_ID" --smoke 2>&1)"
rc=$?
set -e
printf '%s\n' "$dump"
if [[ $rc -ne 0 ]] || ! printf '%s\n' "$dump" | grep -q '^SMOKE=ok$'; then
    echo "error: Flatpak --smoke failed" >&2
    exit 1
fi

echo "Flatpak: $BUNDLE"
echo "app-id: $APP_ID"
echo "run:    flatpak run $APP_ID"
echo "install from bundle: flatpak install --user $BUNDLE"
