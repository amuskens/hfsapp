#!/usr/bin/env swift
import AppKit
import Foundation

// Generates the document icon used for hard-disk image files FloppyFox opens
// (.hda, .vhd) — a stylized 3.5" hard drive with a platter window, distinct
// from the floppy-diskette icon used for .dsk/.img.
// Usage: generate_hd_doc_icon.swift <output-iconset-dir>

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("Usage: generate_hd_doc_icon.swift <output-iconset-dir>")
    exit(1)
}
let outDir = URL(fileURLWithPath: args[1], isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func savePNG(image: NSImage, url: URL) {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let data = rep.representation(using: .png, properties: [:]) else {
        print("Failed to create PNG for \(url.path)")
        return
    }
    try? data.write(to: url)
}

func drawHardDisk(in rect: CGRect) {
    let w = rect.width
    let h = rect.height
    let x0 = rect.minX
    let y0 = rect.minY

    // Drop shadow
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = w * 0.05
    shadow.shadowOffset = CGSize(width: 0, height: -h * 0.02)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()

    // Case silhouette: squat rounded box (classic external hard drive), brushed-metal look
    let caseRect = CGRect(x: x0, y: y0, width: w, height: h * 0.86)
    let caseShape = NSBezierPath(roundedRect: caseRect, xRadius: w * 0.08, yRadius: w * 0.08)
    let caseGradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.62, green: 0.64, blue: 0.68, alpha: 1.0),
        NSColor(calibratedRed: 0.38, green: 0.40, blue: 0.44, alpha: 1.0)
    ])!
    caseGradient.draw(in: caseShape, angle: -90)

    NSGraphicsContext.restoreGraphicsState()

    // Case edge highlight
    NSColor.white.withAlphaComponent(0.25).setStroke()
    caseShape.lineWidth = max(1.0, w * 0.006)
    caseShape.stroke()

    // Brand orange base band (foot/rubber bumper)
    let baseRect = CGRect(x: x0, y: y0, width: w, height: h * 0.10)
    let base = NSBezierPath(roundedRect: baseRect, xRadius: w * 0.04, yRadius: w * 0.04)
    let baseGradient = NSGradient(colors: [
        NSColor(calibratedRed: 1.00, green: 0.55, blue: 0.24, alpha: 1.0),
        NSColor(calibratedRed: 0.86, green: 0.32, blue: 0.10, alpha: 1.0)
    ])!
    baseGradient.draw(in: base, angle: -90)

    // Corner screws (hardware detail)
    let screwInset = w * 0.10
    let screwSize = w * 0.045
    let screwPositions = [
        CGPoint(x: x0 + screwInset, y: y0 + caseRect.height - screwInset),
        CGPoint(x: x0 + w - screwInset, y: y0 + caseRect.height - screwInset)
    ]
    for p in screwPositions {
        let screw = NSBezierPath(ovalIn: CGRect(x: p.x - screwSize/2, y: p.y - screwSize/2, width: screwSize, height: screwSize))
        NSColor(calibratedWhite: 0.15, alpha: 0.55).setFill()
        screw.fill()
        let glint = NSBezierPath(ovalIn: CGRect(x: p.x - screwSize*0.18, y: p.y + screwSize*0.05, width: screwSize*0.35, height: screwSize*0.2))
        NSColor.white.withAlphaComponent(0.5).setFill()
        glint.fill()
    }

    // Platter window: recessed dark porthole showing the spinning disk platter
    let platterCenter = CGPoint(x: x0 + w * 0.5, y: y0 + caseRect.height * 0.48)
    let platterOuterR = w * 0.30

    let windowShadow = NSShadow()
    windowShadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
    windowShadow.shadowBlurRadius = w * 0.02
    windowShadow.shadowOffset = .zero
    NSGraphicsContext.saveGraphicsState()
    windowShadow.set()
    let windowRing = NSBezierPath(ovalIn: CGRect(x: platterCenter.x - platterOuterR, y: platterCenter.y - platterOuterR, width: platterOuterR*2, height: platterOuterR*2))
    NSColor(calibratedWhite: 0.08, alpha: 1.0).setFill()
    windowRing.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Platter disc (brand-tinted metal)
    let platterR = platterOuterR * 0.86
    let platterRect = CGRect(x: platterCenter.x - platterR, y: platterCenter.y - platterR, width: platterR*2, height: platterR*2)
    let platter = NSBezierPath(ovalIn: platterRect)
    let platterGradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.30, green: 0.32, blue: 0.38, alpha: 1.0),
        NSColor(calibratedRed: 0.14, green: 0.15, blue: 0.18, alpha: 1.0)
    ])!
    platterGradient.draw(in: platter, angle: -45)

    // Concentric data-track grooves
    NSColor.white.withAlphaComponent(0.10).setStroke()
    for i in 1...3 {
        let f = CGFloat(i) / 4.0
        let r = platterR * (0.35 + f * 0.55)
        let ring = NSBezierPath(ovalIn: CGRect(x: platterCenter.x - r, y: platterCenter.y - r, width: r*2, height: r*2))
        ring.lineWidth = max(0.75, w * 0.003)
        ring.stroke()
    }

    // Spindle hub (brand orange)
    let hubR = platterR * 0.18
    let hub = NSBezierPath(ovalIn: CGRect(x: platterCenter.x - hubR, y: platterCenter.y - hubR, width: hubR*2, height: hubR*2))
    NSColor(calibratedRed: 1.00, green: 0.55, blue: 0.24, alpha: 1.0).setFill()
    hub.fill()
    let hubCenter = NSBezierPath(ovalIn: CGRect(x: platterCenter.x - hubR*0.35, y: platterCenter.y - hubR*0.35, width: hubR*0.7, height: hubR*0.7))
    NSColor(calibratedWhite: 0.1, alpha: 1.0).setFill()
    hubCenter.fill()

    // Read/write head arm accent, tucked over the platter edge
    let arm = NSBezierPath()
    arm.move(to: CGPoint(x: platterCenter.x + platterR * 0.55, y: platterCenter.y + platterR * 0.75))
    arm.line(to: CGPoint(x: platterCenter.x + platterOuterR * 1.02, y: platterCenter.y + platterOuterR * 1.02))
    arm.line(to: CGPoint(x: platterCenter.x + platterOuterR * 0.80, y: platterCenter.y + platterOuterR * 1.02))
    arm.close()
    NSColor(calibratedWhite: 0.85, alpha: 0.9).setFill()
    arm.fill()

    // Window rim highlight
    NSColor.white.withAlphaComponent(0.18).setStroke()
    windowRing.lineWidth = max(1.0, w * 0.008)
    windowRing.stroke()

    // Activity LED (brand orange, glowing dot) near bottom-right of case
    let ledCenter = CGPoint(x: x0 + w * 0.86, y: y0 + caseRect.height * 0.16)
    let ledGlow = NSBezierPath(ovalIn: CGRect(x: ledCenter.x - w*0.045, y: ledCenter.y - w*0.045, width: w*0.09, height: w*0.09))
    NSColor(calibratedRed: 1.00, green: 0.55, blue: 0.24, alpha: 0.35).setFill()
    ledGlow.fill()
    let led = NSBezierPath(ovalIn: CGRect(x: ledCenter.x - w*0.02, y: ledCenter.y - w*0.02, width: w*0.04, height: w*0.04))
    NSColor(calibratedRed: 1.00, green: 0.65, blue: 0.35, alpha: 1.0).setFill()
    led.fill()

    // Small fox-ear accent badge, top-right corner, ties back to the app icon
    let earRect = CGRect(x: x0 + w * 0.86, y: y0 + caseRect.height - h * 0.02, width: w * 0.12, height: h * 0.12)
    let ear = NSBezierPath()
    ear.move(to: CGPoint(x: earRect.minX, y: earRect.minY))
    ear.line(to: CGPoint(x: earRect.maxX, y: earRect.minY))
    ear.line(to: CGPoint(x: earRect.minX, y: earRect.maxY))
    ear.close()
    NSColor(calibratedRed: 1.00, green: 0.45, blue: 0.16, alpha: 1.0).setFill()
    ear.fill()
}

func makeImage(size: CGSize) -> NSImage {
    let image = NSImage(size: size)
    image.lockFocus()
    let ctx = NSGraphicsContext.current?.cgContext
    ctx?.interpolationQuality = .high

    let padding = size.width * 0.12
    let driveRect = CGRect(x: padding, y: padding, width: size.width - 2*padding, height: size.height - 2*padding)
    drawHardDisk(in: driveRect)

    image.unlockFocus()
    return image
}

let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

for (px, name) in sizes {
    let size = CGSize(width: px, height: px)
    let img = makeImage(size: size)
    let dest = outDir.appendingPathComponent(name)
    savePNG(image: img, url: dest)
    print("Wrote \(dest.path)")
}

print("Iconset generated at \(outDir.path)")
