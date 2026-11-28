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

# OnlineFix's Photon patch and the BepInEx chain it runs through: the plugin, both
# doorways (winhttp and winmm), the chain's config and BepInEx's whole core. A package
# that carries only the plugin and the preloader cannot load, and a doorway the game
# never imports never runs, so the app ships the complete chain.
# The autopilot that makes a game try its own online connection during an install
# test, so the player does not have to drive the menus.
if [ -d "$SRC/autopilot" ]; then
    mkdir -p "$RES/autopilot"
    rsync -a --delete "$SRC/autopilot/" "$RES/autopilot/"
    echo "installed the online test autopilot"
fi

if [ -d "$SRC/photon" ]; then
    mkdir -p "$RES/photon"
    rsync -a --delete "$SRC/photon/" "$RES/photon/"
    echo "installed OnlineFix Photon patch and its BepInEx chain"
fi
