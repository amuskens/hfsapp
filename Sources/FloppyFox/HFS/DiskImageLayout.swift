import Foundation

/// Where HFS volumes live inside an image file.
struct HFSVolumeLocation: Equatable, Sendable {
    let offset: UInt64
    let length: UInt64
    /// The partition name from an Apple Partition Map, if any.
    let partitionName: String?
    /// Set when the volume can be read but must not be written in this container format.
    let readOnlyReason: String?
}

enum DiskImageLayout {
    /// Finds every classic HFS volume in the image: a bare volume (most floppy images), the
    /// Apple_HFS partitions of an Apple Partition Map (hard-disk images such as BlueSCSI
    /// `.hda` files), or the payload of a DiskCopy 4.2 image.
    static func volumes(in url: URL) throws -> [HFSVolumeLocation] {
        let device = try BlockDevice(url: url, writable: false)
        var length = device.length
        // A fixed-size VHD is a raw disk followed by a 512-byte "conectix" footer, which is
        // not part of the disk (and must never be mistaken for its last sector).
        if length >= 1024, let footer = try? device.read(at: length - 512, count: 8), footer == Array("conectix".utf8) {
            length -= 512
        }

        func signature(at position: UInt64) -> UInt16? {
            guard position + 2 <= length, let bytes = try? device.read(at: position, count: 2) else { return nil }
            return UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        }

        // Bare volume: MDB at byte 1024.
        if signature(at: 1024) == MasterDirectoryBlock.signature {
            return [HFSVolumeLocation(offset: 0, length: length, partitionName: nil, readOnlyReason: nil)]
        }
        if let sig = signature(at: 1024), hfsPlusSignatures.contains(sig) {
            throw HFSError.unsupported("Mac OS Extended (HFS+) volumes")
        }

        // GUID Partition Table (what `hdiutil create` and modern Disk Utility make).
        if length > 1024, let header = try? device.read(at: 512, count: 92), header.prefix(8).elementsEqual("EFI PART".utf8) {
            let entriesStart = littleEndian(header, 72, 8) * 512
            let entryCount = min(littleEndian(header, 80, 4), 256)
            let entrySize = littleEndian(header, 84, 4)
            var result: [HFSVolumeLocation] = []
            var sawHFSPlus = false
            if entrySize >= 128, entrySize <= 4096 {
                for index in 0..<entryCount {
                    let position = entriesStart + index * entrySize
                    guard position + 128 <= length, let entry = try? device.read(at: position, count: 128) else { break }
                    guard entry[0..<16].contains(where: { $0 != 0 }) else { continue }
                    let start = littleEndian(entry, 32, 8) * 512
                    let end = (littleEndian(entry, 40, 8) + 1) * 512
                    guard start < length, end > start else { continue }
                    switch signature(at: start + 1024) {
                    case MasterDirectoryBlock.signature?:
                        if let mdb = try? MasterDirectoryBlock(sector: try device.read(at: start + 1024, count: 512)),
                           mdb.embeddedSignature == MasterDirectoryBlock.embeddedHFSPlusSignature {
                            sawHFSPlus = true
                        } else {
                            result.append(HFSVolumeLocation(offset: start, length: min(end, length) - start, partitionName: nil, readOnlyReason: nil))
                        }
                    case let sig? where hfsPlusSignatures.contains(sig):
                        sawHFSPlus = true
                    default:
                        continue
                    }
                }
            }
            if !result.isEmpty { return result }
            if sawHFSPlus { throw HFSError.unsupported("Mac OS Extended (HFS+) volumes") }
        }

        // Apple Partition Map: driver descriptor "ER" in block 0 (optional), entries "PM"
        // from block 1.
        if signature(at: 512) == 0x504D { // "PM"
            var blockSize: UInt64 = 512
            if signature(at: 0) == 0x4552, let ddm = try? device.read(at: 0, count: 4) {
                let size = UInt64(UInt16(ddm[2]) << 8 | UInt16(ddm[3]))
                if [512, 1024, 2048, 4096].contains(size) { blockSize = size }
            }
            let first = try device.read(at: blockSize, count: 512)
            let entryCount = min(Int(try first.u32(4)), 256)
            var result: [HFSVolumeLocation] = []
            var sawHFSPlus = false
            for index in 0..<entryCount {
                let position = blockSize * UInt64(1 + index)
                guard position + 512 <= length else { break }
                let entry = try device.read(at: position, count: 512)
                guard try entry.u16(0) == 0x504D else { continue }
                let start = UInt64(try entry.u32(8)) * blockSize
                let size = UInt64(try entry.u32(12)) * blockSize
                let type = cString(try entry.bytes(48, 32))
                guard type == "Apple_HFS", start < length else { continue }
                let partitionLength = min(size, length - start)
                switch signature(at: start + 1024) {
                case MasterDirectoryBlock.signature?:
                    // An HFS wrapper around an embedded HFS+ volume is reported as HFS+.
                    if let mdb = try? MasterDirectoryBlock(sector: try device.read(at: start + 1024, count: 512)),
                       mdb.embeddedSignature == MasterDirectoryBlock.embeddedHFSPlusSignature {
                        sawHFSPlus = true
                        continue
                    }
                    result.append(HFSVolumeLocation(offset: start, length: partitionLength, partitionName: cString(try entry.bytes(16, 32)), readOnlyReason: nil))
                case let sig? where hfsPlusSignatures.contains(sig):
                    sawHFSPlus = true
                default:
                    continue
                }
            }
            if result.isEmpty && sawHFSPlus { throw HFSError.unsupported("Mac OS Extended (HFS+) volumes") }
            if !result.isEmpty { return result }
        }

        // DiskCopy 4.2: 84-byte header (name, sizes, checksums), magic 0x0100 at offset 82.
        if length > 84, signature(at: 82) == 0x0100, let header = try? device.read(at: 0, count: 84) {
            let dataSize = UInt64(try header.u32(64))
            if dataSize > 0, 84 + dataSize <= length, signature(at: 84 + 1024) == MasterDirectoryBlock.signature {
                // Writing would invalidate the header's data checksum, which Disk Copy verifies.
                return [HFSVolumeLocation(offset: 84, length: dataSize, partitionName: nil, readOnlyReason: "DiskCopy 4.2 images are opened read-only.")]
            }
        }
        throw HFSError.notHFS
    }

