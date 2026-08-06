# FloppyFox

FloppyFox is a macOS app for browsing and editing Apple HFS disk images (`.hda`, `.dsk`, `.img`, and `.vhd`). It is designed for exploring and modifying disk images used by Classic Mac OS, emulators, and devices such as BlueSCSI.

## Features

- Open HFS disk images, including raw `.vhd` images and fixed or dynamic VHD containers.
- Browse folders and files in list or icon view.
- Add files and folders by dragging from Finder or pasting from the clipboard.
- Copy files and folders to Finder using drag and drop or the clipboard.
- Create and delete folders and files inside writable images.
- Export selected files and folders to the host filesystem.
- Inspect classic Finder attributes, data forks, and resource forks.

Long-running file operations display a progress panel. Choose **Cancel** or press Escape to stop after the current file operation finishes safely.

## Basic use

1. Choose **Open Image** and select a supported disk image.
2. Double-click folders to browse them, or use **Up** and the path menu.
3. Drag files between FloppyFox and Finder, or use Cut, Copy, and Paste.
4. Right-click in the browser to create a folder or access file operations.
5. Choose **Eject** before moving or replacing an image that was opened read/write.

Some images cannot be mounted directly by macOS. FloppyFox automatically uses hfsutils as a fallback when available.

## Prerequisites

- macOS 13 or newer.
- hfsutils is recommended for disk images macOS cannot mount directly.

## Building in Visual Studio Code

Install Xcode and its Command Line Tools, Visual Studio Code, and the official **Swift** extension published by Swift Server Work Group. Open the repository using **File > Open Folder**, or run:

```bash
cd /path/to/hfsapp
code .
```

VS Code recognizes `Package.swift` as a Swift package. Use **Swift: Build Package** from the Command Palette, or use the integrated terminal:

```bash
swift build
swift run
swift test
```

To create the release application at `Build/FloppyFox.app`, run:

```bash
./Tools/build-app.sh
open Build/FloppyFox.app
```

This local application bundle is not signed or notarized for public distribution.

## Support

If you enjoy FloppyFox and similar preservation projects, donations are welcome:

https://www.andersmuskens.com/donate

## Credits

(C) 2026 Anders Muskens

AI agent assistance: ChatGPT and Claude.
