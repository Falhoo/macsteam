#!/bin/bash
# The installer package: the app, into /Applications, for people who would rather
# click through Installer than drag it out of the disk image.
#
#   ./scripts/make-pkg.sh                        # dist/macSteam-<version>.pkg
#   ./scripts/make-pkg.sh path/to/macSteam.pkg   # somewhere else
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/macSteam.app"

VERSION="$(sed -n 's/^#define MACSTEAM_VERSION "\(.*\)"/\1/p' "$ROOT/src/version.h")"
OUT="${1:-$ROOT/dist/macSteam-${VERSION:-app}.pkg}"

if [ ! -d "$APP" ]; then
    echo "error: $APP is missing; run ./build.sh first" >&2
    exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# pkgbuild places this root's contents in the install location, so the payload is
# /Applications/macSteam.app once it is installed.
mkdir -p "$STAGE/Applications"
ditto "$APP" "$STAGE/Applications/macSteam.app"
rm -f "$OUT"

pkgbuild \
    --root "$STAGE" \
    --identifier "com.macsteam.app" \
    --version "${VERSION:-1.0}" \
    --install-location "/" \
    "$OUT"

echo "created: $OUT"
