#!/bin/bash
# The OnlineFix Manager part of the macSteam build: installs its resources (the
# injected dylib, 7-Zip and the Steam compatibility profiles) into the assembled
# app, so My Games and Add Game work after one build.
#
#   ./scripts/build-onlinefix.sh "/path/to/macSteam.app"
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ $# -lt 1 ]; then
    echo "usage: $0 <path to the .app>" >&2
    exit 1
fi

APP="$1"
RES="$APP/Contents/Resources"
SRC="$ROOT/onlinefix/vendor"

[ -d "$APP" ] || { echo "error: $APP does not exist" >&2; exit 1; }
[ -d "$SRC" ] || { echo "error: $SRC is missing" >&2; exit 1; }

mkdir -p "$RES/runtime"

for res in onlinefix.dylib 7zz; do
    if [ -f "$SRC/$res" ]; then
        cp "$SRC/$res" "$RES/"
        echo "installed OnlineFix $res"
    else
        echo "warning: $SRC/$res missing" >&2
    fi
done
chmod +x "$RES/7zz" 2>/dev/null || true

if [ -d "$SRC/runtime" ]; then
    cp "$SRC"/runtime/*.json "$RES/runtime/" 2>/dev/null || true
fi

# OnlineFix's Photon patch (Custom.dll, BepInEx's preloader and the winmm doorway).
# The app adds it to a Photon game whose fix stops at the Steam API DLL.
if [ -d "$SRC/photon" ]; then
    mkdir -p "$RES/photon/BepInEx/core"
    cp "$SRC/photon/winmm.dll" "$RES/photon/" 2>/dev/null || true
    cp "$SRC/photon/Custom.dll" "$RES/photon/" 2>/dev/null || true
    cp "$SRC/photon/BepInEx/core/BepInEx.Preloader.dll" "$RES/photon/BepInEx/core/" 2>/dev/null || true
    echo "installed OnlineFix Photon patch"
fi
