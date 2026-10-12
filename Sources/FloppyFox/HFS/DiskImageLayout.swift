import Foundation

/// Where an HFS or HFS Plus volume lives inside an image file.
struct HFSVolumeLocation: Equatable, Sendable {
    enum Format: Equatable, Sendable {
        case hfs
        case hfsPlus
    }

    let format: Format
    let offset: UInt64
    let length: UInt64
    /// The partition name from a partition map, if any.
    let partitionName: String?
    /// Set when the volume can be read but must not be written in this container format.
    let readOnlyReason: String?

    init(format: Format = .hfs, offset: UInt64, length: UInt64, partitionName: String?, readOnlyReason: String?) {
        self.format = format
        self.offset = offset
        self.length = length
        self.partitionName = partitionName
        self.readOnlyReason = readOnlyReason
    }
}

enum DiskImageLayout {
    private static let hfsPlusSignatures: Set<UInt16> = [HFSPlusVolumeHeader.hfsPlusSignature, HFSPlusVolumeHeader.hfsxSignature]

    /// Finds every HFS and HFS Plus volume in the image: a bare volume (most floppy images),
    /// the HFS partitions of an Apple Partition Map (hard-disk images such as BlueSCSI `.hda`
    /// files) or a GUID partition table, or the payload of a DiskCopy 4.2 image. An HFS Plus
    /// volume wrapped in an HFS volume (as Mac OS 8.1–9 formats them) is reported as the
    /// HFS Plus volume inside.
    static func volumes(in url: URL) throws -> [HFSVolumeLocation] {
        let device = try BlockDevice(url: url, writable: false)
        var length = device.length
        // A fixed-size VHD is a raw disk followed by a 512-byte "conectix" footer, which is
        // not part of the disk (and must never be mistaken for its last sector).
        if length >= 1024, let footer = try? device.read(at: length - 512, count: 8), footer == Array("conectix".utf8) {
            length -= 512
        }

        func signature(at position: UInt64) -> UInt16? {
            guard position <= length, length - position >= 2, let bytes = try? device.read(at: position, count: 2) else { return nil }
            return UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        }

        /// The volume starting at `start` (of at most `size` bytes), if it is HFS or HFS Plus.
        func volume(at start: UInt64, size: UInt64, name: String?) -> HFSVolumeLocation? {
            guard start < length else { return nil }
            let size = min(size, length - start)
            guard let sig = signature(at: start + 1024) else { return nil }
            if hfsPlusSignatures.contains(sig) {
                return HFSVolumeLocation(format: .hfsPlus, offset: start, length: size, partitionName: name, readOnlyReason: nil)
            }
            guard sig == MasterDirectoryBlock.signature, size >= 1536,
                  let raw = try? device.read(at: start + 1024, count: 512),
                  let mdb = try? MasterDirectoryBlock(sector: raw) else { return nil }
            guard mdb.embeddedSignature == MasterDirectoryBlock.embeddedHFSPlusSignature else {
                return HFSVolumeLocation(format: .hfs, offset: start, length: size, partitionName: name, readOnlyReason: nil)
            }
            // HFS wrapper: drEmbedExtent (start block, block count), in the wrapper's own
            // allocation blocks.
            guard let embedStart = try? raw.u16(126), let embedCount = try? raw.u16(128) else { return nil }
            let blockSize = UInt64(mdb.allocationBlockSize)
            let embeddedOffset = start + UInt64(mdb.firstAllocationSector) * 512 + UInt64(embedStart) * blockSize
            let embeddedLength = UInt64(embedCount) * blockSize
            guard embeddedLength > 0, embeddedOffset < length, embeddedLength <= length - embeddedOffset,
                  let inner = signature(at: embeddedOffset + 1024), hfsPlusSignatures.contains(inner) else { return nil }
            return HFSVolumeLocation(format: .hfsPlus, offset: embeddedOffset, length: embeddedLength, partitionName: name, readOnlyReason: nil)
        }

        // Bare volume: MDB / volume header at byte 1024.
        if let bare = volume(at: 0, size: length, name: nil) {
            return [bare]
        }

        // GUID Partition Table (what `hdiutil create` and modern Disk Utility make). Every
        // value is untrusted: LBAs are bounded by the image size before multiplying.
        let sectors = length / 512
        if length > 1024, let header = try? device.read(at: 512, count: 92), header.prefix(8).elementsEqual("EFI PART".utf8) {
            let entriesLBA = littleEndian(header, 72, 8)
            let entryCount = min(littleEndian(header, 80, 4), 256)
            let entrySize = littleEndian(header, 84, 4)
            var result: [HFSVolumeLocation] = []
            if entriesLBA < sectors, entrySize >= 128, entrySize <= 4096 {
                for index in 0..<entryCount {
                    let position = entriesLBA * 512 + index * entrySize
                    guard position < length, length - position >= 128, let entry = try? device.read(at: position, count: 128) else { break }
                    guard entry[0..<16].contains(where: { $0 != 0 }) else { continue }
                    let first = littleEndian(entry, 32, 8)
                    let last = littleEndian(entry, 40, 8)
                    guard first < sectors, last >= first else { continue }
                    let end = min(last, sectors - 1) + 1
                    if let found = volume(at: first * 512, size: (end - first) * 512, name: nil) { result.append(found) }
                }
            }
            if !result.isEmpty { return result }
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
            for index in 0..<entryCount {
                let position = blockSize * UInt64(1 + index)
                guard position < length, length - position >= 512 else { break }
                let entry = try device.read(at: position, count: 512)
                guard try entry.u16(0) == 0x504D else { continue }
                let startBlock = UInt64(try entry.u32(8))
                let sizeBlocks = UInt64(try entry.u32(12))
                guard cString(try entry.bytes(48, 32)) == "Apple_HFS", startBlock < length / blockSize else { continue }
                if let found = volume(at: startBlock * blockSize, size: sizeBlocks * blockSize, name: cString(try entry.bytes(16, 32))) {
                    result.append(found)
                }
            }
            if !result.isEmpty { return result }
        }

        // DiskCopy 4.2: 84-byte header (name, sizes, checksums), magic 0x0100 at offset 82.
        if length > 84, signature(at: 82) == 0x0100, let header = try? device.read(at: 0, count: 84) {
            let dataSize = UInt64(try header.u32(64))
            if dataSize > 0, dataSize <= length - 84, let found = volume(at: 84, size: dataSize, name: nil) {
                // Writing would invalidate the header's data checksum, which Disk Copy verifies.
                return [HFSVolumeLocation(format: found.format, offset: found.offset, length: found.length, partitionName: nil,
                                          readOnlyReason: "DiskCopy 4.2 images are opened read-only.")]
            }
        }
        throw HFSError.notHFS
    }

