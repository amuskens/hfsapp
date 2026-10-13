import Foundation

// On-disk structures of the classic Hierarchical File System, per Inside Macintosh: Files
// (chapter 2, "Data Organization on Volumes"). Every structure wraps the raw bytes it was read
// from and exposes fields as accessors, so fields this code doesn't interpret — reserved
// words, Finder info it doesn't change — are written back exactly as found.

/// Catalog node IDs with fixed meanings.
enum HFSCatalogID {
    static let rootParent: UInt32 = 1
    static let rootFolder: UInt32 = 2
    static let extentsFile: UInt32 = 3
    static let catalogFile: UInt32 = 4
    static let badBlocksFile: UInt32 = 5
    static let firstUserID: UInt32 = 16
}

enum HFSFork: UInt8, Sendable {
    case data = 0x00
    case resource = 0xFF
}

struct ExtentDescriptor: Equatable, Sendable {
    var startBlock: UInt16
    var blockCount: UInt16

    static let empty = ExtentDescriptor(startBlock: 0, blockCount: 0)
}

/// Three extent descriptors, the unit HFS stores everywhere (MDB, catalog file records, and
/// extents-overflow records).
struct ExtentRecord: Equatable, Sendable {
    var extents: [ExtentDescriptor]

    static let byteCount = 12
    static let empty = ExtentRecord(extents: [.empty, .empty, .empty])

    init(extents: [ExtentDescriptor]) {
        precondition(extents.count <= 3)
        self.extents = extents + Array(repeating: .empty, count: 3 - extents.count)
    }

    init(bytes: [UInt8], at offset: Int) throws {
        extents = try (0..<3).map { index in
            ExtentDescriptor(startBlock: try bytes.u16(offset + index * 4), blockCount: try bytes.u16(offset + index * 4 + 2))
        }
    }

    var encoded: [UInt8] {
        var bytes = [UInt8](repeating: 0, count: Self.byteCount)
        for (index, extent) in extents.enumerated() {
            bytes.put16(extent.startBlock, at: index * 4)
            bytes.put16(extent.blockCount, at: index * 4 + 2)
        }
        return bytes
    }

    var blockCount: Int { extents.reduce(0) { $0 + Int($1.blockCount) } }
}

/// The Master Directory Block (volume header), 162 meaningful bytes at the start of a
/// 512-byte sector.
struct MasterDirectoryBlock {
    static let signature: UInt16 = 0x4244 // "BD"
    static let embeddedHFSPlusSignature: UInt16 = 0x482B // "H+"
    /// drAtrb bit 8: set when the volume was cleanly unmounted. Mac OS checks the disk when a
    /// volume it mounts has this bit clear.
    static let unmountedCleanlyBit: UInt16 = 1 << 8
    /// drAtrb bit 15: software lock.
    static let softwareLockBit: UInt16 = 1 << 15
    static let hardwareLockBit: UInt16 = 1 << 7

    var raw: [UInt8]

    init(sector: [UInt8]) throws {
        guard sector.count >= 162, try sector.u16(0) == Self.signature else { throw HFSError.notHFS }
        raw = sector
    }

    private func get16(_ o: Int) -> UInt16 { (try? raw.u16(o)) ?? 0 }
    private func get32(_ o: Int) -> UInt32 { (try? raw.u32(o)) ?? 0 }

