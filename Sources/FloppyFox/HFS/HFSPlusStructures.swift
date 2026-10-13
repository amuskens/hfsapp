import Foundation

// On-disk structures of HFS Plus (Mac OS Extended), per Apple Technical Note TN1150. As with
// the classic structures, each wraps its raw bytes so fields this code doesn't interpret are
// written back exactly as found.

extension Array where Element == UInt8 {
    func u64(_ offset: Int) throws -> UInt64 {
        UInt64(try u32(offset)) << 32 | UInt64(try u32(offset + 4))
    }

    mutating func put64(_ value: UInt64, at offset: Int) {
        put32(UInt32(value >> 32), at: offset)
        put32(UInt32(truncatingIfNeeded: value), at: offset + 4)
    }
}

/// HFS Plus counts in 32-bit allocation blocks and keeps eight extents per record.
struct HFSPlusExtent: Equatable, Sendable {
    var startBlock: UInt32
    var blockCount: UInt32
}

/// HFSPlusForkData: a fork's sizes and its first eight extents (80 bytes).
struct HFSPlusForkData: Equatable, Sendable {
    static let byteCount = 80
    static let extentCount = 8

    var logicalSize: UInt64
    var clumpSize: UInt32
    var totalBlocks: UInt32
    var extents: [HFSPlusExtent]

    static let empty = HFSPlusForkData(logicalSize: 0, clumpSize: 0, totalBlocks: 0, extents: [])

    init(logicalSize: UInt64, clumpSize: UInt32, totalBlocks: UInt32, extents: [HFSPlusExtent]) {
        self.logicalSize = logicalSize
        self.clumpSize = clumpSize
        self.totalBlocks = totalBlocks
        self.extents = extents
    }

    init(bytes: [UInt8], at offset: Int) throws {
        logicalSize = try bytes.u64(offset)
        clumpSize = try bytes.u32(offset + 8)
        totalBlocks = try bytes.u32(offset + 12)
        extents = try HFSPlusForkData.parseExtents(bytes, at: offset + 16)
    }

    static func parseExtents(_ bytes: [UInt8], at offset: Int) throws -> [HFSPlusExtent] {
        try (0..<extentCount).map { i in
            HFSPlusExtent(startBlock: try bytes.u32(offset + i * 8), blockCount: try bytes.u32(offset + i * 8 + 4))
        }.filter { $0.blockCount > 0 }
    }

    static func encodeExtents(_ extents: [HFSPlusExtent]) -> [UInt8] {
        precondition(extents.count <= extentCount)
        var bytes = [UInt8](repeating: 0, count: extentCount * 8)
        for (i, extent) in extents.enumerated() {
            bytes.put32(extent.startBlock, at: i * 8)
            bytes.put32(extent.blockCount, at: i * 8 + 4)
        }
        return bytes
    }

    var encoded: [UInt8] {
        var bytes = [UInt8](repeating: 0, count: Self.byteCount)
        bytes.put64(logicalSize, at: 0)
        bytes.put32(clumpSize, at: 8)
        bytes.put32(totalBlocks, at: 12)
        bytes.put(Self.encodeExtents(Array(extents.prefix(Self.extentCount))), at: 16)
        return bytes
    }
}

/// HFSPlusVolumeHeader, 512 bytes at offset 1024 of the volume (copy at end − 1024).
struct HFSPlusVolumeHeader {
    static let hfsPlusSignature: UInt16 = 0x482B // "H+"
    static let hfsxSignature: UInt16 = 0x4858 // "HX"

    static let hardwareLockBit: UInt32 = 1 << 7
    static let unmountedCleanlyBit: UInt32 = 1 << 8
    static let inconsistentBit: UInt32 = 1 << 11
    static let journaledBit: UInt32 = 1 << 13
    static let softwareLockBit: UInt32 = 1 << 15

    var raw: [UInt8]

