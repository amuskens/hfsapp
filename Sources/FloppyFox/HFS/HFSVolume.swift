import Foundation

/// Where a fork's bytes come from when writing a file: its length and a reader for ranges.
struct HFSForkSource: Sendable {
    let length: UInt64
    let read: @Sendable (_ offset: UInt64, _ count: Int) throws -> [UInt8]

    static let empty = HFSForkSource(length: 0) { _, _ in [] }

    init(length: UInt64, read: @escaping @Sendable (_ offset: UInt64, _ count: Int) throws -> [UInt8]) {
        self.length = length
        self.read = read
    }

    init(bytes: [UInt8]) {
        self.init(length: UInt64(bytes.count)) { offset, count in
            Array(bytes[Int(offset)..<(Int(offset) + count)])
        }
    }

    /// Streams `length` bytes stored in `runs` (device position and byte count of each extent)
    /// — for copying a file on the same volume without holding its forks in memory. Safe while
    /// the copy is written: the source's blocks stay allocated, so the copy can't take them.
    init(length: UInt64, runs: [(position: UInt64, bytes: UInt64)], device: BlockDevice) throws {
        guard runs.reduce(0, { $0 + $1.bytes }) >= length else { throw HFSError.corrupt("a file is shorter on disk than its catalog entry says") }
        // Only read synchronously inside the volume actor's own createFile, which owns `device`.
        nonisolated(unsafe) let device = device
        self.init(length: length) { offset, count in
            var result: [UInt8] = []
            result.reserveCapacity(count)
            var position = offset, remaining = UInt64(count), base: UInt64 = 0
            for run in runs where remaining > 0 {
                if position < base + run.bytes {
                    let take = min(remaining, base + run.bytes - position)
                    result += try device.read(at: run.position + (position - base), count: Int(take))
                    position += take
                    remaining -= take
                }
                base += run.bytes
            }
            return result
        }
    }
}