    var createDate: UInt32 { get32(2) }
    var modifyDate: UInt32 { get { get32(6) } set { raw.put32(newValue, at: 6) } }
    var attributes: UInt16 { get { get16(10) } set { raw.put16(newValue, at: 10) } }
    var rootFileCount: UInt16 { get { get16(12) } set { raw.put16(newValue, at: 12) } }
    var bitmapStartSector: UInt16 { get16(14) }
    var allocationPointer: UInt16 { get { get16(16) } set { raw.put16(newValue, at: 16) } }
    var allocationBlockCount: UInt16 { get16(18) }
    var allocationBlockSize: UInt32 { get32(20) }
    var clumpSize: UInt32 { get32(24) }
    var firstAllocationSector: UInt16 { get16(28) }
    var nextCatalogID: UInt32 { get { get32(30) } set { raw.put32(newValue, at: 30) } }
    var freeBlockCount: UInt16 { get { get16(34) } set { raw.put16(newValue, at: 34) } }
    var volumeName: HFSName {
        let length = min(Int(raw[36]), HFSName.maxVolumeLength)
        return HFSName(bytes: Array(raw[37..<(37 + length)]))
    }
    var writeCount: UInt32 { get { get32(70) } set { raw.put32(newValue, at: 70) } }
    var extentsClumpSize: UInt32 { get32(74) }
    var catalogClumpSize: UInt32 { get32(78) }
    var rootFolderCount: UInt16 { get { get16(82) } set { raw.put16(newValue, at: 82) } }
    var fileCount: UInt32 { get { get32(84) } set { raw.put32(newValue, at: 84) } }
    var folderCount: UInt32 { get { get32(88) } set { raw.put32(newValue, at: 88) } }
    var embeddedSignature: UInt16 { get16(124) }
    var extentsFileSize: UInt32 { get { get32(130) } set { raw.put32(newValue, at: 130) } }
    var extentsFileExtents: ExtentRecord {
        get { (try? ExtentRecord(bytes: raw, at: 134)) ?? .empty }
        set { raw.put(newValue.encoded, at: 134) }
    }
    var catalogFileSize: UInt32 { get { get32(146) } set { raw.put32(newValue, at: 146) } }
    var catalogFileExtents: ExtentRecord {
        get { (try? ExtentRecord(bytes: raw, at: 150)) ?? .empty }
        set { raw.put(newValue.encoded, at: 150) }
    }
}

/// Catalog B-tree key: parent folder ID plus the item's name.
struct CatalogKey: Hashable, Sendable {
    var parentID: UInt32
    var name: [UInt8]

    static func compare(_ lhs: CatalogKey, _ rhs: CatalogKey) -> Int {
        if lhs.parentID != rhs.parentID { return lhs.parentID < rhs.parentID ? -1 : 1 }
        return HFSName.compare(lhs.name, rhs.name)
    }

    /// Parses a key at `offset`; returns it and the offset of the record data that follows
    /// (keys are padded so record data starts on an even offset).
    static func parse(_ node: [UInt8], at offset: Int) throws -> (CatalogKey, dataOffset: Int) {
        let keyLength = Int(try node.u8(offset))
        guard keyLength >= 6 else { throw HFSError.corrupt("catalog key too short") }
        let parentID = try node.u32(offset + 2)
        let nameLength = Int(try node.u8(offset + 6))
        guard nameLength <= HFSName.maxLength, 6 + nameLength <= keyLength else { throw HFSError.corrupt("catalog key name too long") }
        let name = try node.bytes(offset + 7, nameLength)
        var dataOffset = offset + 1 + keyLength
        if dataOffset % 2 == 1 { dataOffset += 1 }
        return (CatalogKey(parentID: parentID, name: name), dataOffset)
    }

    /// Leaf form: as short as the name allows, padded to an even length.
    var leafEncoded: [UInt8] {
        var bytes: [UInt8] = [UInt8(6 + name.count), 0, 0, 0, 0, 0, UInt8(name.count)] + name
        bytes.put32(parentID, at: 2)
        if bytes.count % 2 == 1 { bytes.append(0) }
        return bytes
    }

    /// Index form: HFS catalog index keys are always the maximum key length (37), name
    /// zero-padded, so every index record has the same size.
    var indexEncoded: [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 38)
        bytes[0] = 37
        bytes.put32(parentID, at: 2)
        bytes[6] = UInt8(name.count)
        bytes.put(name, at: 7)
        return bytes
    }
}

/// Extents-overflow B-tree key: fork, file ID, and the fork-relative allocation block the
/// record's first extent starts at.
struct ExtentsKey: Hashable, Sendable {
    var fork: HFSFork
    var fileID: UInt32
    var startBlock: UInt16