    init(sector: [UInt8]) throws {
        guard sector.count >= 512 else { throw HFSError.notHFS }
        let signature = try sector.u16(0)
        guard signature == Self.hfsPlusSignature || signature == Self.hfsxSignature else { throw HFSError.notHFS }
        raw = Array(sector.prefix(512))
    }

    private func get32(_ o: Int) -> UInt32 { (try? raw.u32(o)) ?? 0 }

    var isHFSX: Bool { (try? raw.u16(0)) == Self.hfsxSignature }
    var attributes: UInt32 { get { get32(4) } set { raw.put32(newValue, at: 4) } }
    var modifyDate: UInt32 { get { get32(20) } set { raw.put32(newValue, at: 20) } }
    var fileCount: UInt32 { get { get32(32) } set { raw.put32(newValue, at: 32) } }
    var folderCount: UInt32 { get { get32(36) } set { raw.put32(newValue, at: 36) } }
    var blockSize: UInt32 { get32(40) }
    var totalBlocks: UInt32 { get32(44) }
    var freeBlocks: UInt32 { get { get32(48) } set { raw.put32(newValue, at: 48) } }
    var nextAllocation: UInt32 { get { get32(52) } set { raw.put32(newValue, at: 52) } }
    var resourceClumpSize: UInt32 { get32(56) }
    var dataClumpSize: UInt32 { get32(60) }
    var nextCatalogID: UInt32 { get { get32(64) } set { raw.put32(newValue, at: 64) } }
    var writeCount: UInt32 { get { get32(68) } set { raw.put32(newValue, at: 68) } }
    var encodingsBitmap: UInt64 { get { (try? raw.u64(72)) ?? 0 } set { raw.put64(newValue, at: 72) } }

    func fork(_ offset: Int) -> HFSPlusForkData { (try? HFSPlusForkData(bytes: raw, at: offset)) ?? .empty }
    mutating func setFork(_ fork: HFSPlusForkData, _ offset: Int) { raw.put(fork.encoded, at: offset) }

    static let allocationFileOffset = 112
    static let extentsFileOffset = 192
    static let catalogFileOffset = 272
    static let attributesFileOffset = 352
    static let startupFileOffset = 432
}

/// HFS Plus catalog key: parent ID and a UTF-16 name of up to 255 units.
struct HFSPlusCatalogKey: Hashable, Sendable {
    var parentID: UInt32
    var name: [UInt16]

    static func parse(_ record: [UInt8], at offset: Int) throws -> (HFSPlusCatalogKey, dataOffset: Int) {
        let keyLength = Int(try record.u16(offset))
        guard keyLength >= 6 else { throw HFSError.corrupt("catalog key too short") }
        let parentID = try record.u32(offset + 2)
        let nameLength = Int(try record.u16(offset + 6))
        guard nameLength <= 255, 6 + 2 * nameLength <= keyLength else { throw HFSError.corrupt("catalog key name too long") }
        var name: [UInt16] = []
        name.reserveCapacity(nameLength)
        for i in 0..<nameLength { name.append(try record.u16(offset + 8 + 2 * i)) }
        return (HFSPlusCatalogKey(parentID: parentID, name: name), offset + 2 + keyLength)
    }

    var encoded: [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 8 + 2 * name.count)
        bytes.put16(UInt16(6 + 2 * name.count), at: 0)
        bytes.put32(parentID, at: 2)
        bytes.put16(UInt16(name.count), at: 6)
        for (i, unit) in name.enumerated() { bytes.put16(unit, at: 8 + 2 * i) }
        return bytes
    }
}

/// HFS Plus extents-overflow key (12 bytes).
struct HFSPlusExtentsKey: Hashable, Sendable {
    var fork: HFSFork
    var fileID: UInt32
    var startBlock: UInt32

    static func compare(_ lhs: HFSPlusExtentsKey, _ rhs: HFSPlusExtentsKey) -> Int {
        if lhs.fileID != rhs.fileID { return lhs.fileID < rhs.fileID ? -1 : 1 }
        if lhs.fork != rhs.fork { return lhs.fork.rawValue < rhs.fork.rawValue ? -1 : 1 }
        if lhs.startBlock != rhs.startBlock { return lhs.startBlock < rhs.startBlock ? -1 : 1 }
        return 0
    }

