#!/usr/bin/env swift
import AppKit
import Foundation

// Original, resolution-independent FloppyFox artwork. Coordinates use a 512-point,
// top-left canvas. All PNGs and Finder iconsets are rendered from these same drawings.
// Usage: Tools/generate_artwork.swift resources <directory>
//        Tools/generate_artwork.swift app|floppy|hardDisk <iconset-directory>
//        Tools/generate_artwork.swift preview <png-path>

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}
func round(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: r, yRadius: r)
}
func ellipse(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSBezierPath {
    NSBezierPath(ovalIn: NSRect(x: x, y: y, width: w, height: h))
}
func fill(_ path: NSBezierPath, _ hex: UInt32, _ alpha: CGFloat = 1) {
    color(hex, alpha).setFill(); path.fill()
}
func stroke(_ path: NSBezierPath, _ hex: UInt32, _ width: CGFloat = 1, _ alpha: CGFloat = 1) {
    color(hex, alpha).setStroke(); path.lineWidth = width; path.lineCapStyle = .round; path.lineJoinStyle = .round; path.stroke()
}
func gradient(_ path: NSBezierPath, _ colors: [UInt32], angle: CGFloat = 90) {
    NSGradient(colors: colors.map { color($0) })!.draw(in: path, angle: angle)
}
func line(_ points: [(CGFloat, CGFloat)]) -> NSBezierPath {
    let p = NSBezierPath()
    for (i, v) in points.enumerated() {
        if i == 0 { p.move(to: NSPoint(x: v.0, y: v.1)) }
        else { p.line(to: NSPoint(x: v.0, y: v.1)) }
    }
    return p
}
func polygon(_ points: [(CGFloat, CGFloat)]) -> NSBezierPath {
    let p = line(points); p.close(); return p
}
func saved(_ body: () -> Void) {
    NSGraphicsContext.saveGraphicsState(); body(); NSGraphicsContext.restoreGraphicsState()
}
func shadow(_ blur: CGFloat = 14, _ y: CGFloat = 8, _ opacity: CGFloat = 0.22, _ body: () -> Void) {
    saved {
        let s = NSShadow(); s.shadowColor = color(0x172131, opacity)
        s.shadowBlurRadius = blur; s.shadowOffset = NSSize(width: 0, height: -y)
        s.set()
        NSGraphicsContext.current!.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
        body()
        NSGraphicsContext.current!.cgContext.endTransparencyLayer()
    }
}
func placed(_ x: CGFloat, _ y: CGFloat, _ scale: CGFloat, _ rotation: CGFloat = 0, _ body: () -> Void) {
    saved {
        let t = AffineTransform(translationByX: x, byY: y)
        (t as NSAffineTransform).concat()
        let r = NSAffineTransform(); r.rotate(byDegrees: rotation); r.scale(by: scale); r.concat()
        body()
    }
}
func text(_ value: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ hex: UInt32,
          weight: NSFont.Weight = .medium) {
    (value as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color(hex)
    ])
}

