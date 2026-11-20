#!/bin/sh
# Builds CloudRedirect's macOS runtime from the vendored upstream source and puts
# it in the app bundle, the same way CloudRedirect's own macOS app stages it:
# the injected dylib plus the CLI helpers its UI drives and the credential helper
# Steam's runtime launches.
#
#   ./scripts/build-cloudredirect.sh "/path/to/macSteam.app"
#
# Skipped (not an error) when the source or cmake is missing, so a plain build
# still works.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP="$1"
SRC="$ROOT/vendor/cloudredirect"
BUILD="$SRC/build-macos"
RES="$APP/Contents/Resources"

[ -f "$SRC/CMakeLists.txt" ] || { echo "cloudRedirect: source missing, skipping"; exit 0; }
command -v cmake >/dev/null 2>&1 || { echo "cloudRedirect: cmake missing, skipping"; exit 0; }

if [ ! -f "$SRC/vendor/dobby/CMakeLists.txt" ]; then
    ( cd "$SRC" && git -c url."https://github.com/".insteadOf=git@github.com: \
        submodule update --init --depth 1 >/dev/null 2>&1 ) || true
fi
[ -f "$SRC/vendor/dobby/CMakeLists.txt" ] || { echo "cloudRedirect: Dobby missing, skipping"; exit 0; }

cmake -S "$SRC" -B "$BUILD" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 >/dev/null
cmake --build "$BUILD" --parallel 6 >/dev/null

DYLIB="$BUILD/cloud_redirect.dylib"
[ -f "$DYLIB" ] || { echo "cloudRedirect: build produced no dylib"; exit 1; }

mkdir -p "$RES/runtime" "$RES/Licenses"
cp "$DYLIB" "$RES/cloud_redirect.dylib"
cp "$DYLIB" "$RES/runtime/cloud_redirect.dylib"
for tool in cloud_redirect_cli cloud760_tool cloud_redirect_credentials; do
    if [ -f "$BUILD/$tool" ]; then
        cp "$BUILD/$tool" "$RES/runtime/$tool"
        chmod +x "$RES/runtime/$tool"
    else
        echo "cloudRedirect: $tool missing" >&2
    fi
done

cp "$SRC/LICENSE" "$RES/Licenses/LICENSE.cloudredirect" 2>/dev/null || true
cp "$SRC/licenses/Dobby-Apache-2.0.txt" "$RES/Licenses/Dobby-Apache-2.0.cloudredirect.txt" 2>/dev/null || true

for file in "$RES/cloud_redirect.dylib" "$RES/runtime/cloud_redirect.dylib" \
            "$RES/runtime/cloud_redirect_cli" "$RES/runtime/cloud760_tool" \
            "$RES/runtime/cloud_redirect_credentials"; do
    [ -f "$file" ] && codesign -f -s - "$file" >/dev/null 2>&1 || true
done

echo "  cloudRedirect runtime: $(du -h "$DYLIB" | cut -f1)"
