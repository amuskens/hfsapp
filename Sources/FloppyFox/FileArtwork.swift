import AppKit

/// Fallback artwork for catalog items without an embedded classic Mac icon.
/// Finder types take precedence because classic files often have no extension.
enum FileArtwork {
    static func resourceName(name: String, finderType: String?, isDirectory: Bool) -> String? {
        guard !isDirectory else { return nil } // A folder may itself be named "Archive.img".
        switch finderType {
        case "APPL": return "Application"
        case "TEXT", "ttro", "RTF ", "WDBN", "W6BN", "PDF ": return "TextDocument"
        case "PICT", "JPEG", "TIFF", "PNGf", "GIFf", "BMPf", "8BPS": return "ImageDocument"
        case "AIFF", "AIFC", "WAVE", "Midi", "MIDI", "MPG3", "snd ", "sfil": return "AudioDocument"
        case "MooV", "MPEG", "VfW ": return "VideoDocument"
        case "SIT!", "SITD", "SIT5", "ZIP ", "ZIVU", "Gzip", "mBIN", "LHA ": return "ArchiveDocument"
        case "INIT", "cdev", "zsys", "scri", "thng": return "SystemDocument"
        case "FFIL", "LWFN", "sfnt", "tfil": return "FontDocument"
        case "rohd", "hdsk": return "HardDisk"
        default: break
        }
        switch (name as NSString).pathExtension.lowercased() {
        case "dsk", "img", "image", "dc42": return "FloppyDisk"
        case "hda", "vhd": return "HardDisk"
        case "txt", "text", "md", "rtf", "doc", "pdf", "csv", "log": return "TextDocument"
        case "pict", "pct", "pic", "png", "jpg", "jpeg", "tif", "tiff", "gif", "bmp", "psd": return "ImageDocument"
        case "aif", "aiff", "aifc", "wav", "mp3", "m4a", "mid", "midi", "snd": return "AudioDocument"
        case "mov", "mp4", "m4v", "mpg", "mpeg", "avi": return "VideoDocument"
        case "sit", "sitx", "zip", "bin", "hqx", "gz", "tar", "lha", "sea": return "ArchiveDocument"
        case "ttf", "otf", "dfont", "suit": return "FontDocument"
        case "app": return "Application"
        default: return "Document"
        }
    }

    static func image(named name: String) -> NSImage? {
        Bundle.floppyFoxResources.image(forResource: name)
    }
}
