#!/usr/bin/env bash
set -euo pipefail
# build-app.sh: Builds the FloppyFox app bundle and generates an .icns icon
OUTDIR=./Build/FloppyFox.app
ICONSET=./Build/FloppyFox.iconset
ICON=./Build/FloppyFox.icns
DOC_ICONSET=./Build/FloppyFoxDoc.iconset
DOC_ICON=./Build/FloppyFoxDoc.icns
HD_ICONSET=./Build/FloppyFoxHDDoc.iconset
HD_ICON=./Build/FloppyFoxHDDoc.icns

rm -rf "$OUTDIR" "$ICONSET" "$ICON" "$DOC_ICONSET" "$DOC_ICON" "$HD_ICONSET" "$HD_ICON"

echo "Building universal (arm64 + x86_64) release executable..."
swift build -c release --arch arm64 --arch x86_64
PRODUCTS=.build/apple/Products/Release
BIN=$PRODUCTS/FloppyFox

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

mkdir -p "$DOC_ICONSET"
echo Generating disk image document iconset...
Tools/generate_doc_icon.swift "$DOC_ICONSET"

if [ ! -d "$DOC_ICONSET" ]; then
  echo "Document iconset not created"
  exit 1
fi

iconutil -c icns "$DOC_ICONSET" -o "$DOC_ICON"

mkdir -p "$HD_ICONSET"
echo Generating hard disk image document iconset...
Tools/generate_hd_doc_icon.swift "$HD_ICONSET"

if [ ! -d "$HD_ICONSET" ]; then
  echo "Hard disk iconset not created"
  exit 1
fi

iconutil -c icns "$HD_ICONSET" -o "$HD_ICON"

mkdir -p "$OUTDIR/Contents/Resources"
cp "$ICON" "$OUTDIR/Contents/Resources/AppIcon.icns"
cp "$DOC_ICON" "$OUTDIR/Contents/Resources/DiskImageDocument.icns"
cp "$HD_ICON" "$OUTDIR/Contents/Resources/HardDiskImageDocument.icns"

# SwiftPM keeps processed assets and the bundled help README in a companion resource bundle.
# It goes in Contents/Resources, where `Bundle.floppyFoxResources` looks for it. (SwiftPM's own
# `Bundle.module` expects it at the top level of the .app, but codesign rejects anything there:
# "unsealed contents present in the bundle root".)
RESOURCE_BUNDLE=$PRODUCTS/FloppyFox_FloppyFox.bundle
if [ ! -d "$RESOURCE_BUNDLE" ]; then
  echo "Resource bundle not found at $RESOURCE_BUNDLE"
  exit 1
fi
cp -R "$RESOURCE_BUNDLE" "$OUTDIR/Contents/Resources/"

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
  <string>com.andersmuskens.FloppyFox</string>
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
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.utilities</string>
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
      <string>HFS Floppy Disk Image</string>
      <key>CFBundleTypeRole</key>
      <string>Editor</string>
      <key>LSHandlerRank</key>
      <string>Alternate</string>
      <key>CFBundleTypeExtensions</key>
      <array>
        <string>dsk</string>
        <string>img</string>
      </array>
      <key>CFBundleTypeIconFile</key>
      <string>DiskImageDocument.icns</string>
    </dict>
    <dict>
      <key>CFBundleTypeName</key>
      <string>HFS Hard Disk Image</string>
      <key>CFBundleTypeRole</key>
      <string>Editor</string>
      <key>LSHandlerRank</key>
      <string>Alternate</string>
      <key>CFBundleTypeExtensions</key>
      <array>
        <string>hda</string>
        <string>vhd</string>
      </array>
      <key>CFBundleTypeIconFile</key>
      <string>HardDiskImageDocument.icns</string>
    </dict>
  </array>
</dict>
</plist>
PLIST

echo Built app bundle at $OUTDIR
chmod +x "$OUTDIR/Contents/MacOS/FloppyFox"

# Signing and notarization only run when the caller opts in, so plain dev builds
# (no Developer ID cert / keychain profile available) keep working untouched.
if [ -n "${SIGN_IDENTITY:-}" ]; then
  echo "Code signing with identity: $SIGN_IDENTITY"
  codesign --force --deep --options runtime --timestamp \
    --entitlements Tools/FloppyFox.entitlements \
    --sign "$SIGN_IDENTITY" "$OUTDIR"

  echo "Verifying signature..."
  codesign --verify --deep --strict --verbose=2 "$OUTDIR"

  if [ -n "${NOTARY_PROFILE:-}" ]; then
    ZIP=./Build/FloppyFox-notarize.zip
    rm -f "$ZIP"
    echo "Zipping app for notarization..."
    ditto -c -k --keepParent "$OUTDIR" "$ZIP"

    echo "Submitting to Apple notary service (this can take a few minutes)..."
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

    echo "Stapling notarization ticket..."
    xcrun stapler staple "$OUTDIR"

    rm -f "$ZIP"
  else
    echo "NOTARY_PROFILE not set; skipping notarization. Set it to notarize and staple."
  fi
else
  echo "SIGN_IDENTITY not set; skipping code signing and notarization."
  echo "Set SIGN_IDENTITY=\"Developer ID Application: Your Name (TEAMID)\" to sign,"
  echo "and NOTARY_PROFILE=<keychain profile name> to also notarize."
fi
