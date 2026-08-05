#!/usr/bin/env swift
import AppKit
import Foundation

// Improved fox icon generator: draws a stylized fox head with pointed ears and white muzzle.
// Usage: generate_icon.swift <output-iconset-dir>

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("Usage: generate_icon.swift <output-iconset-dir>")
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

func drawFox(in rect: CGRect) {
    // Core drawing using NSBezierPath
    // Colors
    let orange = NSColor(calibratedRed: 1.00, green: 0.45, blue: 0.16, alpha: 1.0)
    let darkOrange = NSColor(calibratedRed: 0.86, green: 0.32, blue: 0.10, alpha: 1.0)
    let white = NSColor.white
    let eyeColor = NSColor(calibratedWhite: 0.06, alpha: 1.0)

    // Helper coordinates
    let w = rect.width
    let h = rect.height

    // Head base (rounded diamond / triangular face)
    let head = NSBezierPath()
    head.move(to: CGPoint(x: w*0.5, y: h*0.9)) // top center between ears
    head.line(to: CGPoint(x: w*0.15, y: h*0.45)) // left cheek
    head.curve(to: CGPoint(x: w*0.5, y: h*0.15), controlPoint1: CGPoint(x: w*0.15, y: h*0.25), controlPoint2: CGPoint(x: w*0.35, y: h*0.12))
    head.curve(to: CGPoint(x: w*0.85, y: h*0.45), controlPoint1: CGPoint(x: w*0.65, y: h*0.12), controlPoint2: CGPoint(x: w*0.85, y: h*0.25))
    head.close()
    orange.setFill()
    head.fill()

    // Ears (left)
    let leftEar = NSBezierPath()
    leftEar.move(to: CGPoint(x: w*0.32, y: h*0.85))
    leftEar.line(to: CGPoint(x: w*0.18, y: h*0.98))
    leftEar.line(to: CGPoint(x: w*0.40, y: h*0.78))
    leftEar.close()
    darkOrange.setFill()
    leftEar.fill()
    // inner left ear
    let leftInner = NSBezierPath()
    leftInner.move(to: CGPoint(x: w*0.33, y: h*0.84))
    leftInner.line(to: CGPoint(x: w*0.24, y: h*0.95))
    leftInner.line(to: CGPoint(x: w*0.38, y: h*0.79))
    leftInner.close()
    NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.68, alpha: 1.0).setFill()
    leftInner.fill()

    // Ears (right)
    let rightEar = NSBezierPath()
    rightEar.move(to: CGPoint(x: w*0.68, y: h*0.85))
    rightEar.line(to: CGPoint(x: w*0.82, y: h*0.98))
    rightEar.line(to: CGPoint(x: w*0.60, y: h*0.78))
    rightEar.close()
    darkOrange.setFill()
    rightEar.fill()
    // inner right ear
    let rightInner = NSBezierPath()
    rightInner.move(to: CGPoint(x: w*0.67, y: h*0.84))
    rightInner.line(to: CGPoint(x: w*0.76, y: h*0.95))
    rightInner.line(to: CGPoint(x: w*0.62, y: h*0.79))
    rightInner.close()
    NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.68, alpha: 1.0).setFill()
    rightInner.fill()

    // Muzzle (white)
    let muzzle = NSBezierPath()
    muzzle.move(to: CGPoint(x: w*0.4, y: h*0.38))
    muzzle.curve(to: CGPoint(x: w*0.5, y: h*0.28), controlPoint1: CGPoint(x: w*0.4, y: h*0.32), controlPoint2: CGPoint(x: w*0.45, y: h*0.28))
    muzzle.curve(to: CGPoint(x: w*0.6, y: h*0.38), controlPoint1: CGPoint(x: w*0.55, y: h*0.28), controlPoint2: CGPoint(x: w*0.6, y: h*0.32))
    muzzle.line(to: CGPoint(x: w*0.62, y: h*0.45))
    muzzle.curve(to: CGPoint(x: w*0.5, y: h*0.52), controlPoint1: CGPoint(x: w*0.62, y: h*0.5), controlPoint2: CGPoint(x: w*0.56, y: h*0.52))
    muzzle.curve(to: CGPoint(x: w*0.38, y: h*0.45), controlPoint1: CGPoint(x: w*0.44, y: h*0.52), controlPoint2: CGPoint(x: w*0.38, y: h*0.5))
    muzzle.close()
    white.setFill()
    muzzle.fill()

    // Nose
    let nose = NSBezierPath(roundedRect: CGRect(x: w*0.48, y: h*0.34, width: w*0.04, height: h*0.03), xRadius: w*0.01, yRadius: h*0.01)
    NSColor(calibratedWhite: 0.06, alpha: 1.0).setFill()
    nose.fill()

    // Eyes (almond shapes)
    let eyeWidth = w*0.08
    let eyeHeight = h*0.05
    let leftEyeRect = CGRect(x: w*0.38 - eyeWidth*0.5, y: h*0.46, width: eyeWidth, height: eyeHeight)
    let rightEyeRect = leftEyeRect.offsetBy(dx: w*0.24, dy: 0)
    let leftEye = NSBezierPath(ovalIn: leftEyeRect)
    let rightEye = NSBezierPath(ovalIn: rightEyeRect)
    eyeColor.setFill()
    leftEye.fill()
    rightEye.fill()

    // Eye highlights
    let highlight = NSBezierPath(ovalIn: CGRect(x: leftEyeRect.minX + eyeWidth*0.15, y: leftEyeRect.minY + eyeHeight*0.55, width: eyeWidth*0.18, height: eyeHeight*0.18))
    NSColor.white.withAlphaComponent(0.9).setFill()
    highlight.fill()
    let highlightR = NSBezierPath(ovalIn: highlight.bounds.offsetBy(dx: w*0.24, dy: 0))
    highlightR.fill()

    // Cheek accents (soft)
    let cheekColor = NSColor(calibratedRed: 1.0, green: 0.9, blue: 0.85, alpha: 0.75)
    let leftCheek = NSBezierPath(ovalIn: CGRect(x: w*0.28, y: h*0.36, width: w*0.14, height: h*0.08))
    cheekColor.setFill()
    leftCheek.fill()
    let rightCheek = NSBezierPath(ovalIn: CGRect(x: w*0.58, y: h*0.36, width: w*0.14, height: h*0.08))
    rightCheek.fill()

    // Subtle border
    NSColor(calibratedWhite: 0.0, alpha: 0.06).setStroke()
    head.lineWidth = max(1.0, w*0.01)
    head.stroke()
}

func makeImage(size: CGSize) -> NSImage {
    let image = NSImage(size: size)
    image.lockFocus()
    let ctx = NSGraphicsContext.current?.cgContext
    ctx?.interpolationQuality = .high

    // Background radial gradient for warmth
    let bg = NSGradient(colors: [NSColor(calibratedRed:0.98, green:0.96, blue:0.92, alpha:1.0), NSColor(calibratedRed:0.99, green:0.85, blue:0.6, alpha:1.0)])!
    bg.draw(in: CGRect(origin: .zero, size: size), relativeCenterPosition: .zero)

    // Draw fox centered
    let padding = size.width * 0.06
    let foxRect = CGRect(x: padding, y: padding, width: size.width - 2*padding, height: size.height - 2*padding)
    drawFox(in: foxRect)

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
