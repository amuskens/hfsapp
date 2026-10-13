#!/usr/bin/env bash
set -euo pipefail
# build-app.sh: builds Build/FloppyFox.app (universal, sandboxed) and optionally signs it for
# distribution.
#
#   VERSION=1.0 BUILD_NUMBER=7 ./Tools/build-app.sh          ad-hoc signed local build
#   RELEASE_CHANNEL=beta ...                                   shows "beta" in About
#   SIGN_IDENTITY="Developer ID Application: …" [NOTARY_PROFILE=…]   notarized, outside the store
#   DISTRIBUTION=appstore SIGN_IDENTITY="Apple Distribution: …" \
#     INSTALLER_IDENTITY="3rd Party Mac Developer Installer: …" \
#     PROVISIONING_PROFILE=path/to/FloppyFox.provisionprofile ./Tools/build-app.sh
#                                                              Build/FloppyFox.pkg for App Store Connect
VERSION=${VERSION:-0.1}
BUILD_NUMBER=${BUILD_NUMBER:-1}
RELEASE_CHANNEL=${RELEASE_CHANNEL:-}
BUNDLE_ID=com.andersmuskens.FloppyFox
ENTITLEMENTS=Tools/FloppyFox.entitlements
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
# The App Store requires a privacy manifest declaring why "required reason" APIs are used.
cp Tools/PrivacyInfo.xcprivacy "$OUTDIR/Contents/Resources/"
# SwiftPM leaves the bundle without an Info.plist (or with one naming an executable it doesn't
# have); App Store validation wants every nested bundle identified, and resources-only.
cat > "$OUTDIR/Contents/Resources/FloppyFox_FloppyFox.bundle/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID.resources</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>FloppyFox Resources</string>
  <key>CFBundlePackageType</key>
  <string>BNDL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
</dict>
</plist>
PLIST

# The build environment, as Xcode records it (App Store Connect reads these).
SDK_VERSION=$(xcrun --sdk macosx --show-sdk-version)
SDK_BUILD=$(xcrun --sdk macosx --show-sdk-build-version)
XCODE_VERSION=$(xcodebuild -version | awk '/^Xcode/ { split($2, v, "."); printf "%d%d%d", v[1], v[2], (v[3] == "" ? 0 : v[3]) }')
XCODE_BUILD=$(xcodebuild -version | awk '/^Build version/ { print $3 }')
OS_BUILD=$(sw_vers -buildVersion)

cat > "$OUTDIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>BuildMachineOSBuild</key>
  <string>$OS_BUILD</string>
  <key>CFBundleSupportedPlatforms</key>
  <array>
    <string>MacOSX</string>
  </array>
  <key>DTCompiler</key>
  <string>com.apple.compilers.llvm.clang.1_0</string>
  <key>DTPlatformBuild</key>
  <string>$SDK_BUILD</string>
  <key>DTPlatformName</key>
  <string>macosx</string>
  <key>DTPlatformVersion</key>
  <string>$SDK_VERSION</string>
  <key>DTSDKBuild</key>
  <string>$SDK_BUILD</string>
  <key>DTSDKName</key>
  <string>macosx$SDK_VERSION</string>
  <key>DTXcode</key>
  <string>$XCODE_VERSION</string>
  <key>DTXcodeBuild</key>
  <string>$XCODE_BUILD</string>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>FloppyFox</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>FloppyFox</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>FloppyFoxReleaseChannel</key>
  <string>$RELEASE_CHANNEL</string>
  <key>ITSAppUsesNonExemptEncryption</key>
  <false/>
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
        <string>image</string>
        <string>dc42</string>
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

if [ "${DISTRIBUTION:-}" = "appstore" ]; then
  : "${SIGN_IDENTITY:?Set SIGN_IDENTITY to your Apple Distribution signing identity}"
  : "${INSTALLER_IDENTITY:?Set INSTALLER_IDENTITY to your 3rd Party Mac Developer Installer identity}"
  : "${PROVISIONING_PROFILE:?Set PROVISIONING_PROFILE to the Mac App Store provisioning profile of the app}"
  cp "$PROVISIONING_PROFILE" "$OUTDIR/Contents/embedded.provisionprofile"

  # App Store builds must carry the application and team identifiers from the profile.
  PROFILE_PLIST=$(mktemp)
  MERGED_ENTITLEMENTS=$(mktemp)
  security cms -D -i "$PROVISIONING_PROFILE" > "$PROFILE_PLIST"
  cp "$ENTITLEMENTS" "$MERGED_ENTITLEMENTS"
  for key in com.apple.application-identifier com.apple.developer.team-identifier; do
    value=$(/usr/libexec/PlistBuddy -c "Print :Entitlements:$key" "$PROFILE_PLIST")
    /usr/libexec/PlistBuddy -c "Add :$key string $value" "$MERGED_ENTITLEMENTS"
  done

  echo "Signing for the Mac App Store with: $SIGN_IDENTITY"
  codesign --force --sign "$SIGN_IDENTITY" --entitlements "$MERGED_ENTITLEMENTS" "$OUTDIR"
  codesign --verify --deep --strict --verbose=2 "$OUTDIR"
  rm -f "$PROFILE_PLIST" "$MERGED_ENTITLEMENTS"

  PKG=./Build/FloppyFox.pkg
  rm -f "$PKG"
  productbuild --component "$OUTDIR" /Applications --sign "$INSTALLER_IDENTITY" "$PKG"
  echo "Built $PKG — upload it with Transporter, or:"
  echo "  xcrun altool --upload-app -t macos -f $PKG --apiKey <key id> --apiIssuer <issuer id>"
  exit 0
fi

# Signing and notarization only run when the caller opts in. Otherwise the app is ad-hoc
# signed with its sandbox entitlements, so local builds run under the same App Sandbox as
# the store build and sandbox problems show up during development.
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
  codesign --force --sign - --entitlements "$ENTITLEMENTS" "$OUTDIR"
  echo "SIGN_IDENTITY not set; ad-hoc signed with the sandbox entitlements (not distributable)."
  echo "Set SIGN_IDENTITY=\"Developer ID Application: Your Name (TEAMID)\" to sign,"
  echo "and NOTARY_PROFILE=<keychain profile name> to also notarize."
fi
