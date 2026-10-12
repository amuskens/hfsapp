import Foundation

/// One catalog item as the rest of the app sees it.
struct HFSItem: Sendable, Hashable, Identifiable {
    let id: UInt32
    let parentID: UInt32
    let name: HFSName
    let isFolder: Bool
    let dataLength: UInt32
    let resourceLength: UInt32
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
}

/// A classic HFS volume opened read/write (or read-only) directly from an image file — no
/// kernel filesystem, no external tools, so it works inside the App Sandbox.
///
/// The whole catalog and extents-overflow tree are held in memory as sorted record arrays.
/// Mutations edit those arrays and the allocation bitmap; `flush()` writes freshly built
/// B-trees, the bitmap and the master directory block back to the image. File data is
/// written to newly allocated blocks *before* any catalog change refers to them, so an
/// interrupted import never leaves a catalog entry pointing at unwritten data.
actor HFSVolume {
    nonisolated let isReadOnly: Bool
    private let device: BlockDevice
    private var mdb: MasterDirectoryBlock
    private var bitmap: [UInt8]
    private var catalog: [CatalogRecord]
    private var extentsRecords: [(key: ExtentsKey, record: ExtentRecord)]
    private var catalogHeader: BTree.Header
    private var extentsHeader: BTree.Header
    private var keyByID: [UInt32: CatalogKey] = [:]
    private var dirty = false
    private var markedInUse = false

    private let blockSize: Int
    private let blockCount: Int
    private let firstBlockOffset: UInt64

    init(device: BlockDevice, readOnly: Bool) throws {
        self.device = device
        self.isReadOnly = readOnly || !device.isWritable
        guard device.length >= 1536 else { throw HFSError.notHFS }
        let mdb = try MasterDirectoryBlock(sector: try device.read(at: 1024, count: 512))
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
        self.mdb = mdb
        self.blockSize = blockSize
        self.blockCount = Int(mdb.allocationBlockCount)
        self.firstBlockOffset = firstBlockOffset

        let bitmapBytes = (blockCount + 7) / 8
        bitmap = try device.read(at: UInt64(mdb.bitmapStartSector) * 512, count: bitmapBytes)

        // The extents file can't overflow, so its extents are entirely in the MDB.
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

        // The catalog may continue in the extents-overflow file.
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
        for record in catalog {
            switch record.type {
            case .folder: if let folder = try? FolderRecord(raw: record.data) { keyByID[folder.id] = record.key }
            case .file: if let file = try? FileRecord(raw: record.data) { keyByID[file.id] = record.key }
            default: break
            }
        }
        guard keyByID[HFSCatalogID.rootFolder] != nil else { throw HFSError.corrupt("root folder is missing") }
    }

    // MARK: - Reading

    var volumeName: HFSName { mdb.volumeName }
    /// Space available for new files (see `allocatableBlockCount`).
    var freeBytes: UInt64 { UInt64(allocatableFreeBlockCount) * UInt64(blockSize) }
    var totalBytes: UInt64 { UInt64(blockCount) * UInt64(blockSize) }

    func item(_ id: UInt32) throws -> HFSItem {
        guard let key = keyByID[id], let index = index(of: key) else { throw HFSError.notFound("Item \(id)") }
        return try makeItem(catalog[index])
    }

    func contents(ofFolder folderID: UInt32) throws -> [HFSItem] {
        let folder = try item(folderID)
        guard folder.isFolder else { throw HFSError.notFound("Folder \(folder.name)") }
        return try childRecordIndices(of: folderID).map { try makeItem(catalog[$0]) }
    }

    /// Folder names from the volume root down to `id` (excluding the root itself).
    func path(of id: UInt32) throws -> [HFSItem] {
        var result: [HFSItem] = []
        var current = id
        var guardCount = 0
        while current != HFSCatalogID.rootFolder {
            let item = try item(current)
            result.insert(item, at: 0)
            current = item.parentID
            guardCount += 1
            if guardCount > 10_000 { throw HFSError.corrupt("folder hierarchy has a cycle") }
        }
        return result
    }

    func child(named name: HFSName, inFolder folderID: UInt32) -> HFSItem? {
        guard let index = index(of: CatalogKey(parentID: folderID, name: name.bytes)) else { return nil }
        return try? makeItem(catalog[index])
    }

    /// Streams a fork to `sink` in chunks of at most `chunkSize` bytes. `sink` may throw (for
    /// example `CancellationError`) to stop early.
    func readFork(_ id: UInt32, fork: HFSFork, chunkSize: Int = 1 << 20, sink: ([UInt8]) throws -> Void) throws {
        let file = try fileRecord(id)
        let length = UInt64(file.logicalLength(fork))
        let extents = Self.forkExtents(fileID: id, fork: fork, first: file.extents(fork), overflow: extentsRecords)
        guard UInt64(extents.reduce(0) { $0 + Int($1.blockCount) }) * UInt64(blockSize) >= length else {
            throw HFSError.corrupt("\(try item(id).name) is shorter on disk than its catalog entry says")
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
        var result: [UInt8] = []
        try readFork(id, fork: fork) { result += $0 }
        return result
    }

    /// The raw 16-byte FInfo and FXInfo of a file (for MacBinary and Finder metadata export).
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
    func createFolder(named name: HFSName, in parentID: UInt32) throws -> UInt32 {
        try checkWritable()
        try checkCanAdd(name, to: parentID)
        let id = try allocateCatalogID()
        let now = HFSDate.now
        insert(CatalogRecord(key: CatalogKey(parentID: parentID, name: name.bytes), data: FolderRecord(id: id, date: now).raw))
        insert(CatalogRecord(key: CatalogKey(parentID: id, name: []), data: ThreadRecord.make(type: .folderThread, parentID: parentID, name: name.bytes)))
        keyByID[id] = CatalogKey(parentID: parentID, name: name.bytes)
        touchFolder(parentID, date: now)
        dirty = true
        return id
    }

    /// Writes both forks to freshly allocated blocks, then adds the catalog entry. On any
    /// failure (including cancellation thrown by a fork reader) the blocks are released and
    /// the catalog is untouched.
    @discardableResult
    func createFile(
        named name: HFSName,
        in parentID: UInt32,
        type: [UInt8],
        creator: [UInt8],
        finderInfo: [UInt8]? = nil,
        extendedFinderInfo: [UInt8]? = nil,
        dataFork: HFSForkSource,
        resourceFork: HFSForkSource
    ) throws -> UInt32 {
        try checkWritable()
        try checkCanAdd(name, to: parentID)
        guard dataFork.length <= UInt64(UInt32.max), resourceFork.length <= UInt64(UInt32.max) else { throw HFSError.volumeFull }
        let bitmapBefore = bitmap
        do {
            let dataExtents = try writeNewFork(dataFork)
            let resourceExtents = try writeNewFork(resourceFork)
            let id = try allocateCatalogID()
            let now = HFSDate.now
            var file = FileRecord(id: id, date: now, type: type, creator: creator)
            if let finderInfo { file.finderInfo = finderInfo }
            if let extendedFinderInfo { file.extendedFinderInfo = extendedFinderInfo }
            try store(dataExtents, fork: .data, length: dataFork.length, fileID: id, in: &file)
            try store(resourceExtents, fork: .resource, length: resourceFork.length, fileID: id, in: &file)
            let key = CatalogKey(parentID: parentID, name: name.bytes)
            insert(CatalogRecord(key: key, data: file.raw))
            keyByID[id] = key
            touchFolder(parentID, date: now)
            dirty = true
            return id
        } catch {
            bitmap = bitmapBefore
            throw error
        }
    }

    /// Deletes a file, or a folder that is already empty.
    func delete(_ id: UInt32) throws {
        try checkWritable()
        guard id != HFSCatalogID.rootFolder, let key = keyByID[id], let index = index(of: key) else { throw HFSError.notFound("Item \(id)") }
        let record = catalog[index]
        switch record.type {
        case .file:
            let file = try FileRecord(raw: record.data)
            for fork in [HFSFork.data, .resource] {
                for extent in Self.forkExtents(fileID: id, fork: fork, first: file.extents(fork), overflow: extentsRecords) {
                    setBlocks(extent, allocated: false)
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
    func move(_ id: UInt32, to newParentID: UInt32, newName: HFSName? = nil) throws {
        try checkWritable()
        guard id != HFSCatalogID.rootFolder, let oldKey = keyByID[id], let oldIndex = index(of: oldKey) else { throw HFSError.notFound("Item \(id)") }
        let name = newName ?? HFSName(bytes: oldKey.name)
        guard try item(newParentID).isFolder else { throw HFSError.invalidMove("The destination is not a folder.") }
        let record = catalog[oldIndex]
        if record.type == .folder {
            var ancestor = newParentID
            while ancestor != HFSCatalogID.rootParent {
                if ancestor == id { throw HFSError.invalidMove("A folder can't be moved into itself.") }
                ancestor = try item(ancestor).parentID
            }
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
    func copyFile(_ id: UInt32, to parentID: UInt32, name: HFSName) throws -> UInt32 {
        let source = try fileRecord(id)
        let data = try readForkBytes(id, fork: .data)
        let resource = try readForkBytes(id, fork: .resource)
        return try createFile(
            named: name, in: parentID,
            type: source.fileType, creator: source.creator,
            finderInfo: source.finderInfo, extendedFinderInfo: source.extendedFinderInfo,
            dataFork: HFSForkSource(bytes: data), resourceFork: HFSForkSource(bytes: resource)
        )
    }

    /// Writes all pending changes to the image.
    func flush() throws {
        guard dirty else { return }
        try checkWritable()
        try markVolumeInUse()
        recomputeCounts()

        try writeTree(
            records: extentsRecords.map { BTree.BuildRecord(leafBytes: $0.key.encoded + $0.record.encoded, indexKey: $0.key.encoded) },
            header: &extentsHeader,
            isCatalog: false
        )
        try writeTree(
            records: catalog.map { BTree.BuildRecord(leafBytes: $0.key.leafEncoded + $0.data, indexKey: $0.key.indexEncoded) },
            header: &catalogHeader,
            isCatalog: true
        )
        try device.write(bitmap, at: UInt64(mdb.bitmapStartSector) * 512)

        mdb.freeBlockCount = UInt16(freeBlockCount)
        mdb.modifyDate = HFSDate.now
        mdb.writeCount &+= 1
        mdb.attributes |= MasterDirectoryBlock.unmountedCleanlyBit
        try writeMDB()
        try device.synchronize()
        markedInUse = false
        dirty = false
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
        guard let key = keyByID[id], let index = index(of: key), catalog[index].type == .file else { throw HFSError.notFound("File \(id)") }
        return try FileRecord(raw: catalog[index].data)
    }

    private func makeItem(_ record: CatalogRecord) throws -> HFSItem {
        switch record.type {
        case .folder:
            let folder = try FolderRecord(raw: record.data)
            return HFSItem(
                id: folder.id, parentID: record.key.parentID, name: HFSName(bytes: record.key.name), isFolder: true,
                dataLength: 0, resourceLength: 0, fileType: [], creator: [], finderFlags: folder.finderFlags, isLocked: false,
                createDate: HFSDate.date(folder.createDate), modifyDate: HFSDate.date(folder.modifyDate),
                valence: childRecordIndices(of: folder.id).count
            )
        case .file:
            let file = try FileRecord(raw: record.data)
            return HFSItem(
                id: file.id, parentID: record.key.parentID, name: HFSName(bytes: record.key.name), isFolder: false,
                dataLength: file.logicalLength(.data), resourceLength: file.logicalLength(.resource),
                fileType: file.fileType, creator: file.creator, finderFlags: file.finderFlags, isLocked: file.isLocked,
                createDate: HFSDate.date(file.createDate), modifyDate: HFSDate.date(file.modifyDate), valence: 0
            )
        default:
            throw HFSError.corrupt("unexpected catalog record type")
        }
    }

    private func checkWritable() throws {
        if isReadOnly { throw HFSError.readOnly }
    }

    private func checkCanAdd(_ name: HFSName, to parentID: UInt32) throws {
        // Apple's fsck_hfs treats "." and ".." as illegal names (it renames them).
        if name.bytes == [0x2E] || name.bytes == [0x2E, 0x2E] { throw HFSError.invalidName(name.string) }
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

    // MARK: - Internals: allocation

    /// Free blocks as the MDB counts them (all of them).
    private var freeBlockCount: Int {
        var used = 0
        for block in 0..<blockCount where isAllocated(block) { used += 1 }
        return blockCount - used
    }

    /// Apple's HFS code never allocates a volume's final allocation block, and fsck_hfs flags
    /// any extent that reaches it ("Invalid extent entry … blockCount > maxBlocks −
    /// startBlock") — even though the MDB still counts it as free (`hformat` does too).
    /// So the allocator stops one block short.
    private var allocatableBlockCount: Int { blockCount - 1 }

    private var allocatableFreeBlockCount: Int {
        var used = 0
        for block in 0..<allocatableBlockCount where isAllocated(block) { used += 1 }
        return allocatableBlockCount - used
    }

    private func isAllocated(_ block: Int) -> Bool {
        bitmap[block / 8] & (0x80 >> UInt8(block % 8)) != 0
    }

    private func setBlocks(_ extent: ExtentDescriptor, allocated: Bool) {
        for block in Int(extent.startBlock)..<(Int(extent.startBlock) + Int(extent.blockCount)) where block < blockCount {
            if allocated { bitmap[block / 8] |= 0x80 >> UInt8(block % 8) } else { bitmap[block / 8] &= ~(0x80 >> UInt8(block % 8)) }
        }
    }

    /// Allocates `count` blocks, contiguously if any free run is long enough, otherwise from
    /// the largest free runs first (fewest extents).
    private func allocate(_ count: Int) throws -> [ExtentDescriptor] {
        guard count > 0 else { return [] }
        guard count <= allocatableFreeBlockCount else { throw HFSError.volumeFull }
        var runs: [ExtentDescriptor] = []
        var block = 0
        while block < allocatableBlockCount {
            if isAllocated(block) { block += 1; continue }
            let start = block
            while block < allocatableBlockCount, !isAllocated(block), block - start < Int(UInt16.max) { block += 1 }
            runs.append(ExtentDescriptor(startBlock: UInt16(start), blockCount: UInt16(block - start)))
        }
        let hint = Int(mdb.allocationPointer)
        if let run = runs.first(where: { Int($0.startBlock) >= hint && Int($0.blockCount) >= count })
            ?? runs.first(where: { Int($0.blockCount) >= count }) {
            let extent = ExtentDescriptor(startBlock: run.startBlock, blockCount: UInt16(count))
            setBlocks(extent, allocated: true)
            mdb.allocationPointer = UInt16(clamping: Int(run.startBlock) + count)
            return [extent]
        }
        var result: [ExtentDescriptor] = []
        var needed = count
        for run in runs.sorted(by: { $0.blockCount > $1.blockCount }) where needed > 0 {
            let take = min(Int(run.blockCount), needed)
            let extent = ExtentDescriptor(startBlock: run.startBlock, blockCount: UInt16(take))
            setBlocks(extent, allocated: true)
            result.append(extent)
            needed -= take
        }
        return result.sorted { $0.startBlock < $1.startBlock }
    }

    private func writeNewFork(_ source: HFSForkSource) throws -> [ExtentDescriptor] {
        let blocks = Int((source.length + UInt64(blockSize) - 1) / UInt64(blockSize))
        let extents = try allocate(blocks)
        var offset: UInt64 = 0
        let chunk = max(blockSize, (1 << 20) / blockSize * blockSize)
        for extent in extents {
            var position = blockPosition(extent.startBlock)
            var remaining = UInt64(extent.blockCount) * UInt64(blockSize)
            while remaining > 0 {
                let count = Int(min(UInt64(chunk), remaining))
                let available = Int(min(UInt64(count), source.length - min(offset, source.length)))
                var bytes = available > 0 ? try source.read(offset, available) : []
                guard bytes.count == available else { throw HFSError.corrupt("source file changed while it was being copied") }
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
    private func store(_ extents: [ExtentDescriptor], fork: HFSFork, length: UInt64, fileID: UInt32, in file: inout FileRecord) throws {
        let blocks = extents.reduce(0) { $0 + Int($1.blockCount) }
        file.setFork(fork, logicalLength: UInt32(length), physicalLength: UInt32(blocks * blockSize), extents: ExtentRecord(extents: Array(extents.prefix(3))))
        var forkBlock = extents.prefix(3).reduce(0) { $0 + Int($1.blockCount) }
        var rest = Array(extents.dropFirst(3))
        while !rest.isEmpty {
            let group = Array(rest.prefix(3))
            rest.removeFirst(group.count)
            let key = ExtentsKey(fork: fork, fileID: fileID, startBlock: UInt16(forkBlock))
            let position = extentsRecords.firstIndex { ExtentsKey.compare($0.key, key) > 0 } ?? extentsRecords.count
            extentsRecords.insert((key, ExtentRecord(extents: group)), at: position)
            forkBlock += group.reduce(0) { $0 + Int($1.blockCount) }
        }
    }

    private func blockPosition(_ block: UInt16) -> UInt64 {
        firstBlockOffset + UInt64(block) * UInt64(blockSize)
    }

    // MARK: - Internals: trees and MDB

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
        let offset = Int(node) * BTree.nodeSize
        guard offset + BTree.nodeSize <= forkSize else { throw HFSError.corrupt("B-tree node \(node) is outside its file") }
        guard let position = forkPosition(offset, extents: fork, firstBlockOffset: firstBlockOffset, blockSize: blockSize) else {
            throw HFSError.corrupt("B-tree node \(node) is not covered by the file's extents")
        }
        return try device.read(at: position, count: BTree.nodeSize)
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

    private func writeTree(records: [BTree.BuildRecord], header: inout BTree.Header, isCatalog: Bool) throws {
        while true {
            let first = isCatalog ? mdb.catalogFileExtents : mdb.extentsFileExtents
            let fork = isCatalog
                ? Self.forkExtents(fileID: HFSCatalogID.catalogFile, fork: .data, first: first, overflow: extentsRecords)
                : Self.extentList(first)
            let size = Int(isCatalog ? mdb.catalogFileSize : mdb.extentsFileSize)
            do {
                let nodes = try BTree.build(records: records, nodeCount: size / BTree.nodeSize, template: header)
                for (number, node) in nodes.enumerated() {
                    guard let position = Self.forkPosition(number * BTree.nodeSize, extents: fork, firstBlockOffset: firstBlockOffset, blockSize: blockSize) else {
                        throw HFSError.corrupt("B-tree file is shorter than its size")
                    }
                    try device.write(node, at: position)
                }
                header = try BTree.Header(raw: try BTree.records(of: nodes[0])[0])
                return
            } catch HFSError.catalogFull {
                try growTreeFile(isCatalog: isCatalog)
            }
        }
    }

    /// Extends the catalog or extents file by one clump, in place if the blocks right after
    /// its last extent are free, otherwise as a new extent (at most three, all in the MDB).
    private func growTreeFile(isCatalog: Bool) throws {
        var record = isCatalog ? mdb.catalogFileExtents : mdb.extentsFileExtents
        let clump = Int(isCatalog ? mdb.catalogClumpSize : mdb.extentsClumpSize)
        let blocks = max(1, (max(clump, 4 * blockSize) + blockSize - 1) / blockSize)
        var used = record.extents.filter { $0.blockCount > 0 }
        if let last = used.last {
            let next = Int(last.startBlock) + Int(last.blockCount)
            if next + blocks <= allocatableBlockCount, (next..<(next + blocks)).allSatisfy({ !isAllocated($0) }), Int(last.blockCount) + blocks <= Int(UInt16.max) {
                setBlocks(ExtentDescriptor(startBlock: UInt16(next), blockCount: UInt16(blocks)), allocated: true)
                used[used.count - 1].blockCount += UInt16(blocks)
                record = ExtentRecord(extents: used)
                try commitTreeExtents(record, isCatalog: isCatalog)
                return
            }
        }
        guard used.count < 3 else { throw HFSError.catalogFull }
        let added = try allocate(blocks)
        guard added.count == 1 else {
            for extent in added { setBlocks(extent, allocated: false) }
            throw HFSError.catalogFull
        }
        record = ExtentRecord(extents: used + added)
        try commitTreeExtents(record, isCatalog: isCatalog)
    }

    private func commitTreeExtents(_ record: ExtentRecord, isCatalog: Bool) throws {
        let size = UInt32(record.blockCount * blockSize)
        if isCatalog {
            mdb.catalogFileExtents = record
            mdb.catalogFileSize = size
        } else {
            mdb.extentsFileExtents = record
            mdb.extentsFileSize = size
        }
    }

    /// Clears the "unmounted cleanly" bit on disk before the first write of a batch, so a
    /// crash midway leaves Mac OS (and fsck) a signal to check the volume.
    private func markVolumeInUse() throws {
        guard !markedInUse else { return }
        mdb.attributes &= ~MasterDirectoryBlock.unmountedCleanlyBit
        try device.write(mdb.raw, at: 1024)
        try device.synchronize()
        markedInUse = true
    }

    private func writeMDB() throws {
        try device.write(mdb.raw, at: 1024)
        // Keep the alternate MDB (second-to-last sector) in step — but only where one exists.
        let alternate = device.length / 512 * 512 - 1024
        if alternate > 1024, let sector = try? device.read(at: alternate, count: 512), (try? sector.u16(0)) == MasterDirectoryBlock.signature {
            try device.write(mdb.raw, at: alternate)
        }
    }
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
        let utc = TimeInterval(value) - epochOffset
        return Date(timeIntervalSince1970: utc - TimeInterval(TimeZone.current.secondsFromGMT()))
    }
}
