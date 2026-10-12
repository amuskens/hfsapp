# FloppyFox

A macOS app project for browsing and editing Apple HFS disk images (`.hda`, `.dsk`, `.img`, and `.vhd`). It's especially designed for exploring and modifying disk images that are used by the Classic Mac OS, alongside emulators and devices like the BlueSCSI.

It allows you to:

- open HFS disk image files, including raw `.vhd` images and fixed or dynamic VHD containers
- mount the image in read/write mode using `hdiutil`
- explore folders and files inside the volume
- delete files and folders inside the image
- add files by dragging from Finder into the app
- copy files from the mounted volume using the clipboard or by dragging from Finder into the app
- export selected files and folders from the volume to the host filesystem

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

The suite has three tiers:

- **Unit tests** (`ParsingTests`, parts of `RobustnessTests`) cover hfsutils output parsing,
  name conversion, hfs:// pseudo-URLs, and fuzzed VHD/resource-fork input. They need nothing
  installed.
- **Integration tests** (`HFSUtilsBackendTests`, `MountedBackendTests`) build throwaway disk
  images: classic HFS with hfsutils' `hformat`, HFS+ with `hdiutil create`. After each
  operation they eject and check the image file itself with hfsutils, so a change only counts
  if it actually reached the disk. The hfsutils tests are skipped unless hfsutils is
  installed (`brew install hfsutils`).
- **Real-image tests** (in `HFSAppTests`) run against period disk images that aren't in the
  repository. Put `HD1 BlueSCSI Bootstrap.hda`, `StuffIt Deluxe 3.0.7 Disk 1.dsk`,
  `StuffIt Deluxe 3.0.7 Disk 2.dsk` and `boot.vhd` in the repo root (they're gitignored), and
  set `FLOPPYFOX_VHD_FIXTURE=/path/to/image.vhd` for the VHD tests. Tests whose image is
  missing are skipped.

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

The local build script does not currently apply a Developer ID signature or submit the app for
Apple notarization. An app intended for distribution must be signed and notarized separately.

## Structure

- `Sources/HFSApp/` contains the app entry point and HFS disk image manager
- `Package.swift` defines the macOS platform target and test target
