#!/bin/bash
# The installer image: one page, the app on the left and an Applications
# shortcut on the right, over dmg/background.png.
#
#   ./scripts/make-dmg.sh                       # dist/macSteam-<version>.dmg
#   ./scripts/make-dmg.sh path/to/macSteam.dmg  # somewhere else
#
# Uses create-dmg (brew install create-dmg) for the layout; without it the
# image still gets the app and the shortcut, just no background.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/macSteam.app"
BACKGROUND="$ROOT/dmg/background.png"

VERSION="$(sed -n 's/^#define MACSTEAM_VERSION "\(.*\)"/\1/p' "$ROOT/src/version.h")"
OUT="${1:-$ROOT/dist/macSteam-${VERSION:-app}.dmg}"

if [ ! -d "$APP" ]; then
    echo "error: $APP is missing; run ./build.sh first" >&2
    exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

ditto "$APP" "$STAGE/macSteam.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$OUT"

if command -v create-dmg >/dev/null 2>&1; then
    # create-dmg exits non-zero on some macOS versions even when the image was
    # written, so the file is what says whether it worked.
    create-dmg \
        --volname "macSteam" \
        --background "$BACKGROUND" \
        --window-pos 200 120 \
        --window-size 600 400 \
        --icon-size 100 \
        --icon "macSteam.app" 175 190 \
        --hide-extension "macSteam.app" \
        --app-drop-link 425 190 \
        "$OUT" \
        "$STAGE" || true
fi

if [ ! -f "$OUT" ]; then
    echo "create-dmg unavailable or failed; writing a plain image" >&2
    rm -f "$STAGE/Applications"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname "macSteam" -srcfolder "$STAGE" -ov -format UDZO "$OUT"
fi

echo "created: $OUT"