    /// "H+" (HFS+) and "HX" (case-sensitive HFSX).
    private static let hfsPlusSignatures: Set<UInt16> = [0x482B, 0x4858]

    private static func littleEndian(_ bytes: [UInt8], _ offset: Int, _ count: Int) -> UInt64 {
        (0..<count).reversed().reduce(UInt64(0)) { $0 << 8 | UInt64(bytes[offset + $1]) }
    }

    private static func cString(_ bytes: [UInt8]) -> String {
        let trimmed = bytes.prefix { $0 != 0 }
        return String(data: Data(trimmed), encoding: .macOSRoman) ?? ""
    }
}

extension HFSVolume {
    /// Opens the volume at `location` inside the image at `url`.
    static func open(_ url: URL, at location: HFSVolumeLocation, readOnly: Bool) throws -> HFSVolume {
        let readOnly = readOnly || location.readOnlyReason != nil
        let device = try BlockDevice(url: url, offset: location.offset, length: location.length, writable: !readOnly)
        return try HFSVolume(device: device, readOnly: readOnly)
    }

    /// Opens the first HFS volume in the image.
    static func open(_ url: URL, readOnly: Bool) throws -> HFSVolume {
        guard let location = try DiskImageLayout.volumes(in: url).first else { throw HFSError.notHFS }
        return try open(url, at: location, readOnly: readOnly)
    }
}
