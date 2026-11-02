#!/bin/bash
# Build Splitvox and install the resulting app bundle in /Applications.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Splitvox.app"
SOURCE_APP="$ROOT/$APP_NAME"
DESTINATION="${SPLITVOX_INSTALL_DIR:-/Applications}"
INSTALLED_APP="$DESTINATION/$APP_NAME"

if ! mkdir -p "$DESTINATION" 2>/dev/null || [[ ! -w "$DESTINATION" ]]; then
    echo "Cannot write to install directory: $DESTINATION" >&2
    echo "Set SPLITVOX_INSTALL_DIR to a writable directory, for example \"$HOME/Applications\"." >&2
    exit 1
fi

echo "==> Building app bundle…"
bash "$ROOT/scripts/make-app.sh"

if [[ ! -d "$SOURCE_APP" ]]; then
    echo "Build did not produce $SOURCE_APP" >&2
    exit 1
fi

echo "==> Installing to ${INSTALLED_APP}…"
STAGING_APP="$DESTINATION/.$APP_NAME.installing-$$"
BACKUP_APP="$DESTINATION/.$APP_NAME.backup-$$"
cleanup() {
    rm -rf "$STAGING_APP"
    if [[ -d "$BACKUP_APP" && ! -e "$INSTALLED_APP" ]]; then
        mv "$BACKUP_APP" "$INSTALLED_APP"
    fi
}
trap cleanup EXIT

rm -rf "$STAGING_APP" "$BACKUP_APP"
ditto "$SOURCE_APP" "$STAGING_APP"

if [[ -e "$INSTALLED_APP" ]]; then
    mv "$INSTALLED_APP" "$BACKUP_APP"
fi

if ! mv "$STAGING_APP" "$INSTALLED_APP"; then
    echo "Install failed; restoring previous app." >&2
    exit 1
fi

rm -rf "$BACKUP_APP"
trap - EXIT
echo "==> Installed $INSTALLED_APP"
echo "    Run with: open \"$INSTALLED_APP\""
