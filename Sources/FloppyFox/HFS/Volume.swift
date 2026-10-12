import Foundation

/// One catalog item as the rest of the app sees it, from either kind of volume.
struct VolumeItem: Sendable, Hashable, Identifiable {
    let id: UInt32
    let parentID: UInt32
    let name: String
    let isFolder: Bool
    let dataLength: UInt64
    let resourceLength: UInt64
    let fileType: [UInt8]
    let creator: [UInt8]
    let finderFlags: UInt16
    let isLocked: Bool
    let createDate: Date
    let modifyDate: Date
    let valence: Int

    static let invisibleFlag: UInt16 = 0x4000
    var isInvisible: Bool { finderFlags & Self.invisibleFlag != 0 }
}

/// Why a volume was opened without write access.
enum ReadOnlyCause: Sendable, Equatable {
    /// The caller asked for read-only, or the image file can't be written.
    case requested
    /// The volume's own lock (Get Info "Locked", a locked floppy).
    case locked
    /// The "unmounted cleanly" bit is clear: Mac OS (an emulator, a real Mac) has the volume
    /// mounted right now, or it wasn't ejected properly. Writing could clash with that
    /// computer's own changes; Mac OS would check the volume first.
    case notCleanlyUnmounted
    /// A Mac OS X journaled volume, whose journal this app doesn't maintain.
    case journaled
    /// Another process holds the image file's exclusive lock.
    case inUse
}

/// The operations the app performs on a volume. `HFSVolume` (Mac OS Standard) and
/// `HFSPlusVolume` (Mac OS Extended) implement them.
///
/// Changes are made in memory and written by `flush()`, atomically: new B-trees go to free
/// space and a single volume-header write switches to them. If a flush fails the volume
/// rolls back to its last committed state and the error says so. Once `close()`d, every call
/// throws `HFSError.closed`.
protocol DiskVolume: Actor {
    nonisolated var isReadOnly: Bool { get }
    nonisolated var readOnlyCause: ReadOnlyCause? { get }
    nonisolated var formatName: String { get }

    var volumeName: String { get }
    var freeBytes: UInt64 { get }

    func item(_ id: UInt32) throws -> VolumeItem
    func contents(ofFolder folderID: UInt32) throws -> [VolumeItem]
    func path(of id: UInt32) throws -> [VolumeItem]
    func child(named name: String, inFolder folderID: UInt32) -> VolumeItem?
    func readFork(_ id: UInt32, fork: HFSFork, chunkSize: Int, sink: @Sendable ([UInt8]) throws -> Void) throws
    func readForkBytes(_ id: UInt32, fork: HFSFork) throws -> [UInt8]
    func finderInfo(_ id: UInt32) throws -> (finderInfo: [UInt8], extended: [UInt8])

    func createFolder(named name: String, in parentID: UInt32) throws -> UInt32
    func createFile(named name: String, in parentID: UInt32, metadata: NewFileMetadata, dataFork: HFSForkSource, resourceFork: HFSForkSource) throws -> UInt32
    func delete(_ id: UInt32) throws
    func move(_ id: UInt32, to newParentID: UInt32, newName: String?) throws
    func copyFile(_ id: UInt32, to parentID: UInt32, name: String) throws -> UInt32
    func flush() throws
    func close()

    /// A name this volume accepts, derived from a host file name (length limits, the `:`
    /// separator, character set).
    nonisolated func validName(from hostName: String) -> String
}

extension DiskVolume {
    func readFork(_ id: UInt32, fork: HFSFork, sink: @Sendable ([UInt8]) throws -> Void) throws {
        try readFork(id, fork: fork, chunkSize: 1 << 20, sink: sink)
    }

    func move(_ id: UInt32, to newParentID: UInt32) throws {
        try move(id, to: newParentID, newName: nil)
    }
}

/// Finder metadata for a new file.
struct NewFileMetadata: Sendable {
    var fileType: [UInt8]
    var creator: [UInt8]
    /// The full 16-byte FInfo, if known (its type/creator are overridden by the fields above).
    var finderInfo: [UInt8]?
    var extendedFinderInfo: [UInt8]?
    var createDate: Date?
    var modifyDate: Date?

