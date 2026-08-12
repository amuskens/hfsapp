#!/usr/bin/env swift
import AppKit
import Foundation

// Generates original stylized artwork for FloppyFox's "classic Mac" decorative icons
// (a 3.5" floppy disk, a compact Mac silhouette, and a smiling monitor), replacing
// artwork that was previously sourced from a third-party repo with no stated license.
// Usage: generate_classic_mac_icons.swift <output-dir>

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("Usage: generate_classic_mac_icons.swift <output-dir>")
    exit(1)
}
let outDir = URL(fileURLWithPath: args[1], isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let canvas = CGSize(width: 1024, height: 1024)

func savePNG(image: NSImage, url: URL) {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let data = rep.representation(using: .png, properties: [:]) else {
        print("Failed to create PNG for \(url.path)")
        return
    }
    try? data.write(to: url)
}

func makeImage(_ draw: (CGRect) -> Void) -> NSImage {
    let image = NSImage(size: canvas)
    image.lockFocus()
    NSGraphicsContext.current?.cgContext.interpolationQuality = .high
    let padding = canvas.width * 0.08
    let rect = CGRect(x: padding, y: padding, width: canvas.width - 2 * padding, height: canvas.height - 2 * padding)
    draw(rect)
    image.unlockFocus()
    return image
}

// MARK: - Floppy disk

func drawFloppy(in rect: CGRect) {
    let w = rect.width, h = rect.height
    let body = NSColor(calibratedWhite: 0.16, alpha: 1.0)
    let shutter = NSColor(calibratedWhite: 0.62, alpha: 1.0)
    let label = NSColor(calibratedRed: 0.93, green: 0.95, blue: 0.98, alpha: 1.0)
    let notch = NSColor(calibratedWhite: 0.05, alpha: 1.0)

    let bodyPath = NSBezierPath(roundedRect: rect, xRadius: w * 0.06, yRadius: h * 0.06)
    body.setFill()
    bodyPath.fill()

    // Clipped notch corner (top-right), a classic 3.5" disk detail.
    let cut = NSBezierPath()
    cut.move(to: CGPoint(x: rect.maxX - w * 0.16, y: rect.maxY))
    cut.line(to: CGPoint(x: rect.maxX, y: rect.maxY))
    cut.line(to: CGPoint(x: rect.maxX, y: rect.maxY - h * 0.16))
    cut.line(to: CGPoint(x: rect.maxX - w * 0.16, y: rect.maxY))
    cut.close()
    NSGraphicsContext.current?.saveGraphicsState()
    bodyPath.addClip()
    NSGraphicsContext.current?.compositingOperation = .destinationOut
    cut.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    // Metal shutter band across the bottom.
    let shutterRect = CGRect(x: rect.minX + w * 0.14, y: rect.minY + h * 0.06, width: w * 0.72, height: h * 0.26)
    let shutterPath = NSBezierPath(roundedRect: shutterRect, xRadius: w * 0.02, yRadius: w * 0.02)
    shutter.setFill()
    shutterPath.fill()
    let slot = NSBezierPath(rect: CGRect(x: shutterRect.midX - w * 0.16, y: shutterRect.minY + h * 0.06, width: w * 0.32, height: h * 0.14))
    notch.setFill()
    slot.fill()

    // Paper label.
    let labelRect = CGRect(x: rect.minX + w * 0.14, y: rect.minY + h * 0.42, width: w * 0.72, height: h * 0.4)
    let labelPath = NSBezierPath(roundedRect: labelRect, xRadius: w * 0.02, yRadius: w * 0.02)
    label.setFill()
    labelPath.fill()
    for i in 0..<3 {
        let lineRect = CGRect(x: labelRect.minX + w * 0.08, y: labelRect.maxY - h * 0.1 - CGFloat(i) * h * 0.09, width: w * (i == 1 ? 0.4 : 0.56), height: h * 0.03)
        NSColor(calibratedWhite: 0.7, alpha: 1.0).setFill()
        NSBezierPath(rect: lineRect).fill()
    }

    // Write-protect tab, top-left.
    let tabRect = CGRect(x: rect.minX + w * 0.1, y: rect.maxY - h * 0.14, width: w * 0.14, height: h * 0.08)
    shutter.setFill()
    NSBezierPath(roundedRect: tabRect, xRadius: 3, yRadius: 3).fill()
}

// MARK: - Compact Mac

func drawCompactMac(in rect: CGRect) {
    let w = rect.width, h = rect.height
    let bodyColor = NSColor(calibratedRed: 0.86, green: 0.85, blue: 0.80, alpha: 1.0)
    let bodyShadow = NSColor(calibratedRed: 0.72, green: 0.71, blue: 0.66, alpha: 1.0)
    let screenBezel = NSColor(calibratedWhite: 0.15, alpha: 1.0)
    let screenColor = NSColor(calibratedRed: 0.55, green: 0.68, blue: 0.78, alpha: 1.0)

    // Rounded chassis, slightly domed top like the original all-in-one Macs.
    let chassis = NSBezierPath()
    let r = w * 0.14
    chassis.appendRoundedRect(rect, xRadius: r, yRadius: r)
    bodyColor.setFill()
    chassis.fill()

    // Subtle bottom shading for depth.
    let shade = NSBezierPath(roundedRect: CGRect(x: rect.minX, y: rect.minY, width: w, height: h * 0.18), xRadius: r, yRadius: r)
    bodyShadow.withAlphaComponent(0.5).setFill()
    shade.fill()

    // Screen bezel + screen.
    let bezelRect = CGRect(x: rect.minX + w * 0.2, y: rect.minY + h * 0.42, width: w * 0.6, height: h * 0.4)
    NSBezierPath(roundedRect: bezelRect, xRadius: w * 0.06, yRadius: w * 0.06).fill(withColor: screenBezel)
    let screenRect = bezelRect.insetBy(dx: w * 0.045, dy: w * 0.045)
    NSBezierPath(roundedRect: screenRect, xRadius: w * 0.03, yRadius: w * 0.03).fill(withColor: screenColor)

    // Disk slot + speaker grille below the screen.
    let slot = CGRect(x: rect.midX - w * 0.11, y: rect.minY + h * 0.3, width: w * 0.22, height: h * 0.025)
    NSBezierPath(roundedRect: slot, xRadius: 2, yRadius: 2).fill(withColor: bodyShadow)
    for i in 0..<5 {
        let dot = CGRect(x: rect.minX + w * 0.24 + CGFloat(i) * w * 0.045, y: rect.minY + h * 0.2, width: w * 0.02, height: w * 0.02)
        NSBezierPath(ovalIn: dot).fill(withColor: bodyShadow)
    }
}

// MARK: - Smiling monitor

func drawHappyMonitor(in rect: CGRect) {
    let w = rect.width, h = rect.height
    let bezel = NSColor(calibratedWhite: 0.2, alpha: 1.0)
    let screen = NSColor(calibratedRed: 0.98, green: 0.85, blue: 0.35, alpha: 1.0)
    let face = NSColor(calibratedWhite: 0.12, alpha: 1.0)

    let monitorRect = CGRect(x: rect.minX, y: rect.minY + h * 0.14, width: w, height: h * 0.76)
    NSBezierPath(roundedRect: monitorRect, xRadius: w * 0.12, yRadius: w * 0.12).fill(withColor: bezel)

    let screenRect = monitorRect.insetBy(dx: w * 0.08, dy: w * 0.08)
    NSBezierPath(roundedRect: screenRect, xRadius: w * 0.06, yRadius: w * 0.06).fill(withColor: screen)

    // Eyes.
    let eyeSize = w * 0.09
    let leftEye = CGRect(x: screenRect.minX + screenRect.width * 0.28 - eyeSize / 2, y: screenRect.midY + h * 0.02, width: eyeSize, height: eyeSize)
    let rightEye = leftEye.offsetBy(dx: screenRect.width * 0.44, dy: 0)
    NSBezierPath(ovalIn: leftEye).fill(withColor: face)
    NSBezierPath(ovalIn: rightEye).fill(withColor: face)

    // Smile.
    let smile = NSBezierPath()
    let smileRect = CGRect(x: screenRect.minX + screenRect.width * 0.22, y: screenRect.minY + h * 0.06, width: screenRect.width * 0.56, height: h * 0.16)
    smile.appendArc(withCenter: CGPoint(x: smileRect.midX, y: smileRect.maxY), radius: smileRect.width / 2, startAngle: 200, endAngle: 340)
    smile.lineWidth = w * 0.035
    smile.lineCapStyle = .round
    face.setStroke()
    smile.stroke()

    // Stand.
    let standRect = CGRect(x: rect.midX - w * 0.09, y: rect.minY, width: w * 0.18, height: h * 0.14)
    NSBezierPath(roundedRect: standRect, xRadius: w * 0.02, yRadius: w * 0.02).fill(withColor: bezel)
    let baseRect = CGRect(x: rect.midX - w * 0.22, y: rect.minY, width: w * 0.44, height: h * 0.04)
    NSBezierPath(roundedRect: baseRect, xRadius: w * 0.02, yRadius: w * 0.02).fill(withColor: bezel)
}

extension NSBezierPath {
    func fill(withColor color: NSColor) {
        color.setFill()
        fill()
    }
}

let drawings: [(String, (CGRect) -> Void)] = [
    ("Floppy.png", drawFloppy),
    ("ClassicMac.png", drawCompactMac),
    ("HappyMac.png", drawHappyMonitor),
]

for (name, draw) in drawings {
    let image = makeImage(draw)
    let dest = outDir.appendingPathComponent(name)
    savePNG(image: image, url: dest)
    print("Wrote \(dest.path)")
}
