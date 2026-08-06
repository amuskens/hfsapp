# FloppyFox

A macOS app project for browsing and editing Apple HFS disk images (`.hda`,`.dsk` and `.img`). It's especially designed for exploring and modifying disk images that are used by the Classic Mac OS, alongisde emulators and devices like the BlueSCSI. 

It allows you to:

- open HFS disk image files
- mount the image in read/write mode using `hdiutil`
- explore folders and files inside the volume
- delete files and folders inside the image
- add files by dragging from Finder into the app
- copy files from the mounted volume using the clipboard or by dragging from Finder into the app
- export selected files and folders from the volume to the host filesystem

## Prerequisites

- Xcode 15+ or newer
- macOS 13+


## Make a donation

If you like the app and like these types of projects, please make a donation here:
https://www.andersmuskens.com/donate
Thank you for your support!

## Run locally

```bash
swift build
swift run
```

If the command line tools are not using the full Xcode SDK, run tests with:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

## Structure

- `Sources/HFSApp/` contains the app entry point and HFS disk image manager
- `Package.swift` defines the macOS platform target and test target