    init(fileType: [UInt8], creator: [UInt8], finderInfo: [UInt8]? = nil, extendedFinderInfo: [UInt8]? = nil, createDate: Date? = nil, modifyDate: Date? = nil) {
        self.fileType = fileType
        self.creator = creator
        self.finderInfo = finderInfo
        self.extendedFinderInfo = extendedFinderInfo
        self.createDate = createDate
        self.modifyDate = modifyDate
    }

    /// FInfo with this metadata's type and creator, and the Finder's on-desktop position
    /// cleared (a host or foreign position means nothing on this disk).
    func resolvedFinderInfo() -> [UInt8] {
        var info = Array((finderInfo ?? []).prefix(16))
        info += [UInt8](repeating: 0, count: 16 - info.count)
        info.replaceSubrange(0..<4, with: Self.fourCC(fileType))
        info.replaceSubrange(4..<8, with: Self.fourCC(creator))
        for i in 10..<16 { info[i] = 0 }
        return info
    }

    static func fourCC(_ code: [UInt8]) -> [UInt8] {
        Array(code.prefix(4)) + [UInt8](repeating: 0x20, count: max(0, 4 - code.count))
    }
}

/// A volume's allocation bitmap, in two versions: `working` (what the pending changes use) and
/// `committed` (what is on disk). New space is only taken from blocks free in *both*, so blocks
/// released by a delete that isn't committed yet can't be overwritten before the delete is
/// durable — and the old B-tree files stay intact until the new ones are committed.
struct AllocationMap {
    private(set) var working: [UInt8]
    private(set) var committed: [UInt8]
    let blockCount: Int
    /// Blocks past this are never handed out (HFS: Apple never allocates the final block).
    let allocatableCount: Int
    let maxRunLength: Int

    init(bitmap: [UInt8], blockCount: Int, allocatableCount: Int, maxRunLength: Int) {
        working = bitmap
        committed = bitmap
        self.blockCount = blockCount
        self.allocatableCount = allocatableCount
        self.maxRunLength = maxRunLength
    }

    private static func isSet(_ map: [UInt8], _ block: Int) -> Bool {
        map[block / 8] & (0x80 >> UInt8(block % 8)) != 0
    }

    func isUsed(_ block: Int) -> Bool { block < blockCount && Self.isSet(working, block) }

    func isAvailable(_ block: Int) -> Bool {
        block < allocatableCount && !Self.isSet(working, block) && !Self.isSet(committed, block)
    }

    /// Marks a run used or free. Runs reaching past the volume (only possible on a damaged
    /// image) are clipped rather than trusted.
    mutating func set(start: Int, count: Int, used: Bool) {
        guard start >= 0, count > 0, start < blockCount else { return }
        for block in start..<min(start + count, blockCount) {
            if used { working[block / 8] |= 0x80 >> UInt8(block % 8) } else { working[block / 8] &= ~(0x80 >> UInt8(block % 8)) }
        }
    }

    /// Population count of `map` over blocks `0..<limit`.
    private static func usedCount(_ map: [UInt8], limit: Int) -> Int {
        let fullBytes = limit / 8
        var used = 0
        for index in 0..<fullBytes { used += map[index].nonzeroBitCount }
        for block in (fullBytes * 8)..<limit where isSet(map, block) { used += 1 }
        return used
    }

    /// Free blocks after the pending changes (what the volume header records).
    var freeCount: Int { blockCount - Self.usedCount(working, limit: blockCount) }

    /// Blocks that new data may use right now.
    var availableCount: Int {
        let fullBytes = allocatableCount / 8
        var used = 0
        for index in 0..<fullBytes { used += (working[index] | committed[index]).nonzeroBitCount }
        for block in (fullBytes * 8)..<allocatableCount where !isAvailable(block) { used += 1 }
        return allocatableCount - used
    }

    /// Both versions combined: written before a commit so that neither the old nor the new
    /// structures are ever marked free on disk.
    var union: [UInt8] { zip(working, committed).map { $0 | $1 } }

    mutating func commit() { committed = working }