    static func compare(_ lhs: ExtentsKey, _ rhs: ExtentsKey) -> Int {
        if lhs.fileID != rhs.fileID { return lhs.fileID < rhs.fileID ? -1 : 1 }
        if lhs.fork != rhs.fork { return lhs.fork.rawValue < rhs.fork.rawValue ? -1 : 1 }
        if lhs.startBlock != rhs.startBlock { return lhs.startBlock < rhs.startBlock ? -1 : 1 }
        return 0
    }

    static func parse(_ node: [UInt8], at offset: Int) throws -> (ExtentsKey, dataOffset: Int) {
        guard try node.u8(offset) == 7 else { throw HFSError.corrupt("bad extents key length") }
        guard let fork = HFSFork(rawValue: try node.u8(offset + 1)) else { throw HFSError.corrupt("bad extents fork type") }
        return (ExtentsKey(fork: fork, fileID: try node.u32(offset + 2), startBlock: try node.u16(offset + 6)), offset + 8)
    }

    var encoded: [UInt8] {
        var bytes: [UInt8] = [7, fork.rawValue, 0, 0, 0, 0, 0, 0]
        bytes.put32(fileID, at: 2)
        bytes.put16(startBlock, at: 6)
        return bytes
    }
}

enum CatalogRecordType: UInt8 {
    case folder = 1
    case file = 2
    case folderThread = 3
    case fileThread = 4
}

/// A catalog leaf record: its key plus the raw record bytes. Typed views below read and
/// update fields in place.
struct CatalogRecord: Sendable {
    var key: CatalogKey
    var data: [UInt8]

    var type: CatalogRecordType? { data.first.flatMap(CatalogRecordType.init(rawValue:)) }

    static let folderRecordSize = 70
    static let fileRecordSize = 102
    static let threadRecordSize = 46
}

/// cdrDirRec, 70 bytes.
struct FolderRecord {
    var raw: [UInt8]

    init(raw: [UInt8]) throws {
        guard raw.count >= CatalogRecord.folderRecordSize, raw[0] == CatalogRecordType.folder.rawValue else { throw HFSError.corrupt("bad folder record") }
        self.raw = raw
    }

    init(id: UInt32, date: UInt32) {
        raw = [UInt8](repeating: 0, count: CatalogRecord.folderRecordSize)
        raw[0] = CatalogRecordType.folder.rawValue
        raw.put32(id, at: 6)
        raw.put32(date, at: 10)
        raw.put32(date, at: 14)
    }

    var valence: UInt16 { get { (try? raw.u16(4)) ?? 0 } set { raw.put16(newValue, at: 4) } }
    var id: UInt32 { (try? raw.u32(6)) ?? 0 }
    var createDate: UInt32 { (try? raw.u32(10)) ?? 0 }
    var modifyDate: UInt32 { get { (try? raw.u32(14)) ?? 0 } set { raw.put32(newValue, at: 14) } }
    /// DInfo.frFlags — Finder flags; bit 14 (0x4000) is "invisible".
    var finderFlags: UInt16 { (try? raw.u16(30)) ?? 0 }
}

/// cdrFilRec, 102 bytes.
struct FileRecord {
    var raw: [UInt8]

    static let lockedFlag: UInt8 = 0x01
    /// filFlags bit 7: Mac OS sets it on every file record ("record in use").
    static let recordUsedFlag: UInt8 = 0x80
    static let threadExistsFlag: UInt8 = 0x02

    init(raw: [UInt8]) throws {
        guard raw.count >= CatalogRecord.fileRecordSize, raw[0] == CatalogRecordType.file.rawValue else { throw HFSError.corrupt("bad file record") }
        self.raw = raw
    }