    static func parse(_ record: [UInt8], at offset: Int) throws -> (HFSPlusExtentsKey, dataOffset: Int) {
        guard try record.u16(offset) == 10 else { throw HFSError.corrupt("bad extents key length") }
        guard let fork = HFSFork(rawValue: try record.u8(offset + 2)) else { throw HFSError.corrupt("bad extents fork type") }
        return (HFSPlusExtentsKey(fork: fork, fileID: try record.u32(offset + 4), startBlock: try record.u32(offset + 8)), offset + 12)
    }

    var encoded: [UInt8] {
        var bytes: [UInt8] = [0, 10, fork.rawValue, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        bytes.put32(fileID, at: 4)
        bytes.put32(startBlock, at: 8)
        return bytes
    }
}

enum HFSPlusRecordType: UInt16 {
    case folder = 1
    case file = 2
    case folderThread = 3
    case fileThread = 4
}

/// A catalog leaf record: key plus raw record bytes.
struct HFSPlusCatalogRecord: Sendable {
    var key: HFSPlusCatalogKey
    var data: [UInt8]

    var type: HFSPlusRecordType? { (try? data.u16(0)).flatMap(HFSPlusRecordType.init(rawValue:)) }

    static let folderRecordSize = 88
    static let fileRecordSize = 248
}

/// HFSPlusCatalogFolder, 88 bytes.
struct HFSPlusFolderRecord {
    var raw: [UInt8]

    init(raw: [UInt8]) throws {
        guard raw.count >= HFSPlusCatalogRecord.folderRecordSize, (try raw.u16(0)) == HFSPlusRecordType.folder.rawValue else { throw HFSError.corrupt("bad folder record") }
        self.raw = raw
    }

    init(id: UInt32, date: UInt32, textEncoding: UInt32) {
        raw = [UInt8](repeating: 0, count: HFSPlusCatalogRecord.folderRecordSize)
        raw.put16(HFSPlusRecordType.folder.rawValue, at: 0)
        raw.put32(id, at: 8)
        for offset in [12, 16, 20, 24] { raw.put32(date, at: offset) }
        raw.put32(textEncoding, at: 80)
    }

    var flags: UInt16 { get { (try? raw.u16(2)) ?? 0 } set { raw.put16(newValue, at: 2) } }
    var valence: UInt32 { get { (try? raw.u32(4)) ?? 0 } set { raw.put32(newValue, at: 4) } }
    var id: UInt32 { (try? raw.u32(8)) ?? 0 }
    var createDate: UInt32 { (try? raw.u32(12)) ?? 0 }
    var modifyDate: UInt32 { get { (try? raw.u32(16)) ?? 0 } set { raw.put32(newValue, at: 16); raw.put32(newValue, at: 20) } }
    var finderFlags: UInt16 { (try? raw.u16(56)) ?? 0 }
    /// The HFSX-style subfolder count, maintained only when flag 0x0010 is set.
    static let hasFolderCountFlag: UInt16 = 0x0010
    var folderCount: UInt32 { get { (try? raw.u32(84)) ?? 0 } set { raw.put32(newValue, at: 84) } }
}

/// HFSPlusCatalogFile, 248 bytes.
struct HFSPlusFileRecord {
    var raw: [UInt8]

    static let lockedFlag: UInt16 = 0x0001
    /// Set on every HFS Plus file: its thread record exists.
    static let threadExistsFlag: UInt16 = 0x0002
    static let hasAttributesFlag: UInt16 = 0x0004
    /// kHFSHasLinkChainMask: a hard-link target or a directory hard link.
    static let hasLinkChainFlag: UInt16 = 0x0020

