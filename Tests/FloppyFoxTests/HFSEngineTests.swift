import XCTest
@testable import FloppyFox

/// Tests for the in-process HFS engine (`HFSVolume`), which replaces hdiutil and hfsutils so the
/// app can run in the App Sandbox. Every write test is judged by two independent oracles:
/// Apple's `fsck_hfs` (structural validity — key order, B-tree links, valences, bitmap, MDB
/// totals) and hfsutils (the content actually reads back as written).
final class HFSEngineTests: XCTestCase {
    private var work: URL!

    override func setUp() async throws {
        guard Fixtures.hfsutilsPrefix != nil else { throw XCTSkip("hfsutils (brew install hfsutils) is required as a test oracle") }
        work = try Fixtures.makeWorkDirectory("engine")
    }

    override func tearDown() async throws {
        if let work, ProcessInfo.processInfo.environment["FLOPPYFOX_KEEP_TEST_IMAGES"] == nil { try? FileManager.default.removeItem(at: work) }
    }

    private func assertFsckClean(_ image: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let verdict = try Fixtures.fsck(image)
        XCTAssertTrue(verdict.clean, "fsck_hfs rejected the volume:\n\(verdict.output)", file: file, line: line)
    }

    /// Names are plain strings; the volume validates them.
    private func name(_ string: String) throws -> String { string }

    private func child(_ volume: HFSVolume, _ name: String, in folder: UInt32, file: StaticString = #filePath, line: UInt = #line) async throws -> VolumeItem {
        let item = await volume.child(named: name, inFolder: folder)
        return try XCTUnwrap(item, "no \(name) in folder \(folder)", file: file, line: line)
    }

