# FloppyFox

FloppyFox is a macOS app for browsing and editing Apple HFS disk images (`.hda`, `.dsk`, `.img`, `.image`, and `.vhd`). It is designed for exploring and modifying disk images used by Classic Mac OS, emulators, and devices such as BlueSCSI.

FloppyFox reads and writes HFS volumes itself. It doesn't mount images in macOS and needs no other software.

## Features

- Open classic HFS (Mac OS Standard) volumes: floppy images, partitioned hard-disk images such as BlueSCSI `.hda` files, and fixed or dynamic VHD containers.
- Browse folders and files in list or icon view.
- Add files and folders by dragging from Finder or pasting from the clipboard. MacBinary (`.bin`) files are unpacked automatically.
- Copy files and folders to Finder using drag and drop, the clipboard, or Export. Resource forks and Finder type/creator codes come along, so classic applications keep working when copied back.
- Copy, move, and delete files and folders inside writable images.
- Inspect classic Finder attributes, data forks, and resource forks.

Long-running file operations display a progress panel. Choose **Cancel** or press Escape to stop. Items that finished copying are kept; the one in progress is discarded.

## Basic use

1. Choose **Open Image** and select a supported disk image.
2. Double-click folders to browse them, or use **Up** and the path menu.
3. Drag files between FloppyFox and Finder, or use Cut, Copy, and Paste.
4. Right-click in the browser to create a folder or access file operations.
5. Choose **Eject** before using the image in an emulator or copying it to a device.

## Read-only images

Some images open read-only. FloppyFox tells you why when it opens one:

- The image file's permissions don't allow writing, or the volume itself is locked.
- Another program, such as an emulator, has the image open.
- Dynamic VHD and DiskCopy 4.2 images: changes can't be written back to these containers.

## Not supported yet

- Mac OS Extended (HFS+) volumes, used by Mac OS 8.1 and later.
- When a hard-disk image has several HFS partitions, only the first one is shown.

## Support

If you enjoy FloppyFox and similar preservation projects, donations are welcome:

https://www.andersmuskens.com/donate

## Credits

(C) 2026 Anders Muskens

AI agent assistance: ChatGPT and Claude.