    init(raw: [UInt8]) throws {
        guard raw.count >= HFSPlusCatalogRecord.fileRecordSize, (try raw.u16(0)) == HFSPlusRecordType.file.rawValue else { throw HFSError.corrupt("bad file record") }
        self.raw = raw
    }

    init(id: UInt32, date: UInt32, textEncoding: UInt32) {
        raw = [UInt8](repeating: 0, count: HFSPlusCatalogRecord.fileRecordSize)
        raw.put16(HFSPlusRecordType.file.rawValue, at: 0)
        raw.put16(Self.threadExistsFlag, at: 2)
        raw.put32(id, at: 8)
        for offset in [12, 16, 20, 24] { raw.put32(date, at: offset) }
        raw.put32(textEncoding, at: 80)
    }

    var flags: UInt16 { (try? raw.u16(2)) ?? 0 }
    var id: UInt32 { (try? raw.u32(8)) ?? 0 }
    var createDate: UInt32 { get { (try? raw.u32(12)) ?? 0 } set { raw.put32(newValue, at: 12) } }
    /// Content modification date (attribute-modification and access dates follow it).
    var modifyDate: UInt32 { get { (try? raw.u32(16)) ?? 0 } set { raw.put32(newValue, at: 16) } }
    /// FInfo: type, creator, flags, location, reserved.
    var finderInfo: [UInt8] { get { Array(raw[48..<64]) } set { raw.put(Array(newValue.prefix(16)), at: 48) } }
    var extendedFinderInfo: [UInt8] { get { Array(raw[64..<80]) } set { raw.put(Array(newValue.prefix(16)), at: 64) } }
    var fileType: [UInt8] { Array(raw[48..<52]) }
    var creator: [UInt8] { Array(raw[52..<56]) }
    var finderFlags: UInt16 { (try? raw.u16(56)) ?? 0 }

    static func forkOffset(_ fork: HFSFork) -> Int { fork == .data ? 88 : 168 }
    func fork(_ fork: HFSFork) -> HFSPlusForkData { (try? HFSPlusForkData(bytes: raw, at: Self.forkOffset(fork))) ?? .empty }
    mutating func setFork(_ fork: HFSFork, _ data: HFSPlusForkData) { raw.put(data.encoded, at: Self.forkOffset(fork)) }
}

enum HFSPlusThreadRecord {
    static func make(type: HFSPlusRecordType, parentID: UInt32, name: [UInt16]) -> [UInt8] {
        var raw = [UInt8](repeating: 0, count: 10 + 2 * name.count)
        raw.put16(type.rawValue, at: 0)
        raw.put32(parentID, at: 4)
        raw.put16(UInt16(name.count), at: 8)
        for (i, unit) in name.enumerated() { raw.put16(unit, at: 10 + 2 * i) }
        return raw
    }
}

/// HFS Plus names: UTF-16 in Apple's canonical decomposition, compared with Apple's
/// case-folding (FastUnicodeCompare) or, on case-sensitive HFSX, by code unit.
enum HFSPlusName {
    static let maxLength = 255

    /// Apple's FastUnicodeCompare (hfs core/UnicodeWrappers.c): characters folded through
    /// the TN1150 tables; characters that fold to 0 are ignored entirely.
    static func compareCaseInsensitive(_ lhs: [UInt16], _ rhs: [UInt16]) -> Int {
        var i = 0, j = 0
        while true {
            let c1 = nextFolded(lhs, &i)
            let c2 = nextFolded(rhs, &j)
            if c1 != c2 { return c1 < c2 ? -1 : 1 }
            if c1 == 0 { return 0 }
        }
    }

    private static func nextFolded(_ units: [UInt16], _ index: inout Int) -> UInt16 {
        while index < units.count {
            let unit = units[index]
            index += 1
            if unit < 0x0100 { return HFSPlusCaseFolding.latinCaseFold[Int(unit)] }
            let table = HFSPlusCaseFolding.lowerCaseTable
            let block = table[Int(unit >> 8)]
            let folded = block == 0 ? unit : table[Int(block) + Int(unit & 0xFF)]
            if folded != 0 { return folded }
        }
        return 0
    }