// A sculpted enamel fox emblem: one recognizable silhouette at every size.
func fox() {
    let face = NSBezierPath()
    face.move(to: NSPoint(x: 256, y: 157))
    face.curve(to: NSPoint(x: 157, y: 111), controlPoint1: NSPoint(x: 216, y: 143), controlPoint2: NSPoint(x: 177, y: 102))
    face.curve(to: NSPoint(x: 146, y: 246), controlPoint1: NSPoint(x: 143, y: 143), controlPoint2: NSPoint(x: 145, y: 206))
    face.curve(to: NSPoint(x: 256, y: 365), controlPoint1: NSPoint(x: 118, y: 293), controlPoint2: NSPoint(x: 215, y: 350))
    face.curve(to: NSPoint(x: 366, y: 246), controlPoint1: NSPoint(x: 297, y: 350), controlPoint2: NSPoint(x: 394, y: 293))
    face.curve(to: NSPoint(x: 355, y: 111), controlPoint1: NSPoint(x: 367, y: 206), controlPoint2: NSPoint(x: 369, y: 143))
    face.curve(to: NSPoint(x: 256, y: 157), controlPoint1: NSPoint(x: 335, y: 102), controlPoint2: NSPoint(x: 296, y: 143))
    face.close()
    shadow(12, 9, 0.25) { gradient(face, [0xffc066, 0xf58a32, 0xd9581b]) }
    stroke(face, 0xa84417, 2, 0.35)
    let leftEar = polygon([(166, 131), (212, 169), (164, 204)])
    let rightEar = polygon([(346, 131), (300, 169), (348, 204)])
    gradient(leftEar, [0x71372d, 0xc26849]); gradient(rightEar, [0x71372d, 0xc26849])
    let muzzle = NSBezierPath()
    muzzle.move(to: NSPoint(x: 148, y: 249))
    muzzle.curve(to: NSPoint(x: 256, y: 290), controlPoint1: NSPoint(x: 190, y: 229), controlPoint2: NSPoint(x: 229, y: 260))
    muzzle.curve(to: NSPoint(x: 364, y: 249), controlPoint1: NSPoint(x: 283, y: 260), controlPoint2: NSPoint(x: 322, y: 229))
    muzzle.curve(to: NSPoint(x: 256, y: 357), controlPoint1: NSPoint(x: 345, y: 306), controlPoint2: NSPoint(x: 287, y: 348))
    muzzle.curve(to: NSPoint(x: 148, y: 249), controlPoint1: NSPoint(x: 225, y: 348), controlPoint2: NSPoint(x: 167, y: 306))
    muzzle.close()
    gradient(muzzle, [0xffffff, 0xffedd3])
    for x: CGFloat in [200, 299] {
        gradient(ellipse(x, 232, 14, 21), [0x49372c, 0x1f242b])
        fill(ellipse(x + 3, 235, 4, 5), 0xffffff, 0.8)
    }
    let nose = NSBezierPath()
    nose.move(to: NSPoint(x: 240, y: 294))
    nose.curve(to: NSPoint(x: 272, y: 294), controlPoint1: NSPoint(x: 247, y: 289), controlPoint2: NSPoint(x: 265, y: 289))
    nose.curve(to: NSPoint(x: 256, y: 311), controlPoint1: NSPoint(x: 274, y: 298), controlPoint2: NSPoint(x: 261, y: 311))
    nose.curve(to: NSPoint(x: 240, y: 294), controlPoint1: NSPoint(x: 251, y: 311), controlPoint2: NSPoint(x: 238, y: 298))
    nose.close(); gradient(nose, [0x4e4944, 0x202833])
    stroke(line([(250, 295), (260, 295)]), 0xffffff, 2, 0.4)
    stroke(line([(256, 311), (256, 320)]), 0x9f6d49, 2)
    let brow = NSBezierPath()
    brow.move(to: NSPoint(x: 166, y: 121))
    brow.curve(to: NSPoint(x: 246, y: 164), controlPoint1: NSPoint(x: 197, y: 132), controlPoint2: NSPoint(x: 221, y: 156))
    stroke(brow, 0xffffff, 3, 0.32)
}

