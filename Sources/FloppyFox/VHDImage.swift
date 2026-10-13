import Foundation

enum VHDImageError: LocalizedError {
    case invalidFooter
    case unsupportedType(UInt32)
    case invalidDynamicHeader
    case invalidBlockTable

    var errorDescription: String? {
        switch self {
        case .invalidFooter:
            return "The file does not contain a valid VHD footer."
        case .unsupportedType(4):
            return "Differencing VHD images are not supported because their parent disk is required."
        case .unsupportedType(let type):
            return "VHD disk type \(type) is not supported."
        case .invalidDynamicHeader:
            return "The dynamic VHD header is invalid or incomplete."
        case .invalidBlockTable:
            return "The dynamic VHD block allocation table is invalid."
        }
    }
}

struct VHDPreparation: Sendable {
    let imageURL: URL
}

/// Makes VHD containers consumable by the app's existing raw-image backends. Fixed VHDs are
/// already raw sector data followed by a footer. Dynamic VHDs are expanded to a temporary raw
/// file; the caller deliberately opens that file read-only because writing it back would require
/// rebuilding the VHD block allocation table and checksums.
enum VHDImage {
    /// `directory` receives the expanded copy of a dynamic VHD (the app passes a directory in
    /// its managed temporary storage, so the copy can't outlive the session).
    static func prepareForReading(_ source: URL, into directory: URL = FileManager.default.temporaryDirectory) async throws -> VHDPreparation {
        try await Task.detached(priority: .userInitiated) {
            try prepareSynchronously(source, into: directory)
        }.value
    }

    private static func prepareSynchronously(_ source: URL, into directory: URL) throws -> VHDPreparation {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let fileLength = try input.seekToEnd()
        // Some classic-Mac emulator packs use `.vhd` for a plain raw hard-disk image rather
        // than Microsoft's VHD container format. No footer means the existing raw-image/HFS
        // backends should receive the file unchanged.
        guard fileLength >= 512 else { return VHDPreparation(imageURL: source) }
        try input.seek(toOffset: fileLength - 512)
        let footer = try input.read(upToCount: 512) ?? Data()
        guard footer.count == 512, footer.ascii(at: 0, count: 8) == "conectix" else {
            return VHDPreparation(imageURL: source)
        }
        guard let diskType = footer.uint32BE(at: 60) else { throw VHDImageError.invalidFooter }

        if diskType == 2 { return VHDPreparation(imageURL: source) }
        guard diskType == 3 else { throw VHDImageError.unsupportedType(diskType) }
        guard let virtualSize = footer.uint64BE(at: 48),
              let headerOffset = footer.uint64BE(at: 16),
              virtualSize > 0, headerOffset < fileLength else { throw VHDImageError.invalidFooter }

        try input.seek(toOffset: headerOffset)
        let header = try input.read(upToCount: 1024) ?? Data()
        guard header.count >= 36, header.ascii(at: 0, count: 8) == "cxsparse",
              let tableOffset = header.uint64BE(at: 16),
              let maximumEntries = header.uint32BE(at: 28),
              let blockSize = header.uint32BE(at: 32),
              blockSize >= 512, blockSize.isMultiple(of: 512) else {
            throw VHDImageError.invalidDynamicHeader
        }

        let requiredEntries64 = ((virtualSize - 1) / UInt64(blockSize)) + 1
        guard requiredEntries64 <= UInt64(Int.max) else { throw VHDImageError.invalidBlockTable }
        let requiredEntries = Int(requiredEntries64)
        guard requiredEntries > 0, UInt64(maximumEntries) >= UInt64(requiredEntries) else {
            throw VHDImageError.invalidBlockTable
        }
        // Only the entries capable of addressing the advertised virtual disk are relevant.
        // This also prevents a corrupt header from requesting a multi-gigabyte BAT allocation.
        let tableByteCount = requiredEntries * 4
        guard tableOffset <= fileLength, UInt64(tableByteCount) <= fileLength - tableOffset else {
            throw VHDImageError.invalidBlockTable
        }
        try input.seek(toOffset: tableOffset)
        let table = try input.read(upToCount: tableByteCount) ?? Data()
        guard table.count == tableByteCount else { throw VHDImageError.invalidBlockTable }

        let outputURL = directory.appendingPathComponent("floppyfox-vhd-\(UUID().uuidString).img")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        do {
            let output = try FileHandle(forWritingTo: outputURL)
            defer { try? output.close() }
            try output.truncate(atOffset: virtualSize)
            let sectorsPerBlock = Int(blockSize / 512)
            let bitmapBytes = (sectorsPerBlock + 7) / 8
            let paddedBitmapBytes = (bitmapBytes + 511) & ~511

            for blockIndex in 0..<requiredEntries {
                guard let sectorOffset = table.uint32BE(at: blockIndex * 4) else {
                    throw VHDImageError.invalidBlockTable
                }
                if sectorOffset == UInt32.max { continue }
                let storedBlockOffset = UInt64(sectorOffset) * 512
                let storedLength = UInt64(paddedBitmapBytes) + UInt64(blockSize)
                guard storedBlockOffset <= fileLength, storedLength <= fileLength - storedBlockOffset else {
                    throw VHDImageError.invalidBlockTable
                }

                try input.seek(toOffset: storedBlockOffset)
                let bitmap = try input.read(upToCount: paddedBitmapBytes) ?? Data()
                let storedData = try input.read(upToCount: Int(blockSize)) ?? Data()
                guard bitmap.count == paddedBitmapBytes, storedData.count == Int(blockSize) else {
                    throw VHDImageError.invalidBlockTable
                }

                var rawBlock = Data(repeating: 0, count: Int(blockSize))
                for sector in 0..<sectorsPerBlock where bitmap[sector / 8] & UInt8(0x80 >> (sector % 8)) != 0 {
                    let range = (sector * 512)..<((sector + 1) * 512)
                    rawBlock.replaceSubrange(range, with: storedData[range])
                }
                let destination = UInt64(blockIndex) * UInt64(blockSize)
                guard destination < virtualSize else { break }
                let writableCount = Int(min(UInt64(blockSize), virtualSize - destination))
                try output.seek(toOffset: destination)
                try output.write(contentsOf: rawBlock.prefix(writableCount))
            }
            return VHDPreparation(imageURL: outputURL)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }
}

private extension Data {
    func uint32BE(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return (UInt32(self[offset]) << 24) | (UInt32(self[offset + 1]) << 16)
            | (UInt32(self[offset + 2]) << 8) | UInt32(self[offset + 3])
    }

    func uint64BE(at offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= count else { return nil }
        return (0..<8).reduce(UInt64(0)) { ($0 << 8) | UInt64(self[offset + $1]) }
    }

    func ascii(at offset: Int, count length: Int) -> String? {
        guard offset >= 0, offset + length <= count else { return nil }
        return String(bytes: self[offset..<(offset + length)], encoding: .ascii)
    }
}
