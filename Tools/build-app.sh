#!/usr/bin/env bash
set -euo pipefail
# build-app.sh: Builds the FloppyFox app bundle and generates an .icns icon
OUTDIR=./Build/FloppyFox.app
ICONSET=./Build/FloppyFox.iconset
ICON=./Build/FloppyFox.icns

rm -rf "$OUTDIR" "$ICONSET" "$ICON"

echo "Building release executable..."
swift build -c release
BIN=.build/release/FloppyFox

if [ ! -f "$BIN" ]; then
  echo "Built binary not found at $BIN"
  exit 1
fi

mkdir -p "$OUTDIR/Contents/MacOS"
cp "$BIN" "$OUTDIR/Contents/MacOS/FloppyFox"

mkdir -p "$ICONSET"
echo Generating iconset...
Tools/generate_icon.swift "$ICONSET"

if [ ! -d "$ICONSET" ]; then
  echo "Iconset not created"
  exit 1
fi

iconutil -c icns "$ICONSET" -o "$ICON"

mkdir -p "$OUTDIR/Contents/Resources"
cp "$ICON" "$OUTDIR/Contents/Resources/AppIcon.icns"

# SwiftPM keeps processed assets and the bundled help README in a companion resource bundle.
# Preserve it inside the application so `Bundle.module` works in packaged release builds too.
RESOURCE_BUNDLE=$(find .build -path '*/release/FloppyFox_FloppyFox.bundle' -type d -print -quit)
if [ -n "$RESOURCE_BUNDLE" ]; then
  cp -R "$RESOURCE_BUNDLE" "$OUTDIR/Contents/Resources/"
fi

cat > "$OUTDIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>FloppyFox</string>
  <key>CFBundleIdentifier</key>
  <string>com.example.FloppyFox</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>FloppyFox</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>NSHumanReadableCopyright</key>
  <string>(C) 2026 Anders Muskens</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon.icns</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key>
      <string>HFS Disk Image</string>
      <key>CFBundleTypeRole</key>
      <string>Editor</string>
      <key>LSHandlerRank</key>
      <string>Alternate</string>
      <key>CFBundleTypeExtensions</key>
      <array>
        <string>dsk</string>
        <string>img</string>
        <string>hda</string>
        <string>vhd</string>
      </array>
      <key>CFBundleTypeIconFile</key>
      <string>AppIcon.icns</string>
    </dict>
  </array>
</dict>
</plist>
PLIST

echo Built app bundle at $OUTDIR
chmod +x "$OUTDIR/Contents/MacOS/FloppyFox"