func floppy() {
    let body = NSBezierPath()
    body.move(to: NSPoint(x: 91, y: 55)); body.line(to: NSPoint(x: 372, y: 55))
    body.line(to: NSPoint(x: 432, y: 115)); body.line(to: NSPoint(x: 432, y: 429))
    body.curve(to: NSPoint(x: 412, y: 449), controlPoint1: NSPoint(x: 432, y: 441), controlPoint2: NSPoint(x: 424, y: 449))
    body.line(to: NSPoint(x: 91, y: 449))
    body.curve(to: NSPoint(x: 71, y: 429), controlPoint1: NSPoint(x: 79, y: 449), controlPoint2: NSPoint(x: 71, y: 441))
    body.line(to: NSPoint(x: 71, y: 75))
    body.curve(to: NSPoint(x: 91, y: 55), controlPoint1: NSPoint(x: 71, y: 63), controlPoint2: NSPoint(x: 79, y: 55)); body.close()
    shadow(16, 9) { gradient(body, [0x657181, 0x343f50, 0x202a39]) }
    stroke(body, 0x101c2b, 2)
    saved {
        body.addClip()
        stroke(body, 0xffffff, 5, 0.25)
        stroke(line([(80, 438), (423, 438)]), 0x030e1c, 4, 0.6)
    }
    gradient(round(134, 56, 215, 135, 9), [0x909ba8, 0xf8fafc, 0xbac4ce, 0xe6eaee], angle: 0)
    stroke(round(134, 56, 215, 135, 9), 0x1e2b3c, 1, 0.6)
    gradient(round(263, 72, 49, 98, 5), [0x111b29, 0x394557])
    stroke(round(263, 72, 49, 98, 5), 0xffffff, 1, 0.35)
    for x in stride(from: CGFloat(143), to: 250, by: 4) {
        stroke(line([(x, 62), (x, 184)]), 0xffffff, 0.5, 0.09)
    }
    fill(round(91, 81, 21, 30, 3), 0x15202e)
    stroke(line([(94, 112), (109, 112)]), 0xffffff, 1, 0.3)
    let label = round(112, 217, 279, 192, 9)
    shadow(3, 2, 0.25) { gradient(label, [0xfffef9, 0xeceae3]) }
    saved {
        label.addClip()
        gradient(round(112, 217, 279, 40, 0), [0xffae54, 0xec7830])
    }
    stroke(label, 0xffffff, 1, 0.6)
    // Embossed fox seal and restrained ruled label.
    placed(128, 265, 0.25) { fox() }
    for (y, w): (CGFloat, CGFloat) in [(293, 106), (316, 119), (339, 82)] {
        stroke(line([(242, y), (242 + w, y)]), 0x8a94a1, 3, 0.55)
    }
    stroke(line([(131, 378), (371, 378)]), 0xb9c1c8, 1.5)
    for x: CGFloat in [94, 404] {
        fill(round(x, 408, 8, 17, 2), 0x121e2d)
        stroke(line([(x + 1, 426), (x + 7, 426)]), 0xffffff, 1, 0.3)
    }
}

func screw(_ x: CGFloat, _ y: CGFloat) {
    gradient(ellipse(x - 6, y - 6, 12, 12), [0x77818b, 0xf5f7fa, 0x7b8796])
    stroke(ellipse(x - 6, y - 6, 12, 12), 0x445263, 1, 0.7)
    stroke(line([(x - 2.5, y + 2.5), (x + 2.5, y - 2.5)]), 0x48596a, 1.5)
}
func hardDisk() {
    shadow(15, 9) { gradient(round(80, 55, 352, 397, 31), [0x84909f, 0x303d50]) }
    gradient(round(80, 49, 352, 388, 28), [0xf9fafb, 0xcbd3dc, 0x94a1b1])
    stroke(round(80, 49, 352, 388, 28), 0x68788a, 2)
    stroke(round(85, 54, 342, 378, 24), 0xffffff, 2, 0.7)
    gradient(round(99, 81, 314, 285, 21), [0x3b4859, 0x152133])
    stroke(round(99, 81, 314, 285, 21), 0x647384, 2)
    gradient(ellipse(115, 94, 267, 267), [0x566a83, 0xe4eaf1, 0x879bb2, 0xf4f6f8, 0x52677e], angle: 32)
    for r in stride(from: CGFloat(47), through: 125, by: 5) {
        stroke(ellipse(248.5 - r, 227.5 - r, r * 2, r * 2), 0x314b68, 0.6, 0.18)
    }
    gradient(ellipse(215, 194, 67, 67), [0xffffff, 0xa1afbf, 0xe1e8ef], angle: 35)
    fill(ellipse(237, 216, 23, 23), 0x34445a)
    stroke(ellipse(237, 216, 23, 23), 0xffffff, 2, 0.7)
    let arm = polygon([(365, 309), (343, 327), (266, 240), (275, 230)])
    shadow(4, 4, 0.45) { gradient(arm, [0xeef2f6, 0x8496ad], angle: 0) }
    gradient(ellipse(327, 292, 49, 49), [0xf0f4f7, 0x7d91a8])
    fill(ellipse(342, 307, 19, 19), 0x5c7089)
    for (x, y): (CGFloat, CGFloat) in [(101, 69), (411, 69), (101, 414), (411, 414)] { screw(x, y) }
    gradient(round(122, 380, 174, 30, 5), [0xf9fafb, 0xe3e8ed])
    text("HFS", 134, 383, 16, 0x56677d, weight: .bold)
    for x in stride(from: CGFloat(188), to: 281, by: 5) {
        fill(round(x, 387, x.truncatingRemainder(dividingBy: 3) + 1, 15, 0), 0x8995a3)
    }
    gradient(round(326, 383, 64, 22, 6), [0xffbb68, 0xe57a32])
    fill(ellipse(366, 389, 8, 8), 0xffefc2)
}