    mutating func rollBack(to bitmap: [UInt8]) {
        working = bitmap
        committed = bitmap
    }

    /// Free runs, skipping whole used bytes quickly.
    private func freeRuns() -> [(start: Int, count: Int)] {
        var runs: [(start: Int, count: Int)] = []
        var block = 0
        while block < allocatableCount {
            if block % 8 == 0, block + 8 <= allocatableCount, (working[block / 8] | committed[block / 8]) == 0xFF {
                block += 8
                continue
            }
            if !isAvailable(block) { block += 1; continue }
            let start = block
            while block < allocatableCount, block - start < maxRunLength {
                if block % 8 == 0, block + 8 <= allocatableCount, block - start + 8 <= maxRunLength, (working[block / 8] | committed[block / 8]) == 0 {
                    block += 8
                    continue
                }
                if !isAvailable(block) { break }
                block += 1
            }
            runs.append((start, block - start))
        }
        return runs
    }

    /// Allocates `count` blocks: one run if any is long enough (searching from `hint`), else
    /// the largest runs first. At most `maxExtents` runs when given; at least `reserve` blocks
    /// must remain available afterwards.
    mutating func allocate(_ count: Int, hint: Int, maxExtents: Int? = nil, reserve: Int = 0) throws -> [(start: Int, count: Int)] {
        guard count > 0 else { return [] }
        let available = availableCount
        guard count <= available, available - count >= reserve else { throw HFSError.volumeFull }
        let runs = freeRuns()
        if let run = runs.first(where: { $0.start >= hint && $0.count >= count }) ?? runs.first(where: { $0.count >= count }) {
            set(start: run.start, count: count, used: true)
            return [(run.start, count)]
        }
        var result: [(start: Int, count: Int)] = []
        var needed = count
        for run in runs.sorted(by: { $0.count > $1.count }) where needed > 0 {
            let take = min(run.count, needed)
            result.append((run.start, take))
            needed -= take
        }
        if needed > 0 { throw HFSError.volumeFull }
        if let maxExtents, result.count > maxExtents { throw HFSError.volumeFull }
        for run in result { set(start: run.start, count: run.count, used: true) }
        return result.sorted { $0.start < $1.start }
    }
}

/// Where a rebuilt B-tree file goes.
enum TreePlacement {
    struct Plan {
        var runs: [(start: Int, count: Int)]
        var nodeCount: Int
        /// True when there was no room for a fresh copy and the tree is rewritten over the
        /// current file (not crash-atomic; only used on volumes another system filled up).
        var inPlace: Bool
    }

    static func blocks(forNodes nodes: Int, nodeSize: Int, blockSize: Int) -> Int {
        (nodes * nodeSize + blockSize - 1) / blockSize
    }

    /// A fresh copy in free space — `roomy` sizes it at the file's current size plus room to
    /// grow, otherwise exactly what's needed — so the old tree stays valid until the volume
    /// header switches over. With `allowInPlace`, falls back to rewriting the current file
    /// when it is big enough and there is no room for a copy.
    static func plan(neededNodes: Int, nodeSize: Int, blockSize: Int, clumpBytes: Int,
                     current: [(start: Int, count: Int)], currentNodes: Int, maxExtents: Int?,
                     roomy: Bool, allowInPlace: Bool, map: inout AllocationMap, hint: Int) throws -> Plan {
        let clumpNodes = max(1, clumpBytes / nodeSize)
        let roomyNodes = max(currentNodes, neededNodes + max(neededNodes / 4, clumpNodes))
        for nodes in roomy ? [roomyNodes, neededNodes] : [neededNodes] {
            let count = blocks(forNodes: nodes, nodeSize: nodeSize, blockSize: blockSize)
            if let runs = try? map.allocate(count, hint: hint, maxExtents: maxExtents) {
                return Plan(runs: runs, nodeCount: count * blockSize / nodeSize, inPlace: false)
            }
        }
        guard allowInPlace, currentNodes >= neededNodes else { throw HFSError.volumeFull }
        return Plan(runs: current, nodeCount: currentNodes, inPlace: true)
    }
}