    /// Apple's UnicodeBinaryCompare, used by case-sensitive HFSX volumes.
    static func compareBinary(_ lhs: [UInt16], _ rhs: [UInt16]) -> Int {
        for (a, b) in zip(lhs, rhs) where a != b { return a < b ? -1 : 1 }
        return lhs.count - rhs.count
    }

    /// The form HFS Plus stores: canonically decomposed, except the ranges Apple leaves
    /// alone (U+2000–U+2FFF, U+F900–U+FAFF, U+2F800–U+2FAFF), which keeps names created here
    /// identical to those Mac OS creates. The exclusion applies per *scalar*: an excluded
    /// combining mark doesn't stop the letter it sits on from being decomposed.
    static func encode(_ string: String) throws -> [UInt16] {
        func excluded(_ scalar: Unicode.Scalar) -> Bool {
            (0x2000...0x2FFF).contains(scalar.value) || (0xF900...0xFAFF).contains(scalar.value) || (0x2F800...0x2FAFF).contains(scalar.value)
        }
        let units: [UInt16]
        if !string.unicodeScalars.contains(where: excluded) {
            units = Array(string.decomposedStringWithCanonicalMapping.utf16)
        } else {
            var result: [UInt16] = []
            for scalar in string.unicodeScalars {
                let piece = excluded(scalar) ? String(scalar) : String(scalar).decomposedStringWithCanonicalMapping
                result += Array(piece.utf16)
            }
            units = result
        }
        guard !units.isEmpty, units.count <= maxLength, !units.contains(0x3A /* ":" */) else { throw HFSError.invalidName(string) }
        if units == [0x2E] || units == [0x2E, 0x2E] { throw HFSError.invalidName(string) }
        return units
    }

    /// The name as stored. Not recomposed: composition would also apply singleton mappings
    /// (U+212B → U+00C5, U+F900 → U+8C48), giving a name that no longer finds the item.
    static func decode(_ units: [UInt16]) -> String {
        String(decoding: units, as: UTF16.self)
    }

    /// The Mac OS text encoding classic Mac OS should use to display a name, and its bit in
    /// the volume header's encodings bitmap (TN1150 "Text Encodings").
    static func textEncoding(for string: String) -> UInt32 {
        // Single-script encodings first: the CJK ones also contain Cyrillic and Greek letters,
        // so a Russian name would otherwise be hinted as Japanese.
        let candidates: [(CFStringEncodings, UInt32)] = [
            (.macCyrillic, 7), (.macGreek, 6), (.macCentralEurRoman, 29), (.macTurkish, 35),
            (.macJapanese, 1), (.macChineseTrad, 2), (.macKorean, 3), (.macChineseSimp, 25),
        ]
        if string.data(using: .macOSRoman, allowLossyConversion: false) != nil { return 0 }
        for (cf, value) in candidates {
            let ns = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cf.rawValue)))
            if string.data(using: ns, allowLossyConversion: false) != nil { return value }
        }
        return 0
    }

    static func encodingsBitmapBit(for encoding: UInt32) -> UInt64 {
        switch encoding {
        case 0x98: return 1 << 48 // MacUkrainian
        case 0x8C: return 1 << 49 // MacFarsi
        case 0..<64: return 1 << UInt64(encoding)
        default: return 0
        }
    }
}

/// HFS Plus dates (other than the volume creation date) are GMT seconds since 1904.
enum HFSPlusDate {
    private static let epochOffset: TimeInterval = 2_082_844_800

    static var now: UInt32 { encode(Date()) }

    static func encode(_ date: Date) -> UInt32 {
        UInt32(clamping: Int64(max(0, date.timeIntervalSince1970 + epochOffset)))
    }

    static func date(_ value: UInt32) -> Date {
        Date(timeIntervalSince1970: TimeInterval(value) - epochOffset)
    }
}