func appIcon() {
    let tile = round(30, 25, 452, 452, 104)
    shadow(13, 9, 0.25) { gradient(tile, [0xffd58d, 0xffad51, 0xe67a30]) }
    stroke(tile, 0xb95723, 1.5, 0.6)
    stroke(round(33, 28, 446, 446, 101), 0xffffff, 2, 0.55)
    // A graphite diskette and a dimensional fox, rather than a flat animal portrait.
    placed(80, 75, 0.69) { floppy() }
    placed(-4, 65, 1.02) { fox() }
}

func compactMac() {
    gradient(round(132, 421, 249, 37, 14), [0xc4c4be, 0x8a9299])
    let shell = round(111, 42, 290, 394, 28)
    shadow(18, 10, 0.23) { gradient(shell, [0xfffdf3, 0xe1e1d9, 0xb7bdbe]) }
    stroke(shell, 0x8e9a9f, 1.5)
    stroke(round(116, 47, 280, 382, 24), 0xffffff, 2, 0.8)
    gradient(round(137, 73, 238, 224, 22), [0x9da7ad, 0xffffff, 0xcbd1cf])
    gradient(round(147, 84, 218, 202, 18), [0x101e2b, 0x394d5d])
    gradient(round(155, 92, 202, 183, 15), [0x263b4b, 0x59808b], angle: 65)
    saved {
        round(155, 92, 202, 183, 15).addClip()
        fill(polygon([(155, 92), (357, 92), (155, 234)]), 0xffffff, 0.06)
    }
    // The familiar welcome face etched in the glass.
    stroke(line([(227, 156), (227, 172)]), 0xd6f3ee, 5)
    stroke(line([(282, 156), (282, 172)]), 0xd6f3ee, 5)
    let smile = NSBezierPath(); smile.move(to: NSPoint(x: 228, y: 203))
    smile.curve(to: NSPoint(x: 283, y: 203), controlPoint1: NSPoint(x: 240, y: 221), controlPoint2: NSPoint(x: 270, y: 221))
    stroke(smile, 0xd6f3ee, 4)
    stroke(line([(245, 170), (245, 190), (255, 190)]), 0xd6f3ee, 3)
    gradient(round(245, 331, 113, 10, 5), [0x69767d, 0x1e303e, 0xb0babd])
    stroke(line([(251, 334), (351, 334)]), 0x14222f, 2)
    fill(ellipse(346, 360, 6, 6), 0x79a99a)
    for y in stride(from: CGFloat(362), through: 390, by: 7) {
        stroke(line([(151, y), (206, y)]), 0x7d8a91, 2, 0.8)
        stroke(line([(151, y + 2), (206, y + 2)]), 0xffffff, 1, 0.7)
    }
    placed(295, 355, 0.12) { fox() }
}

func welcome() {
    // The illustration has no baked-in background, so both window appearances work.
    placed(98, 4, 0.79) { compactMac() }
    placed(8, 192, 0.46, -12) { floppy() }
    placed(326, 228, 0.32, 12) { hardDisk() }
}