/// A classic HFS (Mac OS Standard) volume opened directly from an image file — no kernel
/// filesystem, no external tools, so it works inside the App Sandbox.
///
/// The catalog and extents-overflow trees are held in memory as sorted record arrays, along
/// with the allocation bitmap. Mutations edit those; `flush()` commits them atomically:
///
/// 1. new file data is already in blocks that were free on disk (`AllocationMap`);
/// 2. freshly built B-trees are written to *other* free blocks;
/// 3. the bitmap is written with both old and new structures marked in use;
/// 4. one write of the master directory block switches to the new trees — the commit;
/// 5. the bitmap is rewritten with the old trees' blocks released.
///
/// A crash at any point leaves either the old or the new volume, at worst with some blocks
/// marked in use that nothing references (which fsck / Disk First Aid tidies up). If a flush
/// fails, the in-memory state rolls back to the last commit.
actor HFSVolume: DiskVolume {
    nonisolated let isReadOnly: Bool
    nonisolated let readOnlyCause: ReadOnlyCause?
    nonisolated let formatName = "Mac OS Standard"
    nonisolated var isLocked: Bool { readOnlyCause == .locked }

    private let device: BlockDevice
    private let blockSize: Int
    private let blockCount: Int
    private let firstBlockOffset: UInt64

    private var mdb: MasterDirectoryBlock
    private var allocation: AllocationMap
    private var catalog: [CatalogRecord]
    private var extentsRecords: [(key: ExtentsKey, record: ExtentRecord)]
    private var catalogHeader: BTree.Header
    private var extentsHeader: BTree.Header
    private var keyByID: [UInt32: CatalogKey] = [:]

    /// Everything as of the last commit, for rollback.
    private struct Committed {
        var mdb: MasterDirectoryBlock
        var bitmap: [UInt8]
        var catalog: [CatalogRecord]
        var extentsRecords: [(key: ExtentsKey, record: ExtentRecord)]
        var catalogHeader: BTree.Header
        var extentsHeader: BTree.Header
        var keyByID: [UInt32: CatalogKey]
    }
    private var committed: Committed!
    /// The MDB sector as this engine last saw or wrote it; anything else on disk means
    /// another program wrote to the volume.
    private var lastKnownMDBSector: [UInt8]
    private var dirty = false
    private var markedInUse = false
    /// The volume needs the check Mac OS runs on a volume that wasn't unmounted cleanly
    /// (it was opened that way on request, or its bitmap was missing allocations), so saves
    /// leave its "unmounted cleanly" bit clear rather than vouching for it.
    private let leaveForCheck: Bool
    private var isClosed = false
    /// Set when a save was cut short while rewriting the trees in place: the disk needs
    /// checking (Disk First Aid / fsck) before anything else is written to it.
    private var needsRepair = false

    /// `forcedReadOnly` opens the volume without write access for that reason; otherwise it is
    /// writable unless locked or not cleanly unmounted (`allowUncleanVolume` overrides the
    /// latter, at the user's request).
    init(device: BlockDevice, forcedReadOnly: ReadOnlyCause? = nil, allowUncleanVolume: Bool = false) throws {
        self.device = device
        guard device.length >= 1536 else { throw HFSError.notHFS }
        let sector = try device.read(at: 1024, count: 512)
        let mdb = try MasterDirectoryBlock(sector: sector)
        guard mdb.embeddedSignature != MasterDirectoryBlock.embeddedHFSPlusSignature else {
            throw HFSError.unsupported("Mac OS Extended (HFS+) volumes")
        }
        let blockSize = Int(mdb.allocationBlockSize)
        guard blockSize >= 512, blockSize % 512 == 0, mdb.allocationBlockCount > 0 else {
            throw HFSError.corrupt("bad allocation block size")
        }
        let firstBlockOffset = UInt64(mdb.firstAllocationSector) * 512
        guard firstBlockOffset + UInt64(mdb.allocationBlockCount) * UInt64(blockSize) <= device.length else {
            throw HFSError.corrupt("volume is larger than its image")
        }

        var cause: ReadOnlyCause?
        if let forcedReadOnly {
            cause = forcedReadOnly
        } else if !device.isWritable {
            cause = .requested
        } else if mdb.attributes & (MasterDirectoryBlock.softwareLockBit | MasterDirectoryBlock.hardwareLockBit) != 0 {
            cause = .locked
        } else if mdb.attributes & MasterDirectoryBlock.unmountedCleanlyBit == 0 && !allowUncleanVolume {
            cause = .notCleanlyUnmounted
        }
        self.readOnlyCause = cause
        self.isReadOnly = cause != nil
        self.mdb = mdb
        self.lastKnownMDBSector = sector
        self.blockSize = blockSize
        self.blockCount = Int(mdb.allocationBlockCount)
        self.firstBlockOffset = firstBlockOffset

        let bitmap = try device.read(at: UInt64(mdb.bitmapStartSector) * 512, count: (Int(mdb.allocationBlockCount) + 7) / 8)
        // Apple's HFS never allocates a volume's final allocation block, and fsck_hfs flags any
        // extent that reaches it, although the MDB still counts it as free.
        self.allocation = AllocationMap(bitmap: bitmap, blockCount: Int(mdb.allocationBlockCount), allocatableCount: Int(mdb.allocationBlockCount) - 1, maxRunLength: Int(UInt16.max))

        let extentsFork = Self.extentList(mdb.extentsFileExtents)
        let extentsSize = Int(mdb.extentsFileSize)
        let (extentsHeader, extentsRaw) = try BTree.readLeafRecords { node in
            try Self.readTreeNode(node, fork: extentsFork, forkSize: extentsSize, device: device, firstBlockOffset: firstBlockOffset, blockSize: blockSize)
        }
        var extentsRecords: [(key: ExtentsKey, record: ExtentRecord)] = []
        for raw in extentsRaw {
            let (key, dataOffset) = try ExtentsKey.parse(raw, at: 0)
            extentsRecords.append((key, try ExtentRecord(bytes: raw, at: dataOffset)))
        }
        self.extentsHeader = extentsHeader
        self.extentsRecords = extentsRecords

        let catalogFork = Self.forkExtents(fileID: HFSCatalogID.catalogFile, fork: .data, first: mdb.catalogFileExtents, overflow: extentsRecords)
        let catalogSize = Int(mdb.catalogFileSize)
        let (catalogHeader, catalogRaw) = try BTree.readLeafRecords { node in
            try Self.readTreeNode(node, fork: catalogFork, forkSize: catalogSize, device: device, firstBlockOffset: firstBlockOffset, blockSize: blockSize)
        }
        var catalog: [CatalogRecord] = []
        catalog.reserveCapacity(catalogRaw.count)
        for raw in catalogRaw {
            let (key, dataOffset) = try CatalogKey.parse(raw, at: 0)
            guard dataOffset < raw.count else { throw HFSError.corrupt("catalog record has no data") }
            catalog.append(CatalogRecord(key: key, data: Array(raw[dataOffset...])))
        }
        for i in catalog.indices.dropFirst() where CatalogKey.compare(catalog[i - 1].key, catalog[i].key) >= 0 {
            throw HFSError.corrupt("catalog records are out of order")
        }
        self.catalogHeader = catalogHeader
        self.catalog = catalog

        // Every ID must be unique and no folder may be its own parent; otherwise walking the
        // hierarchy (moves, recursive copies and deletes) could loop forever.
        var keyByID: [UInt32: CatalogKey] = [:]
        for record in catalog {
            let id: UInt32
            switch record.type {
            case .folder:
                guard let folder = try? FolderRecord(raw: record.data) else { continue }
                id = folder.id
                guard id != record.key.parentID else { throw HFSError.corrupt("a folder is its own parent") }
            case .file:
                guard let file = try? FileRecord(raw: record.data) else { continue }
                id = file.id
            default:
                continue
            }
            guard keyByID.updateValue(record.key, forKey: id) == nil else { throw HFSError.corrupt("two catalog entries share ID \(id)") }
        }
        guard let rootKey = keyByID[HFSCatalogID.rootFolder], rootKey.parentID == HFSCatalogID.rootParent else {
            throw HFSError.corrupt("root folder is missing")
        }
        // No extent may reach past the volume: one that does would make deletes and the
        // commit's bookkeeping act on blocks that don't exist.
        let blocks = Int(mdb.allocationBlockCount)
        func checkExtents(_ record: ExtentRecord) throws {
            for extent in record.extents where extent.blockCount > 0 && Int(extent.startBlock) + Int(extent.blockCount) > blocks {
                throw HFSError.corrupt("an extent lies outside the volume")
            }
        }
        try checkExtents(mdb.catalogFileExtents)
        try checkExtents(mdb.extentsFileExtents)
        // Each tree's file must be covered by its extents: a save in place writes all of it.
        for (fork, size) in [(catalogFork, catalogSize), (extentsFork, extentsSize)]
        where fork.reduce(0, { $0 + Int($1.blockCount) }) * blockSize < size || size % BTree.nodeSize512 != 0 {
            throw HFSError.corrupt("a B-tree file is larger than its extents")
        }
        for entry in extentsRecords { try checkExtents(entry.record) }
        for record in catalog where record.type == .file {
            guard let file = try? FileRecord(raw: record.data) else { continue }
            try checkExtents(file.extents(.data))
            try checkExtents(file.extents(.resource))
        }
        self.keyByID = keyByID
        var known: [(start: Int, count: Int)] = []
        func add(_ record: ExtentRecord) { known += record.extents.map { (Int($0.startBlock), Int($0.blockCount)) } }
        add(mdb.catalogFileExtents)
        add(mdb.extentsFileExtents)
        for entry in extentsRecords { add(entry.record) }
        for record in catalog where record.type == .file {
            guard let file = try? FileRecord(raw: record.data) else { continue }
            add(file.extents(.data))
            add(file.extents(.resource))
        }
        let underAllocated = allocation.claimKnownUsed(known)
        self.leaveForCheck = underAllocated || mdb.attributes & MasterDirectoryBlock.unmountedCleanlyBit == 0
        self.committed = Committed(mdb: mdb, bitmap: allocation.committed, catalog: catalog, extentsRecords: extentsRecords,
                                   catalogHeader: catalogHeader, extentsHeader: extentsHeader, keyByID: keyByID)
    }

    // MARK: - Reading

    var volumeName: String { mdb.volumeName.string }
    /// Room for new files: free space, less what the next save needs to write its trees safely.
    var freeBytes: UInt64 { UInt64(allocation.dataAvailableCount(keeping: saveRoom)) * UInt64(blockSize) }
    var totalBytes: UInt64 { UInt64(blockCount) * UInt64(blockSize) }

    nonisolated func validName(from hostName: String) -> String {
        DiskImageManager.classicHFSName(from: hostName)
    }

    func item(_ id: UInt32) throws -> VolumeItem {
        try checkOpen()
        guard let key = keyByID[id], let index = index(of: key) else { throw HFSError.notFound("Item \(id)") }
        return try makeItem(catalog[index])
    }

    func contents(ofFolder folderID: UInt32) throws -> [VolumeItem] {
        let folder = try item(folderID)
        guard folder.isFolder else { throw HFSError.notFound("Folder \(folder.name)") }
        return try childRecordIndices(of: folderID).map { try makeItem(catalog[$0]) }
    }

    /// Folders from the volume root down to `id` (excluding the root itself).
    func path(of id: UInt32) throws -> [VolumeItem] {
        var result: [VolumeItem] = []
        var current = id
        while current != HFSCatalogID.rootFolder {
            let item = try item(current)
            result.insert(item, at: 0)
            current = item.parentID
            if result.count > keyByID.count { throw HFSError.corrupt("folder hierarchy has a cycle") }
        }
        return result
    }

    func child(named name: String, inFolder folderID: UInt32) -> VolumeItem? {
        guard !isClosed, let hfsName = try? HFSName(name), let index = index(of: CatalogKey(parentID: folderID, name: hfsName.bytes)) else { return nil }
        return try? makeItem(catalog[index])
    }

    /// Streams a fork to `sink` in chunks of at most `chunkSize` bytes. `sink` may throw (for
    /// example `CancellationError`) to stop early.
    func readFork(_ id: UInt32, fork: HFSFork, chunkSize: Int, sink: @Sendable ([UInt8]) throws -> Void) throws {
        let file = try fileRecord(id)
        let length = UInt64(file.logicalLength(fork))
        let extents = Self.forkExtents(fileID: id, fork: fork, first: file.extents(fork), overflow: extentsRecords)
        guard UInt64(extents.reduce(0) { $0 + Int($1.blockCount) }) * UInt64(blockSize) >= length else {
            throw HFSError.corrupt("a file is shorter on disk than its catalog entry says")
        }
        var remaining = length
        for extent in extents where remaining > 0 {
            var position = blockPosition(extent.startBlock)
            var extentRemaining = min(UInt64(extent.blockCount) * UInt64(blockSize), remaining)
            while extentRemaining > 0 {
                let count = Int(min(UInt64(chunkSize), extentRemaining))
                try sink(try device.read(at: position, count: count))
                position += UInt64(count)
                extentRemaining -= UInt64(count)
                remaining -= UInt64(count)
            }
        }
    }

    func readForkBytes(_ id: UInt32, fork: HFSFork) throws -> [UInt8] {
        let collected = ByteCollector()
        try readFork(id, fork: fork, chunkSize: 1 << 20) { collected.append($0) }
        return collected.bytes
    }

    func finderInfo(_ id: UInt32) throws -> (finderInfo: [UInt8], extended: [UInt8]) {
        let file = try fileRecord(id)
        return (file.finderInfo, file.extendedFinderInfo)
    }

    /// A fork's full extent list, for diagnostics and tests.
    func extents(of id: UInt32, fork: HFSFork) throws -> [ExtentDescriptor] {
        Self.forkExtents(fileID: id, fork: fork, first: try fileRecord(id).extents(fork), overflow: extentsRecords)
    }

    /// Overflow records, for diagnostics and tests.
    var overflowRecords: [(key: ExtentsKey, record: ExtentRecord)] { extentsRecords }

    // MARK: - Writing

    @discardableResult
    func createFolder(named name: String, in parentID: UInt32) throws -> UInt32 {
        try checkWritable()
        let hfsName = try validated(name)
        try checkCanAdd(hfsName, to: parentID)
        let id = try allocateCatalogID()
        let now = HFSDate.now
        insert(CatalogRecord(key: CatalogKey(parentID: parentID, name: hfsName.bytes), data: FolderRecord(id: id, date: now).raw))
        insert(CatalogRecord(key: CatalogKey(parentID: id, name: []), data: ThreadRecord.make(type: .folderThread, parentID: parentID, name: hfsName.bytes)))
        keyByID[id] = CatalogKey(parentID: parentID, name: hfsName.bytes)
        touchFolder(parentID, date: now)
        dirty = true
        return id
    }

    /// Writes both forks to blocks that are free on disk, then adds the catalog entry. On any
    /// failure (including cancellation thrown by a fork reader) the blocks are released and
    /// nothing else changes.
    @discardableResult
    func createFile(named name: String, in parentID: UInt32, metadata: NewFileMetadata, dataFork: HFSForkSource, resourceFork: HFSForkSource) throws -> UInt32 {
        try checkWritable()
        let hfsName = try validated(name)
        try checkCanAdd(hfsName, to: parentID)
        // Classic Mac OS reads fork lengths as signed 32-bit values.
        let limit = UInt64(Int32.max)
        guard dataFork.length <= limit, resourceFork.length <= limit else { throw HFSError.volumeFull }
        // Before writing any data: has another program written the volume meanwhile?
        try checkNotModifiedElsewhere()
        let allocationBefore = allocation
        let extentsBefore = extentsRecords
        let mdbBefore = mdb
        do {
            let room = saveRoom
            let dataExtents = try writeNewFork(dataFork, keeping: room)
            let resourceExtents = try writeNewFork(resourceFork, keeping: room)
            let id = try allocateCatalogID()
            let now = HFSDate.now
            var file = FileRecord(id: id, date: now, type: metadata.fileType, creator: metadata.creator)
            file.finderInfo = metadata.resolvedFinderInfo()
            if let extended = metadata.extendedFinderInfo { file.extendedFinderInfo = extended }
            if let created = metadata.createDate { file.createDate = HFSDate.encode(created) }
            if let modified = metadata.modifyDate { file.modifyDate = HFSDate.encode(modified) }
            store(dataExtents, fork: .data, length: dataFork.length, fileID: id, in: &file)
            store(resourceExtents, fork: .resource, length: resourceFork.length, fileID: id, in: &file)
            let key = CatalogKey(parentID: parentID, name: hfsName.bytes)
            insert(CatalogRecord(key: key, data: file.raw))
            keyByID[id] = key
            touchFolder(parentID, date: now)
            dirty = true
            return id
        } catch {
            allocation = allocationBefore
            extentsRecords = extentsBefore
            mdb = mdbBefore
            throw error
        }
    }

    /// Deletes a file, or a folder that is already empty. Its blocks stay reserved until the
    /// next commit, so the deleted data can't be overwritten before the delete is durable.
    func delete(_ id: UInt32) throws {
        try checkWritable()
        guard id != HFSCatalogID.rootFolder, let key = keyByID[id], let index = index(of: key) else { throw HFSError.notFound("Item \(id)") }
        let record = catalog[index]
        switch record.type {
        case .file:
            let file = try FileRecord(raw: record.data)
            for fork in [HFSFork.data, .resource] {
                for extent in Self.forkExtents(fileID: id, fork: fork, first: file.extents(fork), overflow: extentsRecords) {
                    allocation.set(start: Int(extent.startBlock), count: Int(extent.blockCount), used: false)
                }
            }
            extentsRecords.removeAll { $0.key.fileID == id }
            catalog.remove(at: index)
            if file.flags & FileRecord.threadExistsFlag != 0, let thread = self.index(of: CatalogKey(parentID: id, name: [])) {
                catalog.remove(at: thread)
            }
        case .folder:
            guard childRecordIndices(of: id).isEmpty else { throw HFSError.directoryNotEmpty(HFSName(bytes: key.name).string) }
            catalog.remove(at: index)
            if let thread = self.index(of: CatalogKey(parentID: id, name: [])) {
                catalog.remove(at: thread)
            }
        default:
            throw HFSError.corrupt("unexpected catalog record type")
        }
        keyByID[id] = nil
        touchFolder(key.parentID, date: HFSDate.now)
        dirty = true
    }

    /// Moves and/or renames an item. A folder can't move into itself or one of its own
    /// subfolders (that would detach it from the tree).
    func move(_ id: UInt32, to newParentID: UInt32, newName: String?) throws {
        try checkWritable()
        guard id != HFSCatalogID.rootFolder, let oldKey = keyByID[id], let oldIndex = index(of: oldKey) else { throw HFSError.notFound("Item \(id)") }
        let name = try newName.map(validated) ?? HFSName(bytes: oldKey.name)
        guard try item(newParentID).isFolder else { throw HFSError.invalidMove("The destination is not a folder.") }
        let record = catalog[oldIndex]
        if record.type == .folder, try newParentID == id || path(of: newParentID).contains(where: { $0.id == id }) {
            throw HFSError.invalidMove("A folder can't be moved into itself.")
        }
        let newKey = CatalogKey(parentID: newParentID, name: name.bytes)
        if newKey == oldKey { return }
        if let existing = index(of: newKey), existing != oldIndex { throw HFSError.alreadyExists(name.string) }

        catalog.remove(at: oldIndex)
        insert(CatalogRecord(key: newKey, data: record.data))
        keyByID[id] = newKey
        let threadType: CatalogRecordType? = record.type == .folder ? .folderThread
            : ((try? FileRecord(raw: record.data))?.flags ?? 0) & FileRecord.threadExistsFlag != 0 ? .fileThread : nil
        if let threadType, let thread = index(of: CatalogKey(parentID: id, name: [])) {
            catalog[thread].data = ThreadRecord.make(type: threadType, parentID: newParentID, name: name.bytes)
        }
        let now = HFSDate.now
        touchFolder(oldKey.parentID, date: now)
        touchFolder(newParentID, date: now)
        dirty = true
    }

    /// Duplicates a file within the volume (both forks and all Finder info).
    @discardableResult
    func copyFile(_ id: UInt32, to parentID: UInt32, name: String) throws -> UInt32 {
        let source = try fileRecord(id)
        func stream(_ fork: HFSFork) throws -> HFSForkSource {
            let runs = Self.forkExtents(fileID: id, fork: fork, first: source.extents(fork), overflow: extentsRecords)
                .map { (position: blockPosition($0.startBlock), bytes: UInt64($0.blockCount) * UInt64(blockSize)) }
            return try HFSForkSource(length: UInt64(source.logicalLength(fork)), runs: runs, device: device)
        }
        let metadata = NewFileMetadata(fileType: source.fileType, creator: source.creator, finderInfo: source.finderInfo,
                                       extendedFinderInfo: source.extendedFinderInfo,
                                       createDate: HFSDate.date(source.createDate), modifyDate: HFSDate.date(source.modifyDate))
        return try createFile(named: name, in: parentID, metadata: metadata, dataFork: try stream(.data), resourceFork: try stream(.resource))
    }

    /// Commits all pending changes (see the type's documentation). On failure the pending
    /// changes are discarded and the volume is back at its last committed state.
    func flush() throws {
        try checkOpen()
        guard dirty else { return }
        try checkWritable()
        progress = .nothingWritten
        do {
            try commit()
        } catch {
            switch progress {
            case .rewritingInPlace:
                // The old trees are partly overwritten: neither state is intact on disk, so
                // rolling back would only pretend. Keep the intended state, refuse further
                // writes, and tell the user the disk needs checking.
                needsRepair = true
                throw HFSError.saveIncomplete
            case .markedInUse, .nothingWritten:
                rollBack()
                if progress == .markedInUse {
                    // Nothing of the new state was committed: put the clean header back so
                    // the volume doesn't look like it crashed.
                    try? device.write(committed.mdb.raw, at: 1024)
                    try? device.synchronize()
                    lastKnownMDBSector = committed.mdb.raw
                    markedInUse = false
                }
                throw error
            }
        }
    }

    /// Releases the image. Every later call throws `HFSError.closed`, so an operation that
    /// was still in flight when the image was ejected can't write to it afterwards.
    func close() {
        isClosed = true
        device.close()
    }

    // MARK: - Commit

    private enum CommitProgress {
        case nothingWritten
        case markedInUse
        case rewritingInPlace
    }
    private var progress = CommitProgress.nothingWritten

    private struct Layout {
        var catalog: TreePlacement.Plan
        var catalogRuns: [ExtentDescriptor]
        var extents: TreePlacement.Plan
        var extentsRuns: [ExtentDescriptor]
        var catalogRecords: [BTree.BuildRecord]
        var extentsBuild: [BTree.BuildRecord]
    }

    /// Chooses where both trees go: fresh copies at a roomy size, then fresh copies at the
    /// exact size, and only then rewriting in place (when the volume has no room for a copy).
    private func planLayout() throws -> Layout {
        let allocationBefore = allocation
        let extentsBefore = extentsRecords
        var lastError: Error = HFSError.volumeFull
        for (roomy, allowInPlace) in [(true, false), (false, false), (false, true)] {
            allocation = allocationBefore
            extentsRecords = extentsBefore
            do {
                return try planLayout(roomy: roomy, allowInPlace: allowInPlace)
            } catch {
                lastError = error
            }
        }
        allocation = allocationBefore
        extentsRecords = extentsBefore
        throw lastError
    }

    private func planLayout(roomy: Bool, allowInPlace: Bool) throws -> Layout {
        let oldCatalog = Self.forkExtents(fileID: HFSCatalogID.catalogFile, fork: .data, first: committed.mdb.catalogFileExtents, overflow: committed.extentsRecords)
        let oldExtents = Self.extentList(committed.mdb.extentsFileExtents)

        // The catalog; extents beyond the MDB's three go into the extents tree.
        let catalogRecords = catalog.map { BTree.BuildRecord(leafBytes: $0.key.leafEncoded + $0.data, indexKey: $0.key.indexEncoded) }
        let catalogPlan = try TreePlacement.plan(
            neededNodes: try BTree.minimumNodeCount(records: catalogRecords, nodeSize: BTree.nodeSize512),
            nodeSize: BTree.nodeSize512, blockSize: blockSize, clumpBytes: Int(mdb.catalogClumpSize),
            current: oldCatalog.map { (Int($0.startBlock), Int($0.blockCount)) }, currentNodes: Int(committed.mdb.catalogFileSize) / BTree.nodeSize512,
            maxExtents: nil, compactRuns: 3, roomy: roomy, allowInPlace: allowInPlace, map: &allocation, hint: Int(mdb.allocationPointer)
        )
        let catalogRuns = catalogPlan.runs.map { ExtentDescriptor(startBlock: UInt16($0.start), blockCount: UInt16($0.count)) }
        extentsRecords.removeAll { $0.key.fileID == HFSCatalogID.catalogFile && $0.key.fork == .data }
        addOverflow(Array(catalogRuns.dropFirst(3)), fork: .data, fileID: HFSCatalogID.catalogFile, startingAt: catalogRuns.prefix(3).reduce(0) { $0 + Int($1.blockCount) })

        // The extents tree; it can't overflow, so at most three extents.
        let extentsBuild = extentsRecords.map { BTree.BuildRecord(leafBytes: $0.key.encoded + $0.record.encoded, indexKey: $0.key.encoded) }
        let extentsPlan = try TreePlacement.plan(
            neededNodes: try BTree.minimumNodeCount(records: extentsBuild, nodeSize: BTree.nodeSize512),
            nodeSize: BTree.nodeSize512, blockSize: blockSize, clumpBytes: Int(mdb.extentsClumpSize),
            current: oldExtents.map { (Int($0.startBlock), Int($0.blockCount)) }, currentNodes: Int(committed.mdb.extentsFileSize) / BTree.nodeSize512,
            maxExtents: 3, compactRuns: 3, roomy: roomy, allowInPlace: allowInPlace, map: &allocation, hint: Int(mdb.allocationPointer)
        )
        guard extentsPlan.runs.count <= 3 else { throw HFSError.catalogFull }
        let extentsRuns = extentsPlan.runs.map { ExtentDescriptor(startBlock: UInt16($0.start), blockCount: UInt16($0.count)) }

        // Old trees are released in the working bitmap (still in use on disk until commit).
        if !catalogPlan.inPlace {
            for extent in oldCatalog { allocation.set(start: Int(extent.startBlock), count: Int(extent.blockCount), used: false) }
        }
        if !extentsPlan.inPlace {
            for extent in oldExtents { allocation.set(start: Int(extent.startBlock), count: Int(extent.blockCount), used: false) }
        }
        return Layout(catalog: catalogPlan, catalogRuns: catalogRuns, extents: extentsPlan, extentsRuns: extentsRuns,
                      catalogRecords: catalogRecords, extentsBuild: extentsBuild)
    }

    private func commit() throws {
        try checkNotModifiedElsewhere()
        recomputeCounts()

        // Everything that can fail for lack of space happens before anything is written.
        let layout = try planLayout()
        let extentsNodes = try BTree.build(records: layout.extentsBuild, nodeCount: layout.extents.nodeCount, template: extentsHeader)
        let catalogNodes = try BTree.build(records: layout.catalogRecords, nodeCount: layout.catalog.nodeCount, template: catalogHeader)

        // 1. Mark the volume in use. That header already carries the advanced next-ID, so IDs
        //    handed out in this batch are never reused, whatever happens next.
        try markVolumeInUse()
        progress = .markedInUse
        // 2. The bitmap with old structures, new trees and new file data all in use.
        try device.write(allocation.union, at: UInt64(mdb.bitmapStartSector) * 512)
        try device.synchronize()
        // 3. The new trees: into free space, or over the old ones if there was no room.
        if layout.catalog.inPlace || layout.extents.inPlace { progress = .rewritingInPlace }
        try writeNodes(extentsNodes, to: layout.extentsRuns)
        try writeNodes(catalogNodes, to: layout.catalogRuns)
        try device.synchronize()

        // 4. The commit: one MDB write switches to the new trees.
        mdb.catalogFileExtents = ExtentRecord(extents: Array(layout.catalogRuns.prefix(3)))
        mdb.catalogFileSize = UInt32(layout.catalog.nodeCount * BTree.nodeSize512)
        mdb.extentsFileExtents = ExtentRecord(extents: layout.extentsRuns)
        mdb.extentsFileSize = UInt32(layout.extents.nodeCount * BTree.nodeSize512)
        mdb.freeBlockCount = UInt16(allocation.freeCount)
        mdb.modifyDate = HFSDate.now
        mdb.writeCount &+= 1
        if leaveForCheck {
            mdb.attributes &= ~MasterDirectoryBlock.unmountedCleanlyBit
        } else {
            mdb.attributes |= MasterDirectoryBlock.unmountedCleanlyBit
        }
        try device.write(mdb.raw, at: 1024)
        try device.synchronize()
        lastKnownMDBSector = mdb.raw
        markedInUse = false
        progress = .nothingWritten

        // Committed.
        extentsHeader = try BTree.Header(raw: try BTree.records(of: extentsNodes[0])[0])
        catalogHeader = try BTree.Header(raw: try BTree.records(of: catalogNodes[0])[0])
        allocation.commit()
        committed = Committed(mdb: mdb, bitmap: allocation.committed, catalog: catalog, extentsRecords: extentsRecords,
                              catalogHeader: catalogHeader, extentsHeader: extentsHeader, keyByID: keyByID)
        dirty = false

        // Tidy-up. The changes are already saved, so a failure here isn't reported as one:
        // it can only leave the spare MDB a commit behind or some blocks marked in use that
        // nothing references, both of which the next flush (or Disk First Aid) puts right.
        try? writeAlternateMDB()
        try? device.synchronize()
        try? device.write(allocation.working, at: UInt64(mdb.bitmapStartSector) * 512)
        try? device.synchronize()
    }

    private func rollBack() {
        mdb = committed.mdb
        allocation.rollBack(to: committed.bitmap)
        catalog = committed.catalog
        extentsRecords = committed.extentsRecords
        catalogHeader = committed.catalogHeader
        extentsHeader = committed.extentsHeader
        keyByID = committed.keyByID
        dirty = false
    }

    /// Refuses to write if the MDB on disk isn't the one this engine last saw: some other
    /// program (an emulator, another app) changed the volume meanwhile.
    private func checkNotModifiedElsewhere() throws {
        let onDisk = try device.read(at: 1024, count: 512)
        guard onDisk == lastKnownMDBSector else { throw HFSError.modifiedElsewhere }
    }

    /// Clears the "unmounted cleanly" bit on disk before the first write of a batch, so a
    /// crash midway leaves Mac OS (and fsck) a signal to check the volume.
    private func markVolumeInUse() throws {
        guard !markedInUse else { return }
        var inUse = committed.mdb
        inUse.attributes &= ~MasterDirectoryBlock.unmountedCleanlyBit
        inUse.nextCatalogID = max(committed.mdb.nextCatalogID, mdb.nextCatalogID)
        try device.write(inUse.raw, at: 1024)
        try device.synchronize()
        lastKnownMDBSector = inUse.raw
        markedInUse = true
    }

    private func writeAlternateMDB() throws {
        // The spare MDB lives in the second-to-last sector — but only touch it where one exists.
        let alternate = device.length / 512 * 512 - 1024
        if alternate > 1024, let sector = try? device.read(at: alternate, count: 512), (try? sector.u16(0)) == MasterDirectoryBlock.signature {
            try device.write(mdb.raw, at: alternate)
        }
    }

    private func writeNodes(_ nodes: [[UInt8]], to extents: [ExtentDescriptor]) throws {
        for (number, node) in nodes.enumerated() {
            guard let position = Self.forkPosition(number * BTree.nodeSize512, extents: extents, firstBlockOffset: firstBlockOffset, blockSize: blockSize) else {
                throw HFSError.corrupt("B-tree file is shorter than its size")
            }
            try device.write(node, at: position)
        }
    }

    // MARK: - Internals: catalog

    private func index(of key: CatalogKey) -> Int? {
        let position = lowerBound(key)
        return position < catalog.count && CatalogKey.compare(catalog[position].key, key) == 0 ? position : nil
    }

    private func lowerBound(_ key: CatalogKey) -> Int {
        var low = 0, high = catalog.count
        while low < high {
            let mid = (low + high) / 2
            if CatalogKey.compare(catalog[mid].key, key) < 0 { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private func insert(_ record: CatalogRecord) {
        catalog.insert(record, at: lowerBound(record.key))
    }

    /// Indices of the folder and file records directly inside `folderID` (thread excluded).
    private func childRecordIndices(of folderID: UInt32) -> [Int] {
        var result: [Int] = []
        var position = lowerBound(CatalogKey(parentID: folderID, name: []))
        while position < catalog.count, catalog[position].key.parentID == folderID {
            if catalog[position].type == .folder || catalog[position].type == .file { result.append(position) }
            position += 1
        }
        return result
    }

    private func fileRecord(_ id: UInt32) throws -> FileRecord {
        try checkOpen()
        guard let key = keyByID[id], let index = index(of: key), catalog[index].type == .file else { throw HFSError.notFound("File \(id)") }
        return try FileRecord(raw: catalog[index].data)
    }

    private func makeItem(_ record: CatalogRecord) throws -> VolumeItem {
        let name = HFSName(bytes: record.key.name).string
        switch record.type {
        case .folder:
            let folder = try FolderRecord(raw: record.data)
            return VolumeItem(
                id: folder.id, parentID: record.key.parentID, name: name, isFolder: true,
                dataLength: 0, resourceLength: 0, fileType: [], creator: [], finderFlags: folder.finderFlags, isLocked: false,
                createDate: HFSDate.date(folder.createDate), modifyDate: HFSDate.date(folder.modifyDate),
                valence: childRecordIndices(of: folder.id).count
            )
        case .file:
            let file = try FileRecord(raw: record.data)
            return VolumeItem(
                id: file.id, parentID: record.key.parentID, name: name, isFolder: false,
                dataLength: UInt64(file.logicalLength(.data)), resourceLength: UInt64(file.logicalLength(.resource)),
                fileType: file.fileType, creator: file.creator, finderFlags: file.finderFlags, isLocked: file.isLocked,
                createDate: HFSDate.date(file.createDate), modifyDate: HFSDate.date(file.modifyDate), valence: 0
            )
        default:
            throw HFSError.corrupt("unexpected catalog record type")
        }
    }

    private func checkOpen() throws {
        if isClosed { throw HFSError.closed }
    }

    private func checkWritable() throws {
        try checkOpen()
        if isReadOnly { throw HFSError.readOnly }
        if needsRepair { throw HFSError.saveIncomplete }
    }

    private func validated(_ name: String) throws -> HFSName {
        let hfsName = try HFSName(name)
        // Apple's fsck_hfs treats "." and ".." as illegal names (it renames them).
        if hfsName.bytes == [0x2E] || hfsName.bytes == [0x2E, 0x2E] { throw HFSError.invalidName(name) }
        return hfsName
    }

    private func checkCanAdd(_ name: HFSName, to parentID: UInt32) throws {
        guard try item(parentID).isFolder else { throw HFSError.notFound("Folder \(parentID)") }
        if index(of: CatalogKey(parentID: parentID, name: name.bytes)) != nil { throw HFSError.alreadyExists(name.string) }
    }

    private func allocateCatalogID() throws -> UInt32 {
        let id = max(mdb.nextCatalogID, HFSCatalogID.firstUserID)
        guard id < UInt32.max else { throw HFSError.catalogFull }
        mdb.nextCatalogID = id + 1
        return id
    }

    private func touchFolder(_ id: UInt32, date: UInt32) {
        guard let key = keyByID[id], let index = index(of: key), var folder = try? FolderRecord(raw: catalog[index].data) else { return }
        folder.modifyDate = date
        catalog[index].data = folder.raw
    }

    /// Valences and MDB totals are derived from the catalog on every flush rather than
    /// maintained incrementally, so they can't drift. (The root folder isn't counted in the
    /// volume's folder total.)
    private func recomputeCounts() {
        var childCount: [UInt32: Int] = [:]
        var files = 0, folders = 0
        for record in catalog {
            switch record.type {
            case .file: files += 1; childCount[record.key.parentID, default: 0] += 1
            case .folder: folders += 1; childCount[record.key.parentID, default: 0] += 1
            default: break
            }
        }
        var rootFiles = 0, rootFolders = 0
        for index in catalog.indices {
            if catalog[index].type == .folder, var folder = try? FolderRecord(raw: catalog[index].data) {
                folder.valence = UInt16(clamping: childCount[folder.id, default: 0])
                catalog[index].data = folder.raw
            }
            if catalog[index].key.parentID == HFSCatalogID.rootFolder {
                if catalog[index].type == .file { rootFiles += 1 }
                if catalog[index].type == .folder { rootFolders += 1 }
            }
        }
        mdb.fileCount = UInt32(files)
        mdb.folderCount = UInt32(max(0, folders - 1))
        mdb.rootFileCount = UInt16(clamping: rootFiles)
        mdb.rootFolderCount = UInt16(clamping: rootFolders)
    }

    // MARK: - Internals: allocation and fork data

    /// Space new file data must leave free so the next save can write fresh copies of both
    /// trees (with room for the catalog to grow) instead of overwriting them in place.
    /// What the next save needs to write both trees by copy: each tree's nodes in use, plus
    /// room for the pending changes to grow them, within the MDB's three extents.
    private var saveRoom: AllocationMap.SaveRoom {
        func room(_ header: BTree.Header) -> Int {
            let used = Int(header.totalNodes) - Int(min(header.freeNodes, header.totalNodes))
            let nodes = TreePlacement.minimumNodes(needed: used + max(used / 4, 4), current: Int(header.totalNodes))
            return TreePlacement.blocks(forNodes: nodes, nodeSize: BTree.nodeSize512, blockSize: blockSize)
        }
        return AllocationMap.SaveRoom(trees: [(room(committed.catalogHeader), 3), (room(committed.extentsHeader), 3)])
    }

    private func writeNewFork(_ source: HFSForkSource, keeping room: AllocationMap.SaveRoom) throws -> [ExtentDescriptor] {
        let blocks = Int((source.length + UInt64(blockSize) - 1) / UInt64(blockSize))
        let extents = try allocation.allocateData(blocks, hint: Int(mdb.allocationPointer), keeping: room)
            .map { ExtentDescriptor(startBlock: UInt16($0.start), blockCount: UInt16($0.count)) }
        if let last = extents.last { mdb.allocationPointer = UInt16(clamping: Int(last.startBlock) + Int(last.blockCount)) }
        var offset: UInt64 = 0
        let chunk = max(blockSize, (1 << 20) / blockSize * blockSize)
        for extent in extents {
            var position = blockPosition(extent.startBlock)
            var remaining = UInt64(extent.blockCount) * UInt64(blockSize)
            while remaining > 0 {
                let count = Int(min(UInt64(chunk), remaining))
                let available = Int(min(UInt64(count), source.length - min(offset, source.length)))
                var bytes = available > 0 ? try source.read(offset, available) : []
                guard bytes.count == available else { throw HFSError.corrupt("the source file changed while it was being copied") }
                if bytes.count < count { bytes += [UInt8](repeating: 0, count: count - bytes.count) }
                try device.write(bytes, at: position)
                position += UInt64(count)
                remaining -= UInt64(count)
                offset += UInt64(count)
            }
        }
        return extents
    }

    /// Puts a fork's first three extents in the file record and the rest in overflow records.
    private func store(_ extents: [ExtentDescriptor], fork: HFSFork, length: UInt64, fileID: UInt32, in file: inout FileRecord) {
        let blocks = extents.reduce(0) { $0 + Int($1.blockCount) }
        file.setFork(fork, logicalLength: UInt32(length), physicalLength: UInt32(blocks * blockSize), extents: ExtentRecord(extents: Array(extents.prefix(3))))
        addOverflow(Array(extents.dropFirst(3)), fork: fork, fileID: fileID, startingAt: extents.prefix(3).reduce(0) { $0 + Int($1.blockCount) })
    }

    private func addOverflow(_ extents: [ExtentDescriptor], fork: HFSFork, fileID: UInt32, startingAt firstBlock: Int) {
        var forkBlock = firstBlock
        var rest = extents
        while !rest.isEmpty {
            let group = Array(rest.prefix(3))
            rest.removeFirst(group.count)
            let key = ExtentsKey(fork: fork, fileID: fileID, startBlock: UInt16(clamping: forkBlock))
            let position = extentsRecords.firstIndex { ExtentsKey.compare($0.key, key) > 0 } ?? extentsRecords.count
            extentsRecords.insert((key, ExtentRecord(extents: group)), at: position)
            forkBlock += group.reduce(0) { $0 + Int($1.blockCount) }
        }
    }

    private func blockPosition(_ block: UInt16) -> UInt64 {
        firstBlockOffset + UInt64(block) * UInt64(blockSize)
    }

    private static func extentList(_ record: ExtentRecord) -> [ExtentDescriptor] {
        record.extents.filter { $0.blockCount > 0 }
    }

    /// A fork's complete extent list: the three in its catalog/MDB record, then any
    /// overflow records chained by fork-relative start block.
    private static func forkExtents(fileID: UInt32, fork: HFSFork, first: ExtentRecord, overflow: [(key: ExtentsKey, record: ExtentRecord)]) -> [ExtentDescriptor] {
        var result = extentList(first)
        var nextStart = result.reduce(0) { $0 + Int($1.blockCount) }
        while let next = overflow.first(where: { $0.key.fileID == fileID && $0.key.fork == fork && Int($0.key.startBlock) == nextStart }) {
            let more = extentList(next.record)
            if more.isEmpty { break }
            result += more
            nextStart += more.reduce(0) { $0 + Int($1.blockCount) }
        }
        return result
    }

    private static func readTreeNode(_ node: UInt32, fork: [ExtentDescriptor], forkSize: Int, device: BlockDevice, firstBlockOffset: UInt64, blockSize: Int) throws -> [UInt8] {
        let offset = Int(node) * BTree.nodeSize512
        guard offset + BTree.nodeSize512 <= forkSize else { throw HFSError.corrupt("B-tree node \(node) is outside its file") }
        guard let position = forkPosition(offset, extents: fork, firstBlockOffset: firstBlockOffset, blockSize: blockSize) else {
            throw HFSError.corrupt("B-tree node \(node) is not covered by the file's extents")
        }
        return try device.read(at: position, count: BTree.nodeSize512)
    }

    /// Device position of a fork-relative byte offset (nodes never straddle blocks since
    /// allocation blocks are multiples of 512).
    private static func forkPosition(_ offset: Int, extents: [ExtentDescriptor], firstBlockOffset: UInt64, blockSize: Int) -> UInt64? {
        var base = 0
        for extent in extents {
            let length = Int(extent.blockCount) * blockSize
            if offset < base + length {
                return firstBlockOffset + UInt64(extent.startBlock) * UInt64(blockSize) + UInt64(offset - base)
            }
            base += length
        }
        return nil
    }
}

extension BTree {
    /// Classic HFS B-trees always use 512-byte nodes.
    static let nodeSize512 = 512
}

private final class ByteCollector: @unchecked Sendable {
    private(set) var bytes: [UInt8] = []
    func append(_ chunk: [UInt8]) { bytes += chunk }
}

/// HFS timestamps: seconds since midnight 1 January 1904, *local* time.
enum HFSDate {
    private static let epochOffset: TimeInterval = 2_082_844_800

    static var now: UInt32 { encode(Date()) }

    static func encode(_ date: Date) -> UInt32 {
        let local = date.timeIntervalSince1970 + TimeInterval(TimeZone.current.secondsFromGMT(for: date)) + epochOffset
        return UInt32(clamping: Int64(max(0, local)))
    }

    static func date(_ value: UInt32) -> Date {
        // The offset is the one in force at that local time, not now, so encode(date(x)) == x
        // across daylight-saving changes.
        let local = TimeInterval(value) - epochOffset
        let zone = TimeZone.current
        let guess = local - TimeInterval(zone.secondsFromGMT(for: Date(timeIntervalSince1970: local)))
        return Date(timeIntervalSince1970: local - TimeInterval(zone.secondsFromGMT(for: Date(timeIntervalSince1970: guess))))
    }
}
