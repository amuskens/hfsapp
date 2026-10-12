# FloppyFox

A macOS app project for browsing and editing Apple HFS disk images (`.hda`, `.dsk`, `.img`, and `.vhd`). It's especially designed for exploring and modifying disk images that are used by the Classic Mac OS, alongside emulators and devices like the BlueSCSI.

It allows you to:

- open classic HFS volumes: floppy images, partitioned hard-disk images (BlueSCSI `.hda`),
  and fixed or dynamic VHD containers
- explore folders and files inside the volume
- copy, move and delete files and folders inside the image
- add files by dragging from Finder or pasting; MacBinary `.bin` files are unpacked
- copy files out by dragging, the clipboard, or Export, with resource forks and Finder
  type/creator preserved

FloppyFox reads and writes HFS with its own engine (`Sources/FloppyFox/HFS/`): no `hdiutil`
mounts and no external tools, so it runs inside the App Sandbox and can ship on the Mac App
Store. Mac OS Extended (HFS+) volumes aren't supported yet.

## Prerequisites

- Xcode 15 or newer, including the Xcode Command Line Tools
- macOS 13+
- [Visual Studio Code](https://code.visualstudio.com/) and the official
  [Swift extension](https://marketplace.visualstudio.com/items?itemName=swiftlang.swift-vscode)
  if you want to work in VS Code


## Make a donation

If you like the app and like these types of projects, please make a donation here:
https://www.andersmuskens.com/donate
Thank you for your support!

## Open and build in VS Code

1. Install Xcode and launch it once to accept its license and install any required components.
2. Install Visual Studio Code.
3. In VS Code, install the official **Swift** extension published by Swift Server Work Group.
4. Open the FloppyFox repository folder using **File > Open Folder**, or from Terminal:

```bash
cd /path/to/hfsapp
code .
```

VS Code should recognize `Package.swift` automatically and resolve the Swift package. You can
build from the Command Palette with **Swift: Build Package**, or use the integrated terminal:

```bash
swift build
```

To build and immediately run the development version:

```bash
swift run
```

You can also select the `FloppyFox` executable in VS Code's **Run and Debug** view and start it
with F5. If source indexing is still in progress, allow SourceKit-LSP to finish before debugging.

Run the test suite with:

```bash
swift test
```

The app itself needs nothing installed, but the tests use
[hfsutils](https://www.mars.org/home/rob/proj/hfs/) (`brew install hfsutils`) as an
independent oracle: `hformat` builds throwaway volumes, and `hls`/`hcopy` read results back.
Tests that need it are skipped when it's missing.

- **Unit tests** (`ParsingTests`, `RobustnessTests`) cover name conversion and ordering,
  subprocess plumbing, and fuzzed VHD and resource-fork input.
- **Engine tests** (`HFSEngineTests`) drive `HFSVolume` directly: multi-level catalog growth,
  extents-overflow files, large allocation blocks, cancelled writes, corrupted images.
- **App tests** (`DiskImageManagerTests`) cover what the window does: import, export,
  copy/cut/paste, delete, read-only cases and cancellation.

Every test that writes a volume also runs Apple's `fsck_hfs -n` on the result. It checks
B-tree structure, catalog key order, valences, the allocation bitmap and the MDB totals.

Set `FLOPPYFOX_REAL_HDA=/path/to/image.hda` to also edit a clone of a real Mac OS-written
hard-disk image and fsck it (the original is never modified).

If the command-line tools are not using the full Xcode SDK, specify it explicitly:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

## Build the macOS application bundle

To create a release build at `Build/FloppyFox.app`, run:

```bash
./Tools/build-app.sh
```

Open the resulting application directly with:

```bash
open Build/FloppyFox.app
```

`VERSION`, `BUILD_NUMBER` and `RELEASE_CHANNEL` (shown in About, e.g. `beta`) set the version.
Without a signing identity the app is ad-hoc signed with its sandbox entitlements, so local
builds run under the same App Sandbox as the store build.

For the Mac App Store, create the app record and a Mac App Store provisioning profile for
`com.andersmuskens.FloppyFox` in your developer account, then:

```bash
DISTRIBUTION=appstore VERSION=1.0 BUILD_NUMBER=1 \
  SIGN_IDENTITY="Apple Distribution: Your Name (TEAMID)" \
  INSTALLER_IDENTITY="3rd Party Mac Developer Installer: Your Name (TEAMID)" \
  PROVISIONING_PROFILE=path/to/FloppyFox.provisionprofile \
  ./Tools/build-app.sh
```

This produces `Build/FloppyFox.pkg`; upload it with Transporter. For direct distribution
outside the store, set `SIGN_IDENTITY` to a Developer ID identity and `NOTARY_PROFILE` to a
notarytool keychain profile instead.

## Structure

- `Sources/FloppyFox/HFS/` is the HFS engine: image layouts (partition maps, DiskCopy 4.2,
  VHD), the master directory block, B-trees, allocation, and MacBinary
- `Sources/FloppyFox/DiskImageManager.swift` is the app's model: opening images, browsing,
  import/export, clipboard and progress
- `Sources/FloppyFox/ContentView.swift` and `HFSApp.swift` are the SwiftUI interface and menus
- `Tools/` has the build script, sandbox entitlements and icon generators
- `Package.swift` defines the macOS platform target and test target
