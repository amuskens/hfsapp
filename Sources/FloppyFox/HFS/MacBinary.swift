import Foundation

/// MacBinary II/III: a classic Mac file (both forks plus Finder info) flattened into one file,
/// the format `.bin` downloads use. Encoding writes MacBinary III; decoding accepts II and III
/// (CRC-verified) and MacBinary I (strict structural checks), so an ordinary file is never
/// mistaken for one.
struct MacBinaryFile: Equatable {
    var name: HFSName
    var fileType: [UInt8]
    var creator: [UInt8]
    var finderFlags: UInt16
    var dataFork: [UInt8]
    var resourceFork: [UInt8]
    var createDate: UInt32 = 0
    var modifyDate: UInt32 = 0

    func encoded() -> [UInt8] {
        var header = [UInt8](repeating: 0, count: 128)
        let name = Array(self.name.bytes.prefix(63))
        header[1] = UInt8(name.count)
        header.put(name, at: 2)
        header.put(padded(fileType), at: 65)
        header.put(padded(creator), at: 69)
        header[73] = UInt8(finderFlags >> 8)
        header.put32(UInt32(dataFork.count), at: 83)
        header.put32(UInt32(resourceFork.count), at: 87)
        header.put32(createDate, at: 91)
        header.put32(modifyDate, at: 95)
        header[101] = UInt8(truncatingIfNeeded: finderFlags)
        header.put(Array("mBIN".utf8), at: 102)
        header[122] = 130
        header[123] = 129
        header.put16(Self.crc16(header[0..<124]), at: 124)
        return header + dataFork + Self.padding(dataFork.count) + resourceFork + Self.padding(resourceFork.count)
    }

    static func decode(_ bytes: [UInt8]) -> MacBinaryFile? {
        guard bytes.count >= 128, bytes[0] == 0, bytes[74] == 0, bytes[82] == 0 else { return nil }
        let nameLength = Int(bytes[1])
        guard (1...63).contains(nameLength), nameLength <= HFSName.maxLength else { return nil }
        guard let dataLength = try? bytes.u32(83), let resourceLength = try? bytes.u32(87),
              dataLength <= 0x7FFF_FFFF, resourceLength <= 0x7FFF_FFFF else { return nil }

        let crcMatches = (try? bytes.u16(124)) == crc16(bytes[0..<124])
        if !crcMatches {
            // MacBinary I: everything past the creator/flags fields is zero.
            guard bytes[99..<128].allSatisfy({ $0 == 0 }) else { return nil }
        }
        let secondaryHeaderLength = Int((try? bytes.u16(120)) ?? 0)
        let dataStart = 128 + (secondaryHeaderLength + 127) / 128 * 128
        let resourceStart = dataStart + (Int(dataLength) + 127) / 128 * 128
        guard dataStart + Int(dataLength) <= bytes.count, resourceStart + Int(resourceLength) <= bytes.count || resourceLength == 0 else { return nil }
        // Anything substantial after the forks means this isn't really MacBinary.
        let end = resourceLength > 0 ? resourceStart + Int(resourceLength) : dataStart + Int(dataLength)
        guard bytes.count - end < 128 + 128 else { return nil }

        return MacBinaryFile(
            name: HFSName(bytes: Array(bytes[2..<(2 + nameLength)])),
            fileType: Array(bytes[65..<69]),
            creator: Array(bytes[69..<73]),
            finderFlags: UInt16(bytes[73]) << 8 | (crcMatches ? UInt16(bytes[101]) : 0),
            dataFork: Array(bytes[dataStart..<(dataStart + Int(dataLength))]),
            resourceFork: resourceLength > 0 ? Array(bytes[resourceStart..<(resourceStart + Int(resourceLength))]) : [],
            createDate: (try? bytes.u32(91)) ?? 0,
            modifyDate: (try? bytes.u32(95)) ?? 0
        )
    }

    /// CRC-16/XMODEM (polynomial 0x1021, initial 0), as MacBinary II specifies.
    static func crc16<C: Collection>(_ bytes: C) -> UInt16 where C.Element == UInt8 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }
        }
        return crc
    }

    private func padded(_ code: [UInt8]) -> [UInt8] {
        Array(code.prefix(4)) + Array(repeating: 0x20, count: max(0, 4 - code.count))
    }

    private static func padding(_ count: Int) -> [UInt8] {
        [UInt8](repeating: 0, count: (128 - count % 128) % 128)
    }
}
