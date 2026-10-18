# FloppyFox artwork

Original artwork, licensed under the repository's MIT license. The entire family
is drawn by `Tools/generate_artwork.swift`: an enamel fox emblem, graphite floppy
disks, brushed-metal hard disks, folded-paper file icons, and a compact Macintosh
welcome illustration. Transparent backgrounds work in both macOS appearances.

Regenerate the bundled PNGs from the repository root:

```sh
Tools/generate_artwork.swift resources Sources/FloppyFox/Resources/Artwork
```

The app icon and both Finder document iconsets are rendered from the same source
by `Tools/build-app.sh`. The existing `generate_icon.swift`,
`generate_doc_icon.swift`, and `generate_hd_doc_icon.swift` entry points delegate
to this renderer. `generate_classic_mac_icons.swift` is a compatibility entry
point for regenerating the bundled artwork family.

Render a review sheet without modifying the bundled assets:

```sh
Tools/generate_artwork.swift preview Build/ArtworkPreview.png
```

`FileArtwork.swift` selects file artwork using classic Finder types first, then
filename extensions. Folders use macOS's own artwork; embedded application icons
retain their original classic Mac pixels.