    init(id: UInt32, date: UInt32, type: [UInt8], creator: [UInt8]) {
        raw = [UInt8](repeating: 0, count: CatalogRecord.fileRecordSize)
        raw[0] = CatalogRecordType.file.rawValue
        raw[2] = Self.recordUsedFlag
        raw.put(Array(type.prefix(4)) + Array(repeating: 0x20, count: max(0, 4 - type.count)), at: 4)
        raw.put(Array(creator.prefix(4)) + Array(repeating: 0x20, count: max(0, 4 - creator.count)), at: 8)
        raw.put32(id, at: 20)
        raw.put32(date, at: 44)
        raw.put32(date, at: 48)
    }

    var flags: UInt8 { get { raw[2] } set { raw[2] = newValue } }
    var isLocked: Bool { flags & Self.lockedFlag != 0 }
    var fileType: [UInt8] { get { Array(raw[4..<8]) } set { raw.put(Array(newValue.prefix(4)), at: 4) } }
    var creator: [UInt8] { get { Array(raw[8..<12]) } set { raw.put(Array(newValue.prefix(4)), at: 8) } }
    /// FInfo.fdFlags; bit 14 (0x4000) is "invisible".
    var finderFlags: UInt16 { get { (try? raw.u16(12)) ?? 0 } set { raw.put16(newValue, at: 12) } }
    /// The full 16-byte FInfo (type, creator, flags, location, folder).
    var finderInfo: [UInt8] { get { Array(raw[4..<20]) } set { raw.put(Array(newValue.prefix(16)), at: 4) } }
    /// The 16-byte FXInfo.
    var extendedFinderInfo: [UInt8] { get { Array(raw[56..<72]) } set { raw.put(Array(newValue.prefix(16)), at: 56) } }
    var id: UInt32 { (try? raw.u32(20)) ?? 0 }
    var createDate: UInt32 { get { (try? raw.u32(44)) ?? 0 } set { raw.put32(newValue, at: 44) } }
    var modifyDate: UInt32 { get { (try? raw.u32(48)) ?? 0 } set { raw.put32(newValue, at: 48) } }

    func logicalLength(_ fork: HFSFork) -> UInt32 { (try? raw.u32(fork == .data ? 26 : 36)) ?? 0 }
    func physicalLength(_ fork: HFSFork) -> UInt32 { (try? raw.u32(fork == .data ? 30 : 40)) ?? 0 }
    func extents(_ fork: HFSFork) -> ExtentRecord { (try? ExtentRecord(bytes: raw, at: fork == .data ? 74 : 86)) ?? .empty }

    mutating func setFork(_ fork: HFSFork, logicalLength: UInt32, physicalLength: UInt32, extents: ExtentRecord) {
        raw.put32(logicalLength, at: fork == .data ? 26 : 36)
        raw.put32(physicalLength, at: fork == .data ? 30 : 40)
        raw.put(extents.encoded, at: fork == .data ? 74 : 86)
        // filStBlk / filRStBlk are reserved: Mac OS writes zero, and fsck_hfs reports anything
        // else as damage ("Reserved fields in the catalog record have incorrect data").
        // (hfsutils fills them in, which is why fsck flags volumes it has written to.)
        raw.put16(0, at: fork == .data ? 24 : 34)
    }
}

/// cdrThdRec / cdrFThdRec, 46 bytes: maps an item's ID back to its parent and name.
struct ThreadRecord {
    static func make(type: CatalogRecordType, parentID: UInt32, name: [UInt8]) -> [UInt8] {
        var raw = [UInt8](repeating: 0, count: CatalogRecord.threadRecordSize)
        raw[0] = type.rawValue
        raw.put32(parentID, at: 10)
        raw[14] = UInt8(name.count)
        raw.put(name, at: 15)
        return raw
    }

    static func parse(_ raw: [UInt8]) throws -> (parentID: UInt32, name: [UInt8]) {
        let length = Int(try raw.u8(14))
        guard length <= HFSName.maxLength else { throw HFSError.corrupt("thread name too long") }
        return (try raw.u32(10), try raw.bytes(15, length))
    }
}