enum DocumentKind: String { case generic, text, image, audio, archive, application, video, system, font }
func document(_ kind: DocumentKind) {
    let paper = NSBezierPath()
    paper.move(to: NSPoint(x: 113, y: 36)); paper.line(to: NSPoint(x: 310, y: 36))
    paper.line(to: NSPoint(x: 407, y: 133)); paper.line(to: NSPoint(x: 407, y: 450))
    paper.curve(to: NSPoint(x: 390, y: 467), controlPoint1: NSPoint(x: 407, y: 460), controlPoint2: NSPoint(x: 400, y: 467))
    paper.line(to: NSPoint(x: 113, y: 467))
    paper.curve(to: NSPoint(x: 96, y: 450), controlPoint1: NSPoint(x: 103, y: 467), controlPoint2: NSPoint(x: 96, y: 460))
    paper.line(to: NSPoint(x: 96, y: 53))
    paper.curve(to: NSPoint(x: 113, y: 36), controlPoint1: NSPoint(x: 96, y: 43), controlPoint2: NSPoint(x: 103, y: 36)); paper.close()
    shadow(12, 6, 0.2) { gradient(paper, [0xffffff, 0xe4eaf1]) }
    stroke(paper, 0x93a3b7, 1.5)
    let fold = NSBezierPath(); fold.move(to: NSPoint(x: 310, y: 36)); fold.line(to: NSPoint(x: 407, y: 133))
    fold.line(to: NSPoint(x: 327, y: 133)); fold.curve(to: NSPoint(x: 310, y: 116), controlPoint1: NSPoint(x: 317, y: 133), controlPoint2: NSPoint(x: 310, y: 126)); fold.close()
    shadow(5, 3, 0.15) { gradient(fold, [0xf9fcff, 0xc6d1df], angle: 135) }
    switch kind {
    case .generic:
        placed(93, 122, 0.63) { fox() }
        for y: CGFloat in [371, 392] {
            fill(round(172, y, 164, 6, 3), 0xb4c0ce)
        }
    case .text:
        fill(round(145, 176, 118, 11, 5), 0x687f9c)
        for (y, w): (CGFloat, CGFloat) in [(217, 215), (250, 215), (283, 174), (330, 215), (363, 183)] {
            fill(round(145, y, w, 7, 3.5), 0x94a6bd)
        }
    case .image:
        let picture = round(132, 183, 239, 191, 13)
        gradient(picture, [0x91d9f3, 0x4388c0])
        saved {
            picture.addClip()
            fill(ellipse(298, 207, 36, 36), 0xffe4a0)
            gradient(polygon([(121, 374), (214, 248), (302, 374)]), [0xc1e4d0, 0x369891])
            gradient(polygon([(221, 374), (306, 277), (385, 374)]), [0xe6f4de, 0x61afaa])
        }
        stroke(picture, 0x226da4, 1.5, 0.5)
    case .audio:
        let note = line([(220, 326), (220, 207), (315, 185), (315, 304)])
        stroke(note, 0xb372be, 16)
        stroke(line([(222, 234), (312, 213)]), 0xb372be, 13)
        gradient(ellipse(172, 311, 55, 39), [0xd6a5db, 0x8e4da7], angle: 40)
        gradient(ellipse(267, 290, 55, 39), [0xd6a5db, 0x8e4da7], angle: 40)
    case .archive:
        gradient(round(151, 206, 202, 165, 14), [0xe9cba1, 0xb98c56])
        gradient(polygon([(141, 206), (167, 170), (338, 170), (363, 206)]), [0xf6dfbb, 0xd4ab79])
        fill(round(237, 170, 31, 201, 0), 0xa37648, 0.4)
        for y in stride(from: CGFloat(180), through: 325, by: 15) {
            gradient(round(245, y, 16, 7, 2), [0xf4e2c5, 0x7e664f], angle: 0)
        }
        gradient(round(239, 318, 26, 32, 5), [0xf8ecd9, 0x9f876c])
    case .application:
        gradient(round(151, 189, 202, 192, 40), [0x9acff7, 0x3d82c6, 0x2862a3])
        stroke(round(154, 192, 196, 186, 37), 0xffffff, 2, 0.6)
        stroke(line([(203, 325), (251, 231), (301, 325)]), 0xf0f9ff, 17)
        stroke(line([(200, 294), (304, 294)]), 0xf0f9ff, 15)
    case .video:
        gradient(round(137, 192, 229, 174, 17), [0x8795ab, 0x3a4a63])
        gradient(polygon([(232, 235), (232, 324), (302, 279)]), [0xffffff, 0xd1dfed], angle: 30)
        for x in stride(from: CGFloat(152), through: 342, by: 28) {
            fill(round(x, 203, 13, 9, 2), 0xd5e1ed); fill(round(x, 347, 13, 9, 2), 0xd5e1ed)
        }
    case .font:
        let font = NSFont(descriptor: NSFont.systemFont(ofSize: 109).fontDescriptor.withDesign(.serif)!, size: 109)!
        ("Aa" as NSString).draw(at: NSPoint(x: 164, y: 202), withAttributes: [.font: font, .foregroundColor: color(0x506c8e)])
        stroke(line([(155, 341), (349, 341)]), 0x9babc0, 2)
    case .system:
        gradient(round(151, 189, 202, 192, 40), [0xdce2e8, 0x8b9aab])
        // A recognizable settings wheel, rendered with the system's vector symbol.
        let symbol = NSImage(systemSymbolName: "gearshape.fill", accessibilityDescription: nil)!
        let tinted = symbol.withSymbolConfiguration(.init(paletteColors: [color(0x52677e)]))!
        tinted.draw(in: NSRect(x: 188, y: 218, width: 128, height: 128))
    }
}

