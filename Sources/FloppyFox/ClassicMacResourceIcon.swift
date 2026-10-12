import AppKit
import Foundation

/// A deliberately small classic Resource Manager reader. It extracts monochrome `ICN#`
/// (32×32) and `ics#` (16×16) icon/mask pairs from a MacBinary file. This covers many System
/// 6/7 applications while keeping malformed disk-image contents safely bounds-checked.
enum ClassicMacResourceIcon {
    static func iconPNG(fromMacBinary file: Data) -> Data? {
        guard file.count >= 128,
              let dataForkLength = file.uint32BE(at: 83),
              let resourceForkLength = file.uint32BE(at: 87),
              resourceForkLength > 0 else { return nil }

        let resourceStart = 128 + aligned128(Int(dataForkLength))
        let resourceEnd = resourceStart + Int(resourceForkLength)
        guard resourceStart >= 0, resourceEnd <= file.count else { return nil }
        return iconPNG(fromResourceFork: file.subdata(in: resourceStart..<resourceEnd))
    }

    static func iconPNG(fromResourceFork fork: Data) -> Data? {
        guard fork.count >= 16,
              let dataOffset = fork.uint32BE(at: 0),
              let mapOffset = fork.uint32BE(at: 4) else { return nil }

        let resourceDataStart = Int(dataOffset)
        let mapStart = Int(mapOffset)
        guard mapStart + 28 <= fork.count,
              let typeListRelative = fork.uint16BE(at: mapStart + 24) else { return nil }
        let typeListStart = mapStart + Int(typeListRelative)
        guard let typeCountMinusOne = fork.uint16BE(at: typeListStart) else { return nil }

        var candidates: [(id: Int16, data: Data, dimension: Int)] = []
        for typeIndex in 0...Int(typeCountMinusOne) {
            let typeEntry = typeListStart + 2 + typeIndex * 8
            guard typeEntry + 8 <= fork.count,
                  let type = fork.fourCC(at: typeEntry),
                  let countMinusOne = fork.uint16BE(at: typeEntry + 4),
                  let referencesRelative = fork.uint16BE(at: typeEntry + 6),
                  type == "ICN#" || type == "ics#" else { continue }

            let dimension = type == "ICN#" ? 32 : 16
            let minimumLength = dimension * dimension / 4 // image bits plus mask bits
            let referencesStart = typeListStart + Int(referencesRelative)
            for referenceIndex in 0...Int(countMinusOne) {
                let reference = referencesStart + referenceIndex * 12
                guard reference + 12 <= fork.count,
                      let rawID = fork.uint16BE(at: reference),
                      let packedOffset = fork.uint32BE(at: reference + 4) else { continue }
                let payloadStart = resourceDataStart + Int(packedOffset & 0x00ff_ffff)
                guard let payloadLength = fork.uint32BE(at: payloadStart) else { continue }
                let bytesStart = payloadStart + 4
                let bytesEnd = bytesStart + Int(payloadLength)
                guard Int(payloadLength) >= minimumLength, bytesEnd <= fork.count else { continue }
                candidates.append((Int16(bitPattern: rawID), fork.subdata(in: bytesStart..<bytesEnd), dimension))
            }
        }

        // -16455 is the conventional custom-icon resource ID. Otherwise use the largest
        // application icon available in the fork.
        guard let icon = candidates.first(where: { $0.id == -16455 })
                ?? candidates.sorted(by: { $0.dimension > $1.dimension }).first else { return nil }
        return monochromePNG(icon.data, dimension: icon.dimension)
    }

    private static func monochromePNG(_ icon: Data, dimension: Int) -> Data? {
        let planeLength = dimension * dimension / 8
        guard icon.count >= planeLength * 2 else { return nil }
        var rgba = Data(count: dimension * dimension * 4)
        rgba.withUnsafeMutableBytes { rawBuffer in
            guard let pixels = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            for pixel in 0..<(dimension * dimension) {
                let byte = pixel / 8
                let bit = UInt8(0x80 >> (pixel % 8))
                let isBlack = icon[byte] & bit != 0
                let isVisible = icon[planeLength + byte] & bit != 0
                let output = pixel * 4
                let shade: UInt8 = isBlack ? 0 : 255
                pixels[output] = shade
                pixels[output + 1] = shade
                pixels[output + 2] = shade
                pixels[output + 3] = isVisible ? 255 : 0
            }
        }

        guard let provider = CGDataProvider(data: rgba as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(
                width: dimension,
                height: dimension,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: dimension * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    private static func aligned128(_ value: Int) -> Int {
        (value + 127) & ~127
    }
}

private extension Data {
    func uint16BE(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        return (UInt16(self[offset]) << 8) | UInt16(self[offset + 1])
    }

    func uint32BE(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return (UInt32(self[offset]) << 24)
            | (UInt32(self[offset + 1]) << 16)
            | (UInt32(self[offset + 2]) << 8)
            | UInt32(self[offset + 3])
    }

    func fourCC(at offset: Int) -> String? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return String(bytes: self[offset..<(offset + 4)], encoding: .macOSRoman)
    }
}
