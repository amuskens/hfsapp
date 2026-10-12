import Foundation

/// An HFS Plus (Mac OS Extended) volume, read and written in-process — the format of Mac OS
/// 8.1–9 hard disks and most later BlueSCSI images. Same design and commit protocol as
/// `HFSVolume`: catalog and extents records held sorted in memory, file data written to blocks
/// that are free on disk, new B-trees written to free space, and one volume-header write as
/// the commit.
///
/// Deliberately conservative where a mistake would damage a Mac OS X-era volume:
/// - journaled volumes open read-only (their journal would have to be replayed and kept);
/// - hard links, and items carrying extended attributes, can't be deleted (that would orphan
///   their indirect nodes or attribute records).
actor HFSPlusVolume: DiskVolume {
    nonisolated let isReadOnly: Bool
    nonisolated let readOnlyCause: ReadOnlyCause?
    nonisolated let formatName: String

    private let device: BlockDevice
    private let blockSize: Int
    private let totalBlocks: Int
    private let catalogNodeSize: Int
    private let extentsNodeSize: Int
    private let caseSensitive: Bool
    private let variableIndexKeys: Bool
    private let hasAttributesTree: Bool

    private var header: HFSPlusVolumeHeader
    private var allocation: AllocationMap
    private var catalog: [HFSPlusCatalogRecord]
    private var extentsRecords: [(key: HFSPlusExtentsKey, extents: [HFSPlusExtent])]
    private var catalogHeader: BTree.Header
    private var extentsHeader: BTree.Header
    private var keyByID: [UInt32: HFSPlusCatalogKey] = [:]

    private struct Committed {
        var header: HFSPlusVolumeHeader
        var bitmap: [UInt8]
        var catalog: [HFSPlusCatalogRecord]
        var extentsRecords: [(key: HFSPlusExtentsKey, extents: [HFSPlusExtent])]
        var catalogHeader: BTree.Header
        var extentsHeader: BTree.Header
        var keyByID: [UInt32: HFSPlusCatalogKey]
    }
    private var committed: Committed!
    private var lastKnownHeaderSector: [UInt8]
    private var dirty = false
    private var markedInUse = false
    private var isClosed = false

    static let allocationFileID: UInt32 = 6

    init(device: BlockDevice, forcedReadOnly: ReadOnlyCause? = nil, allowUncleanVolume: Bool = false) throws {
        self.device = device
        guard device.length >= 2048 else { throw HFSError.notHFS }
        let sector = try device.read(at: 1024, count: 512)
        let header = try HFSPlusVolumeHeader(sector: sector)
        let blockSize = Int(header.blockSize)
        guard blockSize >= 512, blockSize <= 1 << 20, blockSize.nonzeroBitCount == 1, header.totalBlocks > 0,
              UInt64(header.totalBlocks) * UInt64(blockSize) <= device.length else {
            throw HFSError.corrupt("bad volume header")
        }
        self.formatName = header.isHFSX ? "Mac OS Extended (Case-sensitive)" : "Mac OS Extended"

        var cause: ReadOnlyCause?
        if let forcedReadOnly {
            cause = forcedReadOnly
        } else if !device.isWritable {
            cause = .requested
        } else if header.attributes & HFSPlusVolumeHeader.journaledBit != 0 {
            cause = .journaled
        } else if header.attributes & (HFSPlusVolumeHeader.softwareLockBit | HFSPlusVolumeHeader.hardwareLockBit) != 0 {
            cause = .locked
        } else if (header.attributes & HFSPlusVolumeHeader.unmountedCleanlyBit == 0
                   || header.attributes & HFSPlusVolumeHeader.inconsistentBit != 0) && !allowUncleanVolume {
            cause = .notCleanlyUnmounted
        }
        self.readOnlyCause = cause
        self.isReadOnly = cause != nil
        self.header = header
        self.lastKnownHeaderSector = sector
        self.blockSize = blockSize
        self.totalBlocks = Int(header.totalBlocks)

        // Extents overflow file: its own extents are all in the volume header.
        let extentsFork = header.fork(HFSPlusVolumeHeader.extentsFileOffset)
        let extentsReader = Self.forkReader(extentsFork.extents, logicalSize: extentsFork.logicalSize, device: device, blockSize: blockSize)
        let extentsNodeSize = try Self.nodeSize(reading: extentsReader)
        let (extentsHeader, extentsRaw) = try BTree.readLeafRecords(nodeSize: extentsNodeSize) { try extentsReader(UInt64($0) * UInt64(extentsNodeSize), extentsNodeSize) }
        var extentsRecords: [(key: HFSPlusExtentsKey, extents: [HFSPlusExtent])] = []
        for raw in extentsRaw {
            let (key, dataOffset) = try HFSPlusExtentsKey.parse(raw, at: 0)
            extentsRecords.append((key, try HFSPlusForkData.parseExtents(raw, at: dataOffset)))
        }
        self.extentsHeader = extentsHeader
        self.extentsNodeSize = extentsNodeSize
        self.extentsRecords = extentsRecords

        // Allocation bitmap (a file, which can have overflow extents).
        let allocationFork = header.fork(HFSPlusVolumeHeader.allocationFileOffset)
        let allocationExtents = Self.fullExtents(fileID: Self.allocationFileID, fork: .data, data: allocationFork, overflow: extentsRecords)
        let bitmapBytes = (Int(header.totalBlocks) + 7) / 8
        guard allocationFork.logicalSize >= UInt64(bitmapBytes) else { throw HFSError.corrupt("allocation file is too small") }
        let bitmap = try Self.forkReader(allocationExtents, logicalSize: allocationFork.logicalSize, device: device, blockSize: blockSize)(0, bitmapBytes)
        self.allocation = AllocationMap(bitmap: bitmap, blockCount: Int(header.totalBlocks), allocatableCount: Int(header.totalBlocks), maxRunLength: Int(Int32.max))

        // Catalog.
        let catalogFork = header.fork(HFSPlusVolumeHeader.catalogFileOffset)
        let catalogExtents = Self.fullExtents(fileID: HFSCatalogID.catalogFile, fork: .data, data: catalogFork, overflow: extentsRecords)
        let catalogReader = Self.forkReader(catalogExtents, logicalSize: catalogFork.logicalSize, device: device, blockSize: blockSize)
        let catalogNodeSize = try Self.nodeSize(reading: catalogReader)
        let (catalogHeader, catalogRaw) = try BTree.readLeafRecords(nodeSize: catalogNodeSize) { try catalogReader(UInt64($0) * UInt64(catalogNodeSize), catalogNodeSize) }
        self.catalogHeader = catalogHeader
        self.catalogNodeSize = catalogNodeSize
        // keyCompareType 0xBC = binary (case-sensitive HFSX); otherwise Apple case folding.
        let caseSensitive = header.isHFSX && (try? catalogHeader.raw.u8(37)) == 0xBC
        self.caseSensitive = caseSensitive
        self.variableIndexKeys = ((try? catalogHeader.raw.u32(39)) ?? 0) & 0x4 != 0
        self.hasAttributesTree = header.fork(HFSPlusVolumeHeader.attributesFileOffset).logicalSize > 0

        var catalog: [HFSPlusCatalogRecord] = []
        catalog.reserveCapacity(catalogRaw.count)
        for raw in catalogRaw {
            let (key, dataOffset) = try HFSPlusCatalogKey.parse(raw, at: 0)
            guard dataOffset < raw.count else { throw HFSError.corrupt("catalog record has no data") }
            catalog.append(HFSPlusCatalogRecord(key: key, data: Array(raw[dataOffset...])))
        }
        let compare = Self.comparator(caseSensitive: caseSensitive)
        for i in catalog.indices.dropFirst() where compare(catalog[i - 1].key, catalog[i].key) >= 0 {
            throw HFSError.corrupt("catalog records are out of order")
        }
        self.catalog = catalog

        var keyByID: [UInt32: HFSPlusCatalogKey] = [:]
        for record in catalog {
            let id: UInt32
            switch record.type {
            case .folder:
                guard let folder = try? HFSPlusFolderRecord(raw: record.data) else { continue }
                id = folder.id
                guard id != record.key.parentID else { throw HFSError.corrupt("a folder is its own parent") }
            case .file:
                guard let file = try? HFSPlusFileRecord(raw: record.data) else { continue }
                id = file.id
            default:
                continue
            }
            guard keyByID.updateValue(record.key, forKey: id) == nil else { throw HFSError.corrupt("two catalog entries share ID \(id)") }
        }
        guard let rootKey = keyByID[HFSCatalogID.rootFolder], rootKey.parentID == HFSCatalogID.rootParent else {
            throw HFSError.corrupt("root folder is missing")
        }
        self.keyByID = keyByID
        self.committed = Committed(header: header, bitmap: bitmap, catalog: catalog, extentsRecords: extentsRecords,
                                   catalogHeader: catalogHeader, extentsHeader: extentsHeader, keyByID: keyByID)
    }

    // MARK: - Reading

    var volumeName: String {
        guard let key = keyByID[HFSCatalogID.rootFolder] else { return "" }
        return HFSPlusName.decode(key.name)
    }

    var freeBytes: UInt64 { UInt64(allocation.availableCount) * UInt64(blockSize) }

    nonisolated func validName(from hostName: String) -> String {
        var name = hostName.replacingOccurrences(of: ":", with: "-")
        if name.isEmpty || name == "." || name == ".." { name = "Untitled" }
        while (try? HFSPlusName.encode(name)) == nil, !name.isEmpty {
            name.removeLast()
        }
        return name.isEmpty ? "Untitled" : name
    }

    func item(_ id: UInt32) throws -> VolumeItem {
        try checkOpen()
        guard let key = keyByID[id], let index = index(of: key) else { throw HFSError.notFound("Item \(id)") }
        return try makeItem(catalog[index])
    }

    func contents(ofFolder folderID: UInt32) throws -> [VolumeItem] {
        guard try item(folderID).isFolder else { throw HFSError.notFound("Folder \(folderID)") }
        return try childRecordIndices(of: folderID).compactMap { index in
            let item = try makeItem(catalog[index])
            return folderID == HFSCatalogID.rootFolder && Self.isMetadataItem(item.name) ? nil : item
        }
    }

    /// Mac OS X's hidden bookkeeping at the volume root (hard-link stores, journal files).
    private static func isMetadataItem(_ name: String) -> Bool {
        name.hasPrefix("\u{0}\u{0}\u{0}\u{0}HFS+ Private Data") || name == ".HFS+ Private Directory Data\r"
            || name == ".journal" || name == ".journal_info_block"
    }

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
        guard !isClosed, let units = try? HFSPlusName.encode(name), let index = index(of: HFSPlusCatalogKey(parentID: folderID, name: units)) else { return nil }
        return try? makeItem(catalog[index])
    }

    func readFork(_ id: UInt32, fork: HFSFork, chunkSize: Int, sink: @Sendable ([UInt8]) throws -> Void) throws {
        let file = try fileRecord(id)
        let data = file.fork(fork)
        let extents = Self.fullExtents(fileID: id, fork: fork, data: data, overflow: extentsRecords)
        guard UInt64(extents.reduce(0) { $0 + Int($1.blockCount) }) * UInt64(blockSize) >= data.logicalSize else {
            throw HFSError.corrupt("a file is shorter on disk than its catalog entry says")
        }
        var remaining = data.logicalSize
        for extent in extents where remaining > 0 {
            var position = UInt64(extent.startBlock) * UInt64(blockSize)
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
        let collected = ForkCollector()
        try readFork(id, fork: fork, chunkSize: 1 << 20) { collected.append($0) }
        return collected.bytes
    }

    func finderInfo(_ id: UInt32) throws -> (finderInfo: [UInt8], extended: [UInt8]) {
        let file = try fileRecord(id)
        return (file.finderInfo, file.extendedFinderInfo)
    }

    // MARK: - Writing

    @discardableResult
    func createFolder(named name: String, in parentID: UInt32) throws -> UInt32 {
        try checkWritable()
        let units = try HFSPlusName.encode(name)
        try checkCanAdd(units, to: parentID)
        let id = try allocateCatalogID()
        let now = HFSPlusDate.now
        let encoding = HFSPlusName.textEncoding(for: name)
        let key = HFSPlusCatalogKey(parentID: parentID, name: units)
        insert(HFSPlusCatalogRecord(key: key, data: HFSPlusFolderRecord(id: id, date: now, textEncoding: encoding).raw))
        insert(HFSPlusCatalogRecord(key: HFSPlusCatalogKey(parentID: id, name: []), data: HFSPlusThreadRecord.make(type: .folderThread, parentID: parentID, name: units)))
        keyByID[id] = key
        header.encodingsBitmap |= HFSPlusName.encodingsBitmapBit(for: encoding)
        touchFolder(parentID, date: now)
        dirty = true
        return id
    }

    @discardableResult
    func createFile(named name: String, in parentID: UInt32, metadata: NewFileMetadata, dataFork: HFSForkSource, resourceFork: HFSForkSource) throws -> UInt32 {
        try checkWritable()
        let units = try HFSPlusName.encode(name)
        try checkCanAdd(units, to: parentID)
        let allocationBefore = allocation
        let extentsBefore = extentsRecords
        let headerBefore = header
        do {
            let dataExtents = try writeNewFork(dataFork)
            let resourceExtents = try writeNewFork(resourceFork)
            let id = try allocateCatalogID()
            let now = HFSPlusDate.now
            let encoding = HFSPlusName.textEncoding(for: name)
            var file = HFSPlusFileRecord(id: id, date: now, textEncoding: encoding)
            file.finderInfo = metadata.resolvedFinderInfo()
            if let extended = metadata.extendedFinderInfo { file.extendedFinderInfo = extended }
            if let created = metadata.createDate { file.createDate = HFSPlusDate.encode(created) }
            if let modified = metadata.modifyDate { file.modifyDate = HFSPlusDate.encode(modified) }
            store(dataExtents, fork: .data, length: dataFork.length, fileID: id, in: &file)
            store(resourceExtents, fork: .resource, length: resourceFork.length, fileID: id, in: &file)
            let key = HFSPlusCatalogKey(parentID: parentID, name: units)
            insert(HFSPlusCatalogRecord(key: key, data: file.raw))
            insert(HFSPlusCatalogRecord(key: HFSPlusCatalogKey(parentID: id, name: []), data: HFSPlusThreadRecord.make(type: .fileThread, parentID: parentID, name: units)))
            keyByID[id] = key
            header.encodingsBitmap |= HFSPlusName.encodingsBitmapBit(for: encoding)
            touchFolder(parentID, date: now)
            dirty = true
            return id
        } catch {
            allocation = allocationBefore
            extentsRecords = extentsBefore
            header = headerBefore
            throw error
        }
    }

    func delete(_ id: UInt32) throws {
        try checkWritable()
        guard id != HFSCatalogID.rootFolder, let key = keyByID[id], let index = index(of: key) else { throw HFSError.notFound("Item \(id)") }
        let record = catalog[index]
        switch record.type {
        case .file:
            let file = try HFSPlusFileRecord(raw: record.data)
            if file.fileType == Array("hlnk".utf8) && file.creator == Array("hfs+".utf8) {
                throw HFSError.unsupported("Deleting hard links")
            }
            if file.flags & HFSPlusFileRecord.hasAttributesFlag != 0 && hasAttributesTree {
                throw HFSError.unsupported("Deleting files with extended attributes")
            }
            for fork in [HFSFork.data, .resource] {
                for extent in Self.fullExtents(fileID: id, fork: fork, data: file.fork(fork), overflow: extentsRecords) {
                    allocation.set(start: Int(extent.startBlock), count: Int(extent.blockCount), used: false)
                }
            }
            extentsRecords.removeAll { $0.key.fileID == id }
        case .folder:
            guard childRecordIndices(of: id).isEmpty else { throw HFSError.directoryNotEmpty(HFSPlusName.decode(key.name)) }
            if (try HFSPlusFolderRecord(raw: record.data)).flags & 0x0004 != 0 && hasAttributesTree {
                throw HFSError.unsupported("Deleting folders with extended attributes")
            }
        default:
            throw HFSError.corrupt("unexpected catalog record type")
        }
        catalog.remove(at: index)
        if let thread = self.index(of: HFSPlusCatalogKey(parentID: id, name: [])) {
            catalog.remove(at: thread)
        }
        keyByID[id] = nil
        touchFolder(key.parentID, date: HFSPlusDate.now)
        dirty = true
    }

    func move(_ id: UInt32, to newParentID: UInt32, newName: String?) throws {
        try checkWritable()
        guard id != HFSCatalogID.rootFolder, let oldKey = keyByID[id], let oldIndex = index(of: oldKey) else { throw HFSError.notFound("Item \(id)") }
        let units = try newName.map(HFSPlusName.encode) ?? oldKey.name
        guard try item(newParentID).isFolder else { throw HFSError.invalidMove("The destination is not a folder.") }
        let record = catalog[oldIndex]
        if record.type == .folder, try newParentID == id || path(of: newParentID).contains(where: { $0.id == id }) {
            throw HFSError.invalidMove("A folder can't be moved into itself.")
        }
        let newKey = HFSPlusCatalogKey(parentID: newParentID, name: units)
        if newKey == oldKey { return }
        if let existing = index(of: newKey), existing != oldIndex { throw HFSError.alreadyExists(HFSPlusName.decode(units)) }

        catalog.remove(at: oldIndex)
        insert(HFSPlusCatalogRecord(key: newKey, data: record.data))
        keyByID[id] = newKey
        if let thread = index(of: HFSPlusCatalogKey(parentID: id, name: [])) {
            let threadType: HFSPlusRecordType = record.type == .folder ? .folderThread : .fileThread
            catalog[thread].data = HFSPlusThreadRecord.make(type: threadType, parentID: newParentID, name: units)
        }
        if let newName { header.encodingsBitmap |= HFSPlusName.encodingsBitmapBit(for: HFSPlusName.textEncoding(for: newName)) }
        let now = HFSPlusDate.now
        touchFolder(oldKey.parentID, date: now)
        touchFolder(newParentID, date: now)
        dirty = true
    }

    @discardableResult
    func copyFile(_ id: UInt32, to parentID: UInt32, name: String) throws -> UInt32 {
        let source = try fileRecord(id)
        let data = try readForkBytes(id, fork: .data)
        let resource = try readForkBytes(id, fork: .resource)
        let metadata = NewFileMetadata(fileType: source.fileType, creator: source.creator, finderInfo: source.finderInfo,
                                       extendedFinderInfo: source.extendedFinderInfo,
                                       createDate: HFSPlusDate.date(source.createDate), modifyDate: HFSPlusDate.date(source.modifyDate))
        return try createFile(named: name, in: parentID, metadata: metadata, dataFork: HFSForkSource(bytes: data), resourceFork: HFSForkSource(bytes: resource))
    }

    func flush() throws {
        try checkOpen()
        guard dirty else { return }
        try checkWritable()
        do {
            try commit()
        } catch {
            rollBack()
            throw error
        }
    }

    func close() {
        isClosed = true
        device.close()
    }

    // MARK: - Commit

    private func commit() throws {
        let onDisk = try device.read(at: 1024, count: 512)
        guard onDisk == lastKnownHeaderSector else { throw HFSError.modifiedElsewhere }
        try markVolumeInUse()
        recomputeCounts()

        let oldCatalogFork = committed.header.fork(HFSPlusVolumeHeader.catalogFileOffset)
        let oldCatalog = Self.fullExtents(fileID: HFSCatalogID.catalogFile, fork: .data, data: oldCatalogFork, overflow: committed.extentsRecords)
        let oldExtentsFork = committed.header.fork(HFSPlusVolumeHeader.extentsFileOffset)
        let oldExtents = oldExtentsFork.extents
        let hint = Int(header.nextAllocation)

        // 1. Place the catalog; extents beyond the header's eight go in the extents tree.
        let catalogRecords = catalog.map { record -> BTree.BuildRecord in
            let key = record.key.encoded
            return BTree.BuildRecord(leafBytes: key + record.data, indexKey: indexKey(key))
        }
        let catalogPlan = try TreePlacement.plan(
            neededNodes: try BTree.minimumNodeCount(records: catalogRecords, nodeSize: catalogNodeSize),
            nodeSize: catalogNodeSize, blockSize: blockSize, clumpBytes: Int(oldCatalogFork.clumpSize),
            current: oldCatalog.map { (Int($0.startBlock), Int($0.blockCount)) }, currentNodes: Int(oldCatalogFork.logicalSize) / catalogNodeSize,
            maxExtents: nil, map: &allocation, hint: hint
        )
        let catalogRuns = catalogPlan.runs.map { HFSPlusExtent(startBlock: UInt32($0.start), blockCount: UInt32($0.count)) }
        extentsRecords.removeAll { $0.key.fileID == HFSCatalogID.catalogFile && $0.key.fork == .data }
        addOverflow(Array(catalogRuns.dropFirst(8)), fork: .data, fileID: HFSCatalogID.catalogFile, startingAt: catalogRuns.prefix(8).reduce(0) { $0 + Int($1.blockCount) })

        // 2. Place the extents tree (it can't overflow: at most eight extents).
        let extentsBuild = extentsRecords.map { BTree.BuildRecord(leafBytes: $0.key.encoded + HFSPlusForkData.encodeExtents($0.extents), indexKey: $0.key.encoded) }
        let extentsPlan = try TreePlacement.plan(
            neededNodes: try BTree.minimumNodeCount(records: extentsBuild, nodeSize: extentsNodeSize),
            nodeSize: extentsNodeSize, blockSize: blockSize, clumpBytes: Int(oldExtentsFork.clumpSize),
            current: oldExtents.map { (Int($0.startBlock), Int($0.blockCount)) }, currentNodes: Int(oldExtentsFork.logicalSize) / extentsNodeSize,
            maxExtents: 8, map: &allocation, hint: hint
        )
        guard extentsPlan.runs.count <= 8 else { throw HFSError.catalogFull }
        let extentsRuns = extentsPlan.runs.map { HFSPlusExtent(startBlock: UInt32($0.start), blockCount: UInt32($0.count)) }

        // 3. Write both trees.
        let extentsNodes = try BTree.build(records: extentsBuild, nodeCount: extentsPlan.nodeCount, template: extentsHeader, nodeSize: extentsNodeSize)
        let catalogNodes = try BTree.build(records: catalogRecords, nodeCount: catalogPlan.nodeCount, template: catalogHeader, nodeSize: catalogNodeSize)
        try writeForkBytes(extentsNodes.flatMap { $0 }, extents: extentsRuns)
        try writeForkBytes(catalogNodes.flatMap { $0 }, extents: catalogRuns)

        // 4. Bitmap with old and new structures both in use (the allocation file is written in
        //    place, but a superset of what's on disk can't free anything), then the commit.
        if !catalogPlan.inPlace {
            for extent in oldCatalog { allocation.set(start: Int(extent.startBlock), count: Int(extent.blockCount), used: false) }
        }
        if !extentsPlan.inPlace {
            for extent in oldExtents { allocation.set(start: Int(extent.startBlock), count: Int(extent.blockCount), used: false) }
        }
        let allocationExtents = Self.fullExtents(fileID: Self.allocationFileID, fork: .data, data: header.fork(HFSPlusVolumeHeader.allocationFileOffset), overflow: extentsRecords)
        try device.synchronize()
        try writeForkBytes(allocation.union, extents: allocationExtents)
        try device.synchronize()

        var catalogFork = oldCatalogFork
        catalogFork.extents = Array(catalogRuns.prefix(8))
        catalogFork.totalBlocks = UInt32(catalogRuns.reduce(0) { $0 + Int($1.blockCount) })
        catalogFork.logicalSize = UInt64(catalogPlan.nodeCount * catalogNodeSize)
        header.setFork(catalogFork, HFSPlusVolumeHeader.catalogFileOffset)
        var extentsFork = oldExtentsFork
        extentsFork.extents = extentsRuns
        extentsFork.totalBlocks = UInt32(extentsRuns.reduce(0) { $0 + Int($1.blockCount) })
        extentsFork.logicalSize = UInt64(extentsPlan.nodeCount * extentsNodeSize)
        header.setFork(extentsFork, HFSPlusVolumeHeader.extentsFileOffset)
        header.freeBlocks = UInt32(allocation.freeCount)
        header.modifyDate = HFSPlusDate.now
        header.writeCount &+= 1
        header.attributes |= HFSPlusVolumeHeader.unmountedCleanlyBit
        header.attributes &= ~HFSPlusVolumeHeader.inconsistentBit
        try device.write(header.raw, at: 1024)
        try device.synchronize()
        lastKnownHeaderSector = header.raw
        markedInUse = false

        // Committed.
        extentsHeader = try BTree.Header(raw: try BTree.records(of: extentsNodes[0], nodeSize: extentsNodeSize)[0])
        catalogHeader = try BTree.Header(raw: try BTree.records(of: catalogNodes[0], nodeSize: catalogNodeSize)[0])
        allocation.commit()
        committed = Committed(header: header, bitmap: allocation.committed, catalog: catalog, extentsRecords: extentsRecords,
                              catalogHeader: catalogHeader, extentsHeader: extentsHeader, keyByID: keyByID)
        dirty = false
        try writeForkBytes(allocation.working, extents: allocationExtents)
        let alternate = UInt64(totalBlocks) * UInt64(blockSize) - 1024
        if let sector = try? device.read(at: alternate, count: 512), let signature = try? sector.u16(0),
           signature == HFSPlusVolumeHeader.hfsPlusSignature || signature == HFSPlusVolumeHeader.hfsxSignature {
            try device.write(header.raw, at: alternate)
        }
        try device.synchronize()
    }

    private func rollBack() {
        header = committed.header
        allocation.rollBack(to: committed.bitmap)
        catalog = committed.catalog
        extentsRecords = committed.extentsRecords
        catalogHeader = committed.catalogHeader
        extentsHeader = committed.extentsHeader
        keyByID = committed.keyByID
        dirty = false
    }

    /// Before the first write of a batch: mark the volume in use (unmounted bit clear,
    /// inconsistent bit set), so a crash midway makes Mac OS and fsck check it.
    private func markVolumeInUse() throws {
        guard !markedInUse else { return }
        var inUse = committed.header
        inUse.attributes &= ~HFSPlusVolumeHeader.unmountedCleanlyBit
        inUse.attributes |= HFSPlusVolumeHeader.inconsistentBit
        try device.write(inUse.raw, at: 1024)
        try device.synchronize()
        lastKnownHeaderSector = inUse.raw
        markedInUse = true
    }

    // MARK: - Internals: catalog

    private static func comparator(caseSensitive: Bool) -> (HFSPlusCatalogKey, HFSPlusCatalogKey) -> Int {
        { lhs, rhs in
            if lhs.parentID != rhs.parentID { return lhs.parentID < rhs.parentID ? -1 : 1 }
            return caseSensitive ? HFSPlusName.compareBinary(lhs.name, rhs.name) : HFSPlusName.compareCaseInsensitive(lhs.name, rhs.name)
        }
    }

    private func compare(_ lhs: HFSPlusCatalogKey, _ rhs: HFSPlusCatalogKey) -> Int {
        if lhs.parentID != rhs.parentID { return lhs.parentID < rhs.parentID ? -1 : 1 }
        return caseSensitive ? HFSPlusName.compareBinary(lhs.name, rhs.name) : HFSPlusName.compareCaseInsensitive(lhs.name, rhs.name)
    }

    private func lowerBound(_ key: HFSPlusCatalogKey) -> Int {
        var low = 0, high = catalog.count
        while low < high {
            let mid = (low + high) / 2
            if compare(catalog[mid].key, key) < 0 { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private func index(of key: HFSPlusCatalogKey) -> Int? {
        let position = lowerBound(key)
        return position < catalog.count && compare(catalog[position].key, key) == 0 ? position : nil
    }

    private func insert(_ record: HFSPlusCatalogRecord) {
        catalog.insert(record, at: lowerBound(record.key))
    }

    private func childRecordIndices(of folderID: UInt32) -> [Int] {
        var result: [Int] = []
        var position = lowerBound(HFSPlusCatalogKey(parentID: folderID, name: []))
        while position < catalog.count, catalog[position].key.parentID == folderID {
            if catalog[position].type == .folder || catalog[position].type == .file { result.append(position) }
            position += 1
        }
        return result
    }

    private func fileRecord(_ id: UInt32) throws -> HFSPlusFileRecord {
        try checkOpen()
        guard let key = keyByID[id], let index = index(of: key), catalog[index].type == .file else { throw HFSError.notFound("File \(id)") }
        return try HFSPlusFileRecord(raw: catalog[index].data)
    }

    private func makeItem(_ record: HFSPlusCatalogRecord) throws -> VolumeItem {
        let name = HFSPlusName.decode(record.key.name)
        switch record.type {
        case .folder:
            let folder = try HFSPlusFolderRecord(raw: record.data)
            return VolumeItem(
                id: folder.id, parentID: record.key.parentID, name: name, isFolder: true,
                dataLength: 0, resourceLength: 0, fileType: [], creator: [], finderFlags: folder.finderFlags, isLocked: false,
                createDate: HFSPlusDate.date(folder.createDate), modifyDate: HFSPlusDate.date(folder.modifyDate),
                valence: childRecordIndices(of: folder.id).count
            )
        case .file:
            let file = try HFSPlusFileRecord(raw: record.data)
            return VolumeItem(
                id: file.id, parentID: record.key.parentID, name: name, isFolder: false,
                dataLength: file.fork(.data).logicalSize, resourceLength: file.fork(.resource).logicalSize,
                fileType: file.fileType, creator: file.creator, finderFlags: file.finderFlags,
                isLocked: file.flags & HFSPlusFileRecord.lockedFlag != 0,
                createDate: HFSPlusDate.date(file.createDate), modifyDate: HFSPlusDate.date(file.modifyDate), valence: 0
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
    }

    private func checkCanAdd(_ units: [UInt16], to parentID: UInt32) throws {
        guard try item(parentID).isFolder else { throw HFSError.notFound("Folder \(parentID)") }
        if index(of: HFSPlusCatalogKey(parentID: parentID, name: units)) != nil { throw HFSError.alreadyExists(HFSPlusName.decode(units)) }
    }

    private func allocateCatalogID() throws -> UInt32 {
        let id = max(header.nextCatalogID, HFSCatalogID.firstUserID)
        guard id < UInt32.max else { throw HFSError.catalogFull }
        header.nextCatalogID = id + 1
        return id
    }

    private func touchFolder(_ id: UInt32, date: UInt32) {
        guard let key = keyByID[id], let index = index(of: key), var folder = try? HFSPlusFolderRecord(raw: catalog[index].data) else { return }
        folder.modifyDate = date
        catalog[index].data = folder.raw
    }

    /// Valences and volume totals are recomputed from the catalog on each flush. (The root
    /// folder isn't counted in the volume's folder total.)
    private func recomputeCounts() {
        var children: [UInt32: Int] = [:]
        var subfolders: [UInt32: Int] = [:]
        var files = 0, folders = 0
        for record in catalog {
            switch record.type {
            case .file: files += 1; children[record.key.parentID, default: 0] += 1
            case .folder: folders += 1; children[record.key.parentID, default: 0] += 1; subfolders[record.key.parentID, default: 0] += 1
            default: break
            }
        }
        for index in catalog.indices where catalog[index].type == .folder {
            guard var folder = try? HFSPlusFolderRecord(raw: catalog[index].data) else { continue }
            folder.valence = UInt32(children[folder.id, default: 0])
            if folder.flags & HFSPlusFolderRecord.hasFolderCountFlag != 0 {
                folder.folderCount = UInt32(subfolders[folder.id, default: 0])
            }
            catalog[index].data = folder.raw
        }
        header.fileCount = UInt32(files)
        header.folderCount = UInt32(max(0, folders - 1))
    }

    /// Index keys are the leaf keys when the tree uses variable-length index keys (every
    /// HFS Plus catalog does); otherwise they're padded to the maximum key length.
    private func indexKey(_ leafKey: [UInt8]) -> [UInt8] {
        if variableIndexKeys { return leafKey }
        let maxKeyLength = Int(catalogHeader.maxKeyLength)
        var padded = leafKey + [UInt8](repeating: 0, count: max(0, 2 + maxKeyLength - leafKey.count))
        padded.put16(UInt16(maxKeyLength), at: 0)
        return padded
    }

    // MARK: - Internals: allocation and forks

    private func writeNewFork(_ source: HFSForkSource) throws -> [HFSPlusExtent] {
        let blocks = Int((source.length + UInt64(blockSize) - 1) / UInt64(blockSize))
        let extents = try allocation.allocate(blocks, hint: Int(header.nextAllocation))
            .map { HFSPlusExtent(startBlock: UInt32($0.start), blockCount: UInt32($0.count)) }
        if let last = extents.last { header.nextAllocation = last.startBlock + last.blockCount }
        var offset: UInt64 = 0
        let chunk = max(blockSize, (1 << 20) / blockSize * blockSize)
        for extent in extents {
            var position = UInt64(extent.startBlock) * UInt64(blockSize)
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

    private func store(_ extents: [HFSPlusExtent], fork: HFSFork, length: UInt64, fileID: UInt32, in file: inout HFSPlusFileRecord) {
        let blocks = extents.reduce(0) { $0 + Int($1.blockCount) }
        let clump = fork == .data ? header.dataClumpSize : header.resourceClumpSize
        file.setFork(fork, HFSPlusForkData(logicalSize: length, clumpSize: clump, totalBlocks: UInt32(blocks), extents: Array(extents.prefix(8))))
        addOverflow(Array(extents.dropFirst(8)), fork: fork, fileID: fileID, startingAt: extents.prefix(8).reduce(0) { $0 + Int($1.blockCount) })
    }

    private func addOverflow(_ extents: [HFSPlusExtent], fork: HFSFork, fileID: UInt32, startingAt firstBlock: Int) {
        var forkBlock = firstBlock
        var rest = extents
        while !rest.isEmpty {
            let group = Array(rest.prefix(8))
            rest.removeFirst(group.count)
            let key = HFSPlusExtentsKey(fork: fork, fileID: fileID, startBlock: UInt32(forkBlock))
            let position = extentsRecords.firstIndex { HFSPlusExtentsKey.compare($0.key, key) > 0 } ?? extentsRecords.count
            extentsRecords.insert((key, group), at: position)
            forkBlock += group.reduce(0) { $0 + Int($1.blockCount) }
        }
    }

    private static func fullExtents(fileID: UInt32, fork: HFSFork, data: HFSPlusForkData, overflow: [(key: HFSPlusExtentsKey, extents: [HFSPlusExtent])]) -> [HFSPlusExtent] {
        var result = data.extents
        var nextStart = result.reduce(0) { $0 + Int($1.blockCount) }
        while nextStart < Int(data.totalBlocks),
              let next = overflow.first(where: { $0.key.fileID == fileID && $0.key.fork == fork && Int($0.key.startBlock) == nextStart }) {
            if next.extents.isEmpty { break }
            result += next.extents
            nextStart += next.extents.reduce(0) { $0 + Int($1.blockCount) }
        }
        return result
    }

    /// Reads `count` bytes at a fork-relative offset (may span extents).
    private static func forkReader(_ extents: [HFSPlusExtent], logicalSize: UInt64, device: BlockDevice, blockSize: Int) -> (UInt64, Int) throws -> [UInt8] {
        { offset, count in
            guard offset <= logicalSize, UInt64(count) <= logicalSize - offset else { throw HFSError.corrupt("read past the end of a volume structure") }
            var result: [UInt8] = []
            result.reserveCapacity(count)
            var position = offset
            var remaining = count
            var base: UInt64 = 0
            for extent in extents where remaining > 0 {
                let length = UInt64(extent.blockCount) * UInt64(blockSize)
                if position < base + length {
                    let within = position - base
                    let take = Int(min(UInt64(remaining), length - within))
                    result += try device.read(at: UInt64(extent.startBlock) * UInt64(blockSize) + within, count: take)
                    position += UInt64(take)
                    remaining -= take
                }
                base += length
            }
            guard remaining == 0 else { throw HFSError.corrupt("a volume structure isn't covered by its extents") }
            return result
        }
    }

    private func writeForkBytes(_ bytes: [UInt8], extents: [HFSPlusExtent]) throws {
        var offset = 0
        for extent in extents where offset < bytes.count {
            let length = Int(extent.blockCount) * blockSize
            let take = min(length, bytes.count - offset)
            try device.write(Array(bytes[offset..<(offset + take)]), at: UInt64(extent.startBlock) * UInt64(blockSize))
            offset += take
        }
        guard offset == bytes.count else { throw HFSError.corrupt("a volume structure isn't covered by its extents") }
    }

    /// The node size is in the header record of node 0.
    private static func nodeSize(reading reader: (UInt64, Int) throws -> [UInt8]) throws -> Int {
        let start = try reader(0, 512)
        let size = Int(try start.u16(BTree.descriptorSize + 18))
        guard size >= 512, size <= 32768, size.nonzeroBitCount == 1 else { throw HFSError.corrupt("bad B-tree node size") }
        return size
    }
}

private final class ForkCollector: @unchecked Sendable {
    private(set) var bytes: [UInt8] = []
    func append(_ chunk: [UInt8]) { bytes += chunk }
}
