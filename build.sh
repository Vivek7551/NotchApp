#!/bin/bash
# Builds NotchApp.app into ./build.
#   ./build.sh          debug build
#   ./build.sh run      debug build, then (re)launch the app
#   CONFIG=release ./build.sh
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="NotchApp"
CONFIG="${CONFIG:-debug}"
APP="build/$APP_NAME.app"

# Now Playing helper (only rebuilt when missing)
ADAPTER="Vendor/build/MediaRemoteAdapter.framework"
[[ -d "$ADAPTER" ]] || Vendor/build-adapter.sh

swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp -R "$ADAPTER" "$APP/Contents/Frameworks/"
cp Vendor/mediaremote-adapter/bin/mediaremote-adapter.pl "$APP/Contents/Resources/"
cp Vendor/mediaremote-adapter/LICENSE "$APP/Contents/Resources/mediaremote-adapter-LICENSE.txt"

# Code signing. macOS remembers permissions (Accessibility, Full Disk Access)
# per signing identity. An ad-hoc signature ("-") changes on every build, so
# macOS forgets those permissions after each rebuild. If you have a real
# certificate (e.g. "Apple Development" from Xcode), we use it instead.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Apple Development|NotchApp/ { print $2; exit }')}"
IDENTITY="${IDENTITY:--}"

# Sign the inside first, then the app.
codesign --force --sign "$IDENTITY" "$APP/Contents/Frameworks/MediaRemoteAdapter.framework"
codesign --force --sign "$IDENTITY" "$APP"
echo "✅ Built $APP"
if [[ "$IDENTITY" == "-" ]]; then
    echo "⚠️  Ad-hoc signed: Accessibility / Full Disk Access must be re-granted after each rebuild."
else
    echo "🔏 Signed with: $IDENTITY"
fi

if [[ "${1:-}" == "run" ]]; then
    pkill -x "$APP_NAME" 2>/dev/null || true
    sleep 1 # give macOS a moment to fully quit the old copy
    open "$APP"
    echo "🚀 Launched $APP_NAME"
fi