func bitmap(width: Int, height: Int? = nil, canvas: CGFloat = 512, draw: () -> Void) -> NSBitmapImageRep {
    let h = height ?? width
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: h,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: h)
    saved {
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        context.cgContext.translateBy(x: 0, y: CGFloat(h))
        context.cgContext.scaleBy(x: CGFloat(width) / canvas, y: -CGFloat(width) / canvas)
        // Text and SF Symbols also need the AppKit flipped flag.
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        draw()
    }
    return rep
}
func save(_ rep: NSBitmapImageRep, _ path: URL) throws {
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "FloppyFox.Artwork", code: 1, userInfo: [NSLocalizedDescriptionKey: "PNG encoding failed"])
    }
    try data.write(to: path)
    print("Wrote \(path.path)")
}
let drawings: [String: () -> Void] = [
    "AppIcon": appIcon, "FloppyDisk": floppy, "HardDisk": hardDisk, "Welcome": welcome,
    "Document": { document(.generic) }, "TextDocument": { document(.text) },
    "ImageDocument": { document(.image) }, "AudioDocument": { document(.audio) },
    "ArchiveDocument": { document(.archive) }, "Application": { document(.application) },
    "VideoDocument": { document(.video) }, "SystemDocument": { document(.system) },
    "FontDocument": { document(.font) }
]
let sizes = [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"),
             (128, "128x128"), (256, "128x128@2x"), (256, "256x256"),
             (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")]
do {
    guard CommandLine.arguments.count == 3 else {
        throw NSError(domain: "FloppyFox.Artwork", code: 2, userInfo: [NSLocalizedDescriptionKey: "Usage: generate_artwork.swift resources|app|floppy|hardDisk|preview <output>"])
    }
    let mode = CommandLine.arguments[1]
    let output = URL(fileURLWithPath: CommandLine.arguments[2])
    if mode == "resources" {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for name in drawings.keys.sorted() {
            let rep = name == "Welcome"
                ? bitmap(width: 1536, height: 1320, draw: welcome)
                : bitmap(width: 1024, draw: drawings[name]!)
            try save(rep, output.appendingPathComponent(name + ".png"))
        }
    } else if mode == "preview" {
        try save(bitmap(width: 1680, height: 1080, canvas: 1120) {
            fill(round(0, 0, 1120, 720, 0), 0xf1f2f4)
            placed(28, 30, 0.48) { appIcon() }
            placed(306, 32, 0.48) { floppy() }
            placed(574, 32, 0.48) { hardDisk() }
            placed(833, 32, 0.48) { compactMac() }
            for (i, name) in ["Document", "TextDocument", "ImageDocument", "AudioDocument", "ArchiveDocument", "Application", "VideoDocument", "SystemDocument", "FontDocument"].enumerated() {
                placed(CGFloat(i) * 122 + 17, 340, 0.21) { drawings[name]!() }
                text(name == "Document" ? "Document" : name.replacingOccurrences(of: "Document", with: ""), CGFloat(i) * 122 + 25, 467, 12, 0x536276)
            }
            fill(round(0, 510, 560, 210, 0), 0xfafafa)
            fill(round(560, 510, 560, 210, 0), 0x252932)
            placed(156, 512, 0.45) { welcome() }
            placed(716, 512, 0.45) { welcome() }
        }, output)
    } else {
        guard let draw = ["app": appIcon, "floppy": floppy, "hardDisk": hardDisk][mode] else {
            throw NSError(domain: "FloppyFox.Artwork", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unknown artwork mode: \(mode)"])
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (px, suffix) in sizes {
            // Supersampling keeps curves and fine hardware details clean at Finder sizes.
            let source = bitmap(width: max(px, 1024), draw: draw)
            let resized = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            saved {
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: resized)
                NSGraphicsContext.current?.imageInterpolation = .high
                NSImage(cgImage: source.cgImage!, size: NSSize(width: px, height: px)).draw(in: NSRect(x: 0, y: 0, width: px, height: px))
            }
            try save(resized, output.appendingPathComponent("icon_\(suffix).png"))
        }
    }
} catch {
    fputs("Artwork generation failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
