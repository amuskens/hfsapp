#!/usr/bin/env swift
import AppKit
import Foundation

// Generates the document icon used for disk image files FloppyFox opens
// (.dsk, .img, .hda, .vhd) — a stylized 3.5" floppy diskette in the app's
// brand palette, distinct from the fox-head app icon.
// Usage: generate_doc_icon.swift <output-iconset-dir>

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("Usage: generate_doc_icon.swift <output-iconset-dir>")
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

func drawFloppy(in rect: CGRect) {
    let w = rect.width
    let h = rect.height
    let x0 = rect.minX
    let y0 = rect.minY

    func pt(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
        CGPoint(x: x0 + w * fx, y: y0 + h * fy)
    }

    // Drop shadow
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = w * 0.05
    shadow.shadowOffset = CGSize(width: 0, height: -h * 0.02)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()

    // Case silhouette: square with a clipped top-right corner (classic 3.5" floppy)
    let cornerCut: CGFloat = 0.16
    let radius = w * 0.03
    let caseShape = NSBezierPath()
    caseShape.move(to: pt(0.0, 0.0))
    caseShape.line(to: pt(1.0, 0.0))
    caseShape.line(to: pt(1.0, 1.0 - cornerCut))
    caseShape.line(to: pt(1.0 - cornerCut, 1.0))
    caseShape.line(to: pt(0.0, 1.0))
    caseShape.close()
    caseShape.lineJoinStyle = .round
    let roundedCase = NSBezierPath(roundedRect: caseShape.bounds, xRadius: radius, yRadius: radius)
    _ = roundedCase // corner radius applied via clipping below for crisp cut corner

    let caseGradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.30, green: 0.32, blue: 0.38, alpha: 1.0),
        NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.21, alpha: 1.0)
    ])!
    caseGradient.draw(in: caseShape, angle: -90)

    NSGraphicsContext.restoreGraphicsState()

    // Subtle case edge highlight
    NSColor.white.withAlphaComponent(0.08).setStroke()
    caseShape.lineWidth = max(1.0, w * 0.006)
    caseShape.stroke()

    // Metal shutter band (brand orange) near the top
    let shutterRect = CGRect(x: x0 + w * 0.10, y: y0 + h * 0.66, width: w * 0.80, height: h * 0.20)
    let shutter = NSBezierPath(roundedRect: shutterRect, xRadius: w * 0.02, yRadius: w * 0.02)
    let shutterGradient = NSGradient(colors: [
        NSColor(calibratedRed: 1.00, green: 0.55, blue: 0.24, alpha: 1.0),
        NSColor(calibratedRed: 0.86, green: 0.32, blue: 0.10, alpha: 1.0)
    ])!
    shutterGradient.draw(in: shutter, angle: -90)
    NSColor.black.withAlphaComponent(0.15).setStroke()
    shutter.lineWidth = max(1.0, w * 0.004)
    shutter.stroke()

    // Shutter highlight stripe
    let stripeRect = CGRect(x: shutterRect.minX + w * 0.02, y: shutterRect.maxY - h * 0.045, width: shutterRect.width - w * 0.04, height: h * 0.02)
    let stripe = NSBezierPath(roundedRect: stripeRect, xRadius: w * 0.01, yRadius: w * 0.01)
    NSColor.white.withAlphaComponent(0.35).setFill()
    stripe.fill()

    // Hub window (metal shutter cutout revealing the disk hub) — dark slot
    let hubRect = CGRect(x: x0 + w * 0.40, y: shutterRect.minY + h * 0.03, width: w * 0.20, height: h * 0.14)
    let hub = NSBezierPath(roundedRect: hubRect, xRadius: w * 0.015, yRadius: w * 0.015)
    NSColor(calibratedWhite: 0.05, alpha: 1.0).setFill()
    hub.fill()
    let hubCircle = NSBezierPath(ovalIn: CGRect(x: hubRect.midX - w*0.035, y: hubRect.midY - w*0.035, width: w*0.07, height: w*0.07))
    NSColor(calibratedWhite: 0.35, alpha: 1.0).setFill()
    hubCircle.fill()

    // Write-protect notch (small dark square, upper-left of case)
    let notch = NSBezierPath(rect: CGRect(x: x0 + w * 0.14, y: y0 + h * 0.88, width: w * 0.07, height: h * 0.05))
    NSColor(calibratedWhite: 0.05, alpha: 1.0).setFill()
    notch.fill()

    // Label area (cream, matches app icon's muzzle tone)
    let labelRect = CGRect(x: x0 + w * 0.14, y: y0 + h * 0.16, width: w * 0.72, height: h * 0.40)
    let label = NSBezierPath(roundedRect: labelRect, xRadius: w * 0.02, yRadius: w * 0.02)
    NSColor(calibratedRed: 1.0, green: 0.97, blue: 0.93, alpha: 1.0).setFill()
    label.fill()
    NSColor.black.withAlphaComponent(0.08).setStroke()
    label.lineWidth = max(1.0, w * 0.004)
    label.stroke()

    // Label text lines
    NSColor(calibratedRed: 0.86, green: 0.32, blue: 0.10, alpha: 0.55).setFill()
    let lineHeight = h * 0.035
    let lineInset = w * 0.06
    let line1 = NSBezierPath(roundedRect: CGRect(x: labelRect.minX + lineInset, y: labelRect.maxY - h * 0.10, width: labelRect.width - lineInset * 2, height: lineHeight), xRadius: lineHeight/2, yRadius: lineHeight/2)
    line1.fill()
    NSColor.black.withAlphaComponent(0.20).setFill()
    let line2 = NSBezierPath(roundedRect: CGRect(x: labelRect.minX + lineInset, y: labelRect.maxY - h * 0.18, width: (labelRect.width - lineInset * 2) * 0.7, height: lineHeight), xRadius: lineHeight/2, yRadius: lineHeight/2)
    line2.fill()
    let line3 = NSBezierPath(roundedRect: CGRect(x: labelRect.minX + lineInset, y: labelRect.maxY - h * 0.26, width: (labelRect.width - lineInset * 2) * 0.5, height: lineHeight), xRadius: lineHeight/2, yRadius: lineHeight/2)
    line3.fill()

    // Small fox-ear accent tucked in the corner cut, ties back to the app icon
    let earRect = CGRect(x: x0 + w * 0.84, y: y0 + h * 0.84, width: w * 0.12, height: h * 0.12)
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
    let floppyRect = CGRect(x: padding, y: padding, width: size.width - 2*padding, height: size.height - 2*padding)
    drawFloppy(in: floppyRect)

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
