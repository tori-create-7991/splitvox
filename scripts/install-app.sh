#!/bin/bash
# Build Splitvox and install the resulting app bundle in /Applications.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Splitvox.app"
SOURCE_APP="$ROOT/$APP_NAME"
DESTINATION="${SPLITVOX_INSTALL_DIR:-/Applications}"
INSTALLED_APP="$DESTINATION/$APP_NAME"
BUILD_LOCK="$ROOT/.build/.install-app.lock"
INSTALL_LOCK="$DESTINATION/.$APP_NAME.install-lock"
STAGING_APP=""
BACKUP_APP=""
build_locked=false
install_locked=false

cleanup() {
    local status=$?
    trap - EXIT
    if [[ -n "$STAGING_APP" ]]; then rm -rf "$STAGING_APP"; fi
    if [[ -n "$BACKUP_APP" && -d "$BACKUP_APP" && ! -e "$INSTALLED_APP" ]]; then
        if ! mv "$BACKUP_APP" "$INSTALLED_APP"; then
            echo "Restore failed; previous app remains at $BACKUP_APP" >&2
            status=1
        fi
    fi
    if $install_locked; then rmdir "$INSTALL_LOCK"; fi
    if $build_locked; then rmdir "$BUILD_LOCK"; fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if ! mkdir -p "$DESTINATION" 2>/dev/null || [[ ! -w "$DESTINATION" ]]; then
    echo "Cannot write to install directory: $DESTINATION" >&2
    echo "Set SPLITVOX_INSTALL_DIR to a writable directory, for example \"$HOME/Applications\"." >&2
    exit 1
fi

# Hold both locks across building and replacing the bundle. Never remove a
# pre-existing lock: it may belong to another invocation or a failed install.
mkdir -p "$ROOT/.build"
if ! mkdir "$BUILD_LOCK" 2>/dev/null; then
    echo "Build is locked: $BUILD_LOCK (inspect the owning install before retrying)." >&2
    exit 1
fi
build_locked=true
if ! mkdir "$INSTALL_LOCK" 2>/dev/null; then
    echo "Install is locked: $INSTALL_LOCK (inspect the owning install before retrying)." >&2
    exit 1
fi
install_locked=true

echo "==> Building app bundle…"
bash "$ROOT/scripts/make-app.sh"

if [[ ! -d "$SOURCE_APP" ]]; then
    echo "Build did not produce $SOURCE_APP" >&2
    exit 1
fi

echo "==> Installing to ${INSTALLED_APP}…"
STAGING_APP="$DESTINATION/.$APP_NAME.installing-$$"
BACKUP_APP="$DESTINATION/.$APP_NAME.backup-$$"
rm -rf "$STAGING_APP" "$BACKUP_APP"
ditto "$SOURCE_APP" "$STAGING_APP"
if [[ ! -x "$STAGING_APP/Contents/MacOS/Splitvox" ]]; then
    echo "Staged app has no executable: $STAGING_APP" >&2
    exit 1
fi
codesign --verify --deep --strict "$STAGING_APP"

if [[ -e "$INSTALLED_APP" ]]; then
    mv "$INSTALLED_APP" "$BACKUP_APP"
fi

if ! mv "$STAGING_APP" "$INSTALLED_APP"; then
    echo "Install failed; restoring previous app." >&2
    exit 1
fi

rm -rf "$BACKUP_APP"
echo "==> Installed $INSTALLED_APP"
echo "    Run with: open \"$INSTALLED_APP\""