    private func randomBytes(_ count: Int, seed: UInt64) -> [UInt8] {
        var generator = SeededGenerator(seed: seed)
        return (0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) }
    }

    // MARK: Reading what hfsutils wrote

    func testReadsFilesFoldersForksAndFinderInfoWrittenByHFSUtils() async throws {
        let image = try Fixtures.makeClassicHFSImage(in: work)
        let data = randomBytes(5000, seed: 1)
        let resource = randomBytes(700, seed: 2)
        let macBinary = MacBinaryFile(name: try HFSName("Both Forks"), fileType: Array("APPL".utf8), creator: Array("TEST".utf8), finderFlags: 0, dataFork: data, resourceFork: resource)
        let binURL = work.appendingPathComponent("both.bin")
        try Data(macBinary.encoded()).write(to: binURL)
        try Fixtures.withMounted(image) {
            try Fixtures.hfs("hmkdir", [":Folder"])
            try Fixtures.hfs("hmkdir", [":Folder:Nested"])
            try Fixtures.hfs("hcopy", ["-m", binURL.path, ":Folder:Both Forks"])
            try Fixtures.putFile(Data("plain".utf8), at: ":Plain", type: "TEXT", creator: "ttxt", scratch: work)
        }

        let volume = try HFSVolume.open(image, readOnly: true)
        let root = try await volume.contents(ofFolder: HFSCatalogID.rootFolder)
        XCTAssertEqual(Set(root.map(\.name)), ["Folder", "Plain"])
        let plain = try XCTUnwrap(root.first { $0.name == "Plain" })
        XCTAssertEqual(plain.fileType, Array("TEXT".utf8))
        XCTAssertEqual(plain.creator, Array("ttxt".utf8))
        let folder = try XCTUnwrap(root.first { $0.isFolder })
        XCTAssertEqual(folder.valence, 2)

        let inner = try await volume.contents(ofFolder: folder.id)
        let both = try XCTUnwrap(inner.first { $0.name == "Both Forks" })
        XCTAssertEqual(both.fileType, Array("APPL".utf8))
        let readData = try await volume.readForkBytes(both.id, fork: .data)
        let readResource = try await volume.readForkBytes(both.id, fork: .resource)
        XCTAssertEqual(readData, data)
        XCTAssertEqual(readResource, resource)
        let path = try await volume.path(of: both.id).map(\.name)
        XCTAssertEqual(path, ["Folder", "Both Forks"])
    }

    // MARK: Writing, judged by fsck_hfs and hfsutils

    func testEngineWritesPassFsckAndReadBackThroughHFSUtils() async throws {
        let image = try Fixtures.makeClassicHFSImage(in: work)
        try assertFsckClean(image) // sanity: the oracle accepts a blank hformat volume

        let data = randomBytes(40_000, seed: 3)
        let resource = randomBytes(1_234, seed: 4)
        do {
            let volume = try HFSVolume.open(image, readOnly: false)
            let docs = try await volume.createFolder(named: try name("Documents"), in: HFSCatalogID.rootFolder)
            let deep = try await volume.createFolder(named: try name("Deep"), in: docs)
            _ = try await volume.createFile(named: try name("App"), in: deep, type: Array("APPL".utf8), creator: Array("FFOX".utf8),
                                            dataFork: HFSForkSource(bytes: data), resourceFork: HFSForkSource(bytes: resource))
            let doomed = try await volume.createFile(named: try name("Doomed"), in: docs, type: Array("TEXT".utf8), creator: Array("ttxt".utf8),
                                                     dataFork: HFSForkSource(bytes: [1, 2, 3]), resourceFork: .empty)
            let movable = try await volume.createFile(named: try name("Movable"), in: docs, type: Array("TEXT".utf8), creator: Array("ttxt".utf8),
                                                      dataFork: HFSForkSource(bytes: Array("move me".utf8)), resourceFork: .empty)
            try await volume.delete(doomed)
            try await volume.move(movable, to: HFSCatalogID.rootFolder, newName: try name("Moved & Renamed"))
            try await volume.flush()
        }
        try assertFsckClean(image)

        try Fixtures.withMounted(image) {
            XCTAssertEqual(try Fixtures.names(in: ":"), ["Documents", "Moved & Renamed"])
            XCTAssertEqual(try Fixtures.names(in: ":Documents"), ["Deep"])
            XCTAssertEqual(try Fixtures.readFile(":Moved & Renamed", scratch: work), Data("move me".utf8))
            let appPath = ":Documents:Deep:App"
            XCTAssertEqual(try Fixtures.readFile(appPath, scratch: work), Data(data))
            XCTAssertTrue(try Fixtures.longListing(of: appPath).contains("APPL/FFOX"))
            let exported = work.appendingPathComponent("app.bin")
            try Fixtures.hfs("hcopy", ["-m", appPath, exported.path])
            let decoded = try XCTUnwrap(MacBinaryFile.decode(Array(try Data(contentsOf: exported))), "hfsutils' MacBinary export didn't decode")
            XCTAssertEqual(decoded.resourceFork, resource)
            XCTAssertEqual(decoded.dataFork, data)
        }
    }

    /// Hundreds of entries outgrow a floppy's initial catalog file (forcing it to grow) and
    /// need a multi-level index; deleting most of them shrinks the tree again.
    func testCatalogGrowsToAMultiLevelTreeAndShrinksBack() async throws {
        let image = try Fixtures.makeClassicHFSImage(in: work)
        let count = 700
        do {
            let volume = try HFSVolume.open(image, readOnly: false)
            let folder = try await volume.createFolder(named: try name("Many"), in: HFSCatalogID.rootFolder)
            for i in 0..<count {
                _ = try await volume.createFile(named: try name(String(format: "File %04d with a long name", i)), in: folder, type: Array("TEXT".utf8), creator: Array("ttxt".utf8),
                                                dataFork: .empty, resourceFork: .empty)
            }
            try await volume.flush()
        }
        try assertFsckClean(image)
        try Fixtures.withMounted(image) { XCTAssertEqual(try Fixtures.names(in: ":Many").count, count) }

        do {
            let volume = try HFSVolume.open(image, readOnly: false)
            let maybeFolder = await volume.child(named: try name("Many"), inFolder: HFSCatalogID.rootFolder)
            let folder = try XCTUnwrap(maybeFolder)
            for item in try await volume.contents(ofFolder: folder.id).dropFirst(10) {
                try await volume.delete(item.id)
            }
            try await volume.flush()
        }
        try assertFsckClean(image)
        try Fixtures.withMounted(image) { XCTAssertEqual(try Fixtures.names(in: ":Many").count, 10) }
    }

    /// A file written into a checkerboard of free space needs more than three extents, so the
    /// rest must go to the extents-overflow B-tree.
    func testFragmentedFileSpillsIntoTheExtentsOverflowTree() async throws {
        let image = try Fixtures.makeClassicHFSImage(in: work)
        let payload = randomBytes(30 * 512, seed: 5)
        do {
            let volume = try HFSVolume.open(image, readOnly: false)
            var fillers: [UInt32] = []
            for i in 0..<60 {
                fillers.append(try await volume.createFile(named: try name("filler \(i)"), in: HFSCatalogID.rootFolder, type: Array("TEXT".utf8), creator: Array("ttxt".utf8),
                                                           dataFork: HFSForkSource(bytes: [UInt8](repeating: UInt8(i), count: 512)), resourceFork: .empty))
            }
            for (index, id) in fillers.enumerated() where index % 2 == 0 { try await volume.delete(id) }
            // Leave no long free run: consume everything after the checkerboard.
            let free = Int(await volume.freeBytes) - 30 * 512 - 10 * 512
            if free > 0 {
                _ = try await volume.createFile(named: try name("ballast"), in: HFSCatalogID.rootFolder, type: Array("TEXT".utf8), creator: Array("ttxt".utf8),
                                                dataFork: HFSForkSource(bytes: [UInt8](repeating: 0, count: free)), resourceFork: .empty)
            }
            _ = try await volume.createFile(named: try name("Fragmented"), in: HFSCatalogID.rootFolder, type: Array("TEXT".utf8), creator: Array("ttxt".utf8),
                                            dataFork: HFSForkSource(bytes: payload), resourceFork: .empty)
            try await volume.flush()
        }
        try assertFsckClean(image)
        try Fixtures.withMounted(image) {
            XCTAssertEqual(try Fixtures.readFile(":Fragmented", scratch: work), Data(payload))
        }
        // And our own reader agrees after a fresh open.
        let volume = try HFSVolume.open(image, readOnly: true)
        let maybeFragmented = await volume.child(named: try name("Fragmented"), inFolder: HFSCatalogID.rootFolder)
        let fragmented = try XCTUnwrap(maybeFragmented)
        let readBack = try await volume.readForkBytes(fragmented.id, fork: .data)
        XCTAssertEqual(readBack, payload)
    }

    /// Volumes over 32 MB use allocation blocks larger than 512 bytes; a big file on one
    /// exercises block-size arithmetic everywhere (allocation, fork lengths, node positions).
    /// (A blank `hformat` volume of exactly 32 MB is itself rejected by fsck_hfs, so the
    /// sizes here are 40 MB — 1 KB blocks — and 100 MB — 2 KB blocks.)
    func testLargeFilesOnVolumesWithLargerAllocationBlocks() async throws {
        for sizeMB in [40, 100] {
            try await assertLargeFileRoundTrips(onVolumeOfMB: sizeMB)
        }
    }

    private func assertLargeFileRoundTrips(onVolumeOfMB sizeMB: Int) async throws {
        let image = try Fixtures.makeClassicHFSImage(in: work, name: "\(sizeMB)MB.dsk", sizeKB: sizeMB * 1024)
        let payload = randomBytes(20 * 1024 * 1024 + 123, seed: UInt64(sizeMB))
        do {
            let volume = try HFSVolume.open(image, readOnly: false)
            _ = try await volume.createFile(named: try name("Big"), in: HFSCatalogID.rootFolder, type: Array("BINA".utf8), creator: Array("????".utf8),
                                            dataFork: HFSForkSource(bytes: payload), resourceFork: .empty)
            try await volume.flush()
        }
        try assertFsckClean(image)
        try Fixtures.withMounted(image) {
            XCTAssertEqual(try Fixtures.readFile(":Big", scratch: work), Data(payload))
        }
    }

    /// Writes names covering every Mac Roman byte; Apple's checker rejects the catalog if our
    /// ordering differs from Mac OS's anywhere.
    func testNameOrderMatchesApplesCatalogChecker() async throws {
        let image = try Fixtures.makeClassicHFSImage(in: work, sizeKB: 4096)
        var created = 0
        do {
            let volume = try HFSVolume.open(image, readOnly: false)
            for byte in UInt8(1)...UInt8(255) where byte != UInt8(ascii: ":") {
                for bytes in [[byte], [UInt8(ascii: "a"), byte], [byte, UInt8(ascii: "z"), byte]] {
                    do {
                        _ = try await volume.createFolder(named: HFSName(bytes: bytes).string, in: HFSCatalogID.rootFolder)
                        created += 1
                    } catch HFSError.alreadyExists, HFSError.invalidName {
                        // Case-insensitively equal to a name already present (e.g. "a" vs "A"),
                        // or "."/"..".
                    }
                }
            }
            try await volume.flush()
        }
        XCTAssertGreaterThan(created, 500)
        try assertFsckClean(image)
    }

    // MARK: Rules and failure modes

    func testRejectsDuplicateNamesCaseInsensitivelyAndInvalidMoves() async throws {
        let image = try Fixtures.makeClassicHFSImage(in: work)
        let volume = try HFSVolume.open(image, readOnly: false)
        let folder = try await volume.createFolder(named: try name("ReadMe"), in: HFSCatalogID.rootFolder)
        let child = try await volume.createFolder(named: try name("Child"), in: folder)
        _ = try await volume.createFile(named: try name("File"), in: child, type: [], creator: [], dataFork: .empty, resourceFork: .empty)

        await assertThrows(HFSError.alreadyExists("readme")) { try await volume.createFolder(named: try self.name("readme"), in: HFSCatalogID.rootFolder) }
        await assertThrows(HFSError.invalidMove("A folder can't be moved into itself.")) { try await volume.move(folder, to: child) }
        await assertThrows(HFSError.invalidMove("A folder can't be moved into itself.")) { try await volume.move(folder, to: folder) }
        await assertThrows(HFSError.directoryNotEmpty("Child")) { try await volume.delete(child) }
        XCTAssertThrowsError(try HFSName("a:b"))
        XCTAssertThrowsError(try HFSName(String(repeating: "x", count: 32)))

        // A case-only rename is allowed.
        try await volume.move(folder, to: HFSCatalogID.rootFolder, newName: try name("README"))
        try await volume.flush()
        await volume.close()
        try assertFsckClean(image)
        try Fixtures.withMounted(image) { XCTAssertEqual(try Fixtures.names(in: ":"), ["README"]) }
    }

    func testCancelledOrOversizedWritesLeaveTheVolumeUntouched() async throws {
        let image = try Fixtures.makeClassicHFSImage(in: work, sizeKB: 8 * 1024)
        let before = try Data(contentsOf: image)
        let volume = try HFSVolume.open(image, readOnly: false)
        let freeBefore = await volume.freeBytes

        // Several 1 MB chunks, cancelled after the first has been written to the image.
        let cancelling = HFSForkSource(length: 4_000_000) { offset, count in
            if offset >= 1_000_000 { throw CancellationError() }
            return [UInt8](repeating: 7, count: count)
        }
        do {
            _ = try await volume.createFile(named: try name("Cancelled"), in: HFSCatalogID.rootFolder, type: [], creator: [], dataFork: cancelling, resourceFork: .empty)
            XCTFail("expected cancellation")
        } catch is CancellationError {}
        await assertThrows(HFSError.volumeFull) {
            try await volume.createFile(named: try self.name("Too Big"), in: HFSCatalogID.rootFolder, type: [], creator: [],
                                        dataFork: HFSForkSource(length: 50_000_000) { _, count in [UInt8](repeating: 0, count: count) }, resourceFork: .empty)
        }
        let freeAfter = await volume.freeBytes
        XCTAssertEqual(freeAfter, freeBefore, "blocks of a failed write must be released")
        try await volume.flush() // nothing pending: must not touch the image
        let cancelledItem = await volume.child(named: try name("Cancelled"), inFolder: HFSCatalogID.rootFolder)
        XCTAssertNil(cancelledItem)

        // Data blocks of the cancelled write may have been scribbled on, but they were free
        // space; the structures must be byte-identical.
        let after = try Data(contentsOf: image)
        XCTAssertEqual(after.prefix(1536), before.prefix(1536), "boot blocks and MDB changed")
        await volume.close()
        try assertFsckClean(image)
    }

    func testReadOnlyVolumeRefusesWrites() async throws {
        let image = try Fixtures.makeClassicHFSImage(in: work)
        let volume = try HFSVolume.open(image, readOnly: true)
        await assertThrows(HFSError.readOnly) { try await volume.createFolder(named: try self.name("No"), in: HFSCatalogID.rootFolder) }
    }

    /// Damaged images must fail to open (or open) — never crash or hang.
    func testCorruptedImagesNeverCrash() async throws {
        let image = try Fixtures.makeClassicHFSImage(in: work)
        try Fixtures.withMounted(image) {
            for i in 0..<30 { try Fixtures.putFile(Data(repeating: UInt8(i), count: 300), at: ":f\(i)", scratch: work) }
        }
        let pristine = Array(try Data(contentsOf: image))
        var generator = SeededGenerator(seed: 0xBAD)
        for round in 0..<150 {
            var damaged = pristine
            // Concentrate damage on the MDB, bitmap and the start of the B-tree files.
            for _ in 0..<Int.random(in: 1...40, using: &generator) {
                let position = Int.random(in: 1024..<min(damaged.count, 40_000), using: &generator)
                damaged[position] = UInt8.random(in: 0...255, using: &generator)
            }
            if round % 10 == 0 { damaged = Array(damaged.prefix(Int.random(in: 0..<damaged.count, using: &generator))) }
            let url = work.appendingPathComponent("damaged-\(round).dsk")
            try Data(damaged).write(to: url)
            guard let volume = try? HFSVolume.open(url, readOnly: true) else { continue }
            if let items = try? await volume.contents(ofFolder: HFSCatalogID.rootFolder) {
                for item in items.prefix(5) where !item.isFolder {
                    _ = try? await volume.readForkBytes(item.id, fork: .data)
                }
            }
        }
    }

    // MARK: Containers

    func testFindsVolumesInPartitionMapsAndRejectsNonHFS() throws {
        // A minimal Apple Partition Map wrapping a real HFS volume.
        let volume = Array(try Data(contentsOf: try Fixtures.makeClassicHFSImage(in: work)))
        let partitionStart = 64 // blocks
        var disk = [UInt8](repeating: 0, count: partitionStart * 512)
        disk.put16(0x4552, at: 0)
        disk.put16(512, at: 2)
        func entry(_ index: Int, start: Int, blocks: Int, name: String, type: String) {
            let base = 512 * (1 + index)
            disk.put16(0x504D, at: base)
            disk.put32(2, at: base + 4)
            disk.put32(UInt32(start), at: base + 8)
            disk.put32(UInt32(blocks), at: base + 12)
            disk.put(Array(name.utf8), at: base + 16)
            disk.put(Array(type.utf8), at: base + 48)
        }
        entry(0, start: 1, blocks: 63, name: "Apple", type: "Apple_partition_map")
        entry(1, start: partitionStart, blocks: volume.count / 512, name: "MacOS", type: "Apple_HFS")
        disk += volume
        let url = work.appendingPathComponent("disk.hda")
        try Data(disk).write(to: url)

        let locations = try DiskImageLayout.volumes(in: url)
        XCTAssertEqual(locations, [HFSVolumeLocation(offset: UInt64(partitionStart * 512), length: UInt64(volume.count), partitionName: "MacOS", readOnlyReason: nil)])
        XCTAssertNoThrow(try HFSVolume.open(url, readOnly: true))

        let junk = work.appendingPathComponent("junk.img")
        try Data(repeating: 0x41, count: 100_000).write(to: junk)
        XCTAssertThrowsError(try DiskImageLayout.volumes(in: junk))
    }

    /// Real disks exist whose partition map was shrunk after formatting, so the volume
    /// claims more than its partition. Mac OS trusts the volume; so does reading here, but
    /// writing is refused (the extra space may belong to something else). A volume that runs
    /// past the end of the image file itself is still rejected.
    func testAVolumeLargerThanItsPartitionOpensReadOnly() async throws {
        let volume = Array(try Data(contentsOf: try Fixtures.makeClassicHFSImage(in: work)))
        let partitionStart = 64
        func disk(partitionBlocks: Int, truncatedBy cut: Int = 0) throws -> URL {
            var disk = [UInt8](repeating: 0, count: partitionStart * 512)
            disk.put16(0x4552, at: 0)
            disk.put16(512, at: 2)
            for (index, (start, blocks, type)) in [(1, 63, "Apple_partition_map"), (partitionStart, partitionBlocks, "Apple_HFS")].enumerated() {
                let base = 512 * (1 + index)
                disk.put16(0x504D, at: base)
                disk.put32(2, at: base + 4)
                disk.put32(UInt32(start), at: base + 8)
                disk.put32(UInt32(blocks), at: base + 12)
                disk.put(Array("MacOS".utf8), at: base + 16)
                disk.put(Array(type.utf8), at: base + 48)
            }
            disk += volume.dropLast(cut)
            let url = work.appendingPathComponent("shrunk-\(partitionBlocks)-\(cut).hda")
            try Data(disk).write(to: url)
            return url
        }
        let url = try disk(partitionBlocks: volume.count / 512 - 100)
        let location = try XCTUnwrap(DiskImageLayout.volumes(in: url).first)
        XCTAssertEqual(location.length, UInt64(volume.count), "the volume's own size should be used")
        XCTAssertNotNil(location.readOnlyReason)
        let opened = try DiskImageLayout.openVolume(url, readOnly: false)
        XCTAssertTrue(opened.isReadOnly)
        let listed = try await opened.contents(ofFolder: HFSCatalogID.rootFolder)
        XCTAssertNotNil(listed)
        await opened.close()

        let truncated = try disk(partitionBlocks: volume.count / 512 - 100, truncatedBy: 50 * 512)
        XCTAssertThrowsError(try DiskImageLayout.volumes(in: truncated))
    }

    func testOpensRealPartitionedHardDiskImageIfPresent() async throws {
        let url = URL(fileURLWithPath: "/Users/amuskens/Downloads/ PreInstalled MacOS Images/HD0-OpenRetroSCSI-7.1.hda")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("real HDA fixture not present") }
        let volume = try HFSVolume.open(url, readOnly: true)
        let names = Set(try await volume.contents(ofFolder: HFSCatalogID.rootFolder).map(\.name))
        XCTAssertTrue(names.contains("System Folder 7.1"), "\(names)")
        XCTAssertTrue(names.contains("SimpleText"))
    }

    /// The strongest check available: edit a volume Mac OS itself created (a real System 7.1
    /// BlueSCSI hard-disk image, cloned so the original is never touched) and confirm Apple's
    /// checker still considers it healthy.
    func testEditingARealMacOSVolumeKeepsItFsckClean() async throws {
        let original = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FLOPPYFOX_REAL_HDA"]
            ?? "/Users/amuskens/Downloads/ PreInstalled MacOS Images/HD0-OpenRetroSCSI-7.1.hda")
        guard FileManager.default.fileExists(atPath: original.path) else { throw XCTSkip("set FLOPPYFOX_REAL_HDA to a Mac OS-written .hda image") }
        let image = work.appendingPathComponent("real.hda")
        try FileManager.default.copyItem(at: original, to: image) // an APFS clone: instant
        let baseline = try Fixtures.fsck(image)
        guard baseline.clean else { throw XCTSkip("the original image isn't fsck-clean to begin with:\n\(baseline.output)") }

        let payload = randomBytes(300_000, seed: 8)
        var sourceName = "", movedName = ""
        let resource = randomBytes(9_000, seed: 9)
        do {
            let volume = try HFSVolume.open(image, readOnly: false)
            let root = try await volume.contents(ofFolder: HFSCatalogID.rootFolder)
            // Any root file with a resource fork (an application or document) to duplicate,
            // and any other root item to move.
            let simpleText = try XCTUnwrap(root.first { !$0.isFolder && $0.resourceLength > 0 }, "no root file with a resource fork")
            sourceName = simpleText.name
            let folder = try await volume.createFolder(named: try name("FloppyFox Test"), in: HFSCatalogID.rootFolder)
            _ = try await volume.createFile(named: try name("Imported"), in: folder, type: Array("APPL".utf8), creator: Array("FFOX".utf8),
                                            dataFork: HFSForkSource(bytes: payload), resourceFork: HFSForkSource(bytes: resource))
            _ = try await volume.copyFile(simpleText.id, to: folder, name: try name("SimpleText Copy"))
            let movable = try XCTUnwrap(root.first { $0.id != simpleText.id && !$0.isLocked })
            movedName = movable.name
            try await volume.move(movable.id, to: folder, newName: try name("Moved Item"))
            try await volume.flush()
        }
        try assertFsckClean(image)

        // Reopen fresh and compare content with the original image.
        let volume = try HFSVolume.open(image, readOnly: true)
        let pristine = try HFSVolume.open(original, readOnly: true)
        let folder = try await child(volume, "FloppyFox Test", in: HFSCatalogID.rootFolder)
        let copy = try await child(volume, "SimpleText Copy", in: folder.id)
        let source = try await child(pristine, sourceName, in: HFSCatalogID.rootFolder)
        let copyResource = try await volume.readForkBytes(copy.id, fork: .resource)
        let sourceResource = try await pristine.readForkBytes(source.id, fork: .resource)
        XCTAssertEqual(copyResource, sourceResource)
        XCTAssertEqual(copy.fileType, source.fileType)
        XCTAssertEqual(copy.creator, source.creator)
        let imported = try await child(volume, "Imported", in: folder.id)
        let importedData = try await volume.readForkBytes(imported.id, fork: .data)
        XCTAssertEqual(importedData, payload)
        let rootNames = Set(try await volume.contents(ofFolder: HFSCatalogID.rootFolder).map(\.name))
        XCTAssertFalse(rootNames.contains(movedName))
        _ = try await child(volume, "Moved Item", in: folder.id)
    }

    // MARK: MacBinary

    func testMacBinaryRoundTripsAndInteroperatesWithHFSUtils() throws {
        let file = MacBinaryFile(name: try HFSName("Round Trip"), fileType: Array("PICT".utf8), creator: Array("MDRW".utf8), finderFlags: 0x4100,
                                 dataFork: randomBytes(333, seed: 6), resourceFork: randomBytes(129, seed: 7))
        XCTAssertEqual(MacBinaryFile.decode(file.encoded()), file)
        XCTAssertNil(MacBinaryFile.decode(Array("definitely not macbinary, just text".utf8) + [UInt8](repeating: 0, count: 200)))
    }

    private func assertThrows(_ expected: HFSError, file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> Any) async {
        do {
            _ = try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as HFSError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected \(expected), got \(error)", file: file, line: line)
        }
    }
}