    private static func littleEndian(_ bytes: [UInt8], _ offset: Int, _ count: Int) -> UInt64 {
        (0..<count).reversed().reduce(UInt64(0)) { $0 << 8 | UInt64(bytes[offset + $1]) }
    }

    private static func cString(_ bytes: [UInt8]) -> String {
        let trimmed = bytes.prefix { $0 != 0 }
        return String(data: Data(trimmed), encoding: .macOSRoman) ?? ""
    }

    /// Opens the volume at `location` inside the image at `url`, as HFS or HFS Plus. A writer
    /// that can't take the image's exclusive lock (another program is writing it) gets a
    /// read-only volume instead, with cause `.inUse`.
    static func openVolume(_ url: URL, at location: HFSVolumeLocation, readOnly: Bool, allowUncleanVolume: Bool = false) throws -> any DiskVolume {
        func open(writable: Bool, cause: ReadOnlyCause) throws -> any DiskVolume {
            let device = try BlockDevice(url: url, offset: location.offset, length: location.length, writable: writable)
            let readOnlyCause: ReadOnlyCause? = writable ? nil : cause
            switch location.format {
            case .hfs: return try HFSVolume(device: device, forcedReadOnly: readOnlyCause, allowUncleanVolume: allowUncleanVolume)
            case .hfsPlus: return try HFSPlusVolume(device: device, forcedReadOnly: readOnlyCause, allowUncleanVolume: allowUncleanVolume)
            }
        }
        if readOnly || location.readOnlyReason != nil { return try open(writable: false, cause: .requested) }
        do {
            return try open(writable: true, cause: .requested)
        } catch HFSError.inUse {
            return try open(writable: false, cause: .inUse)
        }
    }

    /// Opens the first volume in the image.
    static func openVolume(_ url: URL, readOnly: Bool, allowUncleanVolume: Bool = false) throws -> any DiskVolume {
        guard let location = try volumes(in: url).first else { throw HFSError.notHFS }
        return try openVolume(url, at: location, readOnly: readOnly, allowUncleanVolume: allowUncleanVolume)
    }
}

extension HFSVolume {
    /// Opens the first classic HFS volume in the image (for tests and tools).
    static func open(_ url: URL, readOnly: Bool, allowUncleanVolume: Bool = false) throws -> HFSVolume {
        guard let location = try DiskImageLayout.volumes(in: url).first(where: { $0.format == .hfs }) else { throw HFSError.notHFS }
        let device = try BlockDevice(url: url, offset: location.offset, length: location.length, writable: !readOnly)
        return try HFSVolume(device: device, forcedReadOnly: readOnly ? .requested : nil, allowUncleanVolume: allowUncleanVolume)
    }
}
