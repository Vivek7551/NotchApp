#!/bin/bash
# Compiles MediaRemoteAdapter.framework from Vendor/mediaremote-adapter
# (https://github.com/ungive/mediaremote-adapter, BSD-3-Clause) with clang,
# so we don't need cmake. Output: Vendor/build/MediaRemoteAdapter.framework
set -euo pipefail
cd "$(dirname "$0")"

SRC="mediaremote-adapter"
OUT="build/MediaRemoteAdapter.framework"
# The exact version NotchApp was tested with.
ADAPTER_COMMIT="73f14ab1568371e6e3c44063f21c34c5e2712c4d"

# Download the adapter's source (not stored in this repo) if it isn't here yet.
if [[ ! -f "$SRC/bin/mediaremote-adapter.pl" ]]; then
    rm -rf "$SRC"
    git init -q "$SRC"
    git -C "$SRC" fetch -q --depth 1 https://github.com/ungive/mediaremote-adapter.git "$ADAPTER_COMMIT"
    git -C "$SRC" checkout -q FETCH_HEAD
fi

rm -rf "$OUT"
mkdir -p "$OUT/Versions/A/Resources"

clang -dynamiclib -fobjc-arc -fvisibility=default -O2 \
    -arch arm64 -arch x86_64 -mmacosx-version-min=14.0 \
    -I"$SRC/include" -I"$SRC/src" \
    "$SRC"/src/adapter/*.m "$SRC"/src/private/MediaRemote.m "$SRC"/src/utility/*.m \
    -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
    -install_name @rpath/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter \
    -o "$OUT/Versions/A/MediaRemoteAdapter"

cat > "$OUT/Versions/A/Resources/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleExecutable</key><string>MediaRemoteAdapter</string>
    <key>CFBundleIdentifier</key><string>com.vandenbe.MediaRemoteAdapter</string>
    <key>CFBundleName</key><string>MediaRemoteAdapter</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>0.1.0</string>
</dict></plist>
PLIST

# Standard framework symlinks
ln -sfh A "$OUT/Versions/Current"
ln -sfh Versions/Current/MediaRemoteAdapter "$OUT/MediaRemoteAdapter"
ln -sfh Versions/Current/Resources "$OUT/Resources"

codesign --force --sign - "$OUT"
echo "✅ Built $OUT"
