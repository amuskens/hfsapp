import XCTest
@testable import FloppyFox

/// Regression tests for the findings of the third independent engine review.
final class ThirdReviewTests: XCTestCase {
    private var work: URL!

    override func setUp() async throws {
        guard Fixtures.hfsutilsPrefix != nil else { throw XCTSkip("hfsutils (brew install hfsutils) is required as a test oracle") }
        work = try Fixtures.makeWorkDirectory("review3")
    }

    override func tearDown() async throws {
        if let work, ProcessInfo.processInfo.environment["FLOPPYFOX_KEEP_TEST_IMAGES"] == nil { try? FileManager.default.removeItem(at: work) }
    }

    private func openHFS(_ url: URL, allowUnclean: Bool = false) throws -> HFSVolume {
        let location = try XCTUnwrap(DiskImageLayout.volumes(in: url).first)
        return try HFSVolume(device: try BlockDevice(url: url, offset: location.offset, length: location.length, writable: true), allowUncleanVolume: allowUnclean)
    }

    private func openHFSPlus(_ url: URL, allowUnclean: Bool = false) throws -> HFSPlusVolume {
        let location = try XCTUnwrap(DiskImageLayout.volumes(in: url).first)
        return try HFSPlusVolume(device: try BlockDevice(url: url, offset: location.offset, length: location.length, writable: true), allowUncleanVolume: allowUnclean)
    }

    private func mdb(_ url: URL) throws -> MasterDirectoryBlock {
        try MasterDirectoryBlock(sector: try BlockDevice(url: url, writable: false).read(at: 1024, count: 512))
    }

    private func patch(_ url: URL, at offset: UInt64, _ change: (inout [UInt8]) -> Void, count: Int) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        var bytes = [UInt8](handle.readData(ofLength: count))
        change(&bytes)
        try handle.seek(toOffset: offset)
        handle.write(Data(bytes))
    }

    // MARK: Finding 1 — a bitmap that under-reports allocation

    /// After an unclean shutdown the bitmap can miss blocks a file uses. New data must never
    /// be put there, and the volume stays marked for Mac OS to check.
    func testBlocksAFileUsesAreNeverReusedEvenIfTheBitmapSaysFree() async throws {
        let url = try Fixtures.makeClassicHFSImage(in: work)
        let original = (0..<50_000).map { UInt8(truncatingIfNeeded: $0 &* 7) }
        let extents: [ExtentDescriptor]
        do {
            let volume = try openHFS(url)
            let id = try await volume.createFile(named: "precious", in: HFSCatalogID.rootFolder, type: [], creator: [], dataFork: HFSForkSource(bytes: original), resourceFork: .empty)
            try await volume.flush()
            extents = try await volume.extents(of: id, fork: .data)
            await volume.close()
        }
        let bitmapStart = UInt64(try mdb(url).bitmapStartSector) * 512
        try patch(url, at: bitmapStart, { bitmap in
            for extent in extents {
                for block in Int(extent.startBlock)..<(Int(extent.startBlock) + Int(extent.blockCount)) { bitmap[block / 8] &= ~(0x80 >> UInt8(block % 8)) }
            }
        }, count: 512)

        let volume = try openHFS(url)
        let free = Int(await volume.freeBytes)
        try await volume.createFile(named: "new", in: HFSCatalogID.rootFolder, type: [], creator: [], dataFork: HFSForkSource(bytes: [UInt8](repeating: 0xEE, count: free)), resourceFork: .empty)
        try await volume.flush()
        let precious = try await childItem(volume, "precious", in: HFSCatalogID.rootFolder)
        let after = try await volume.readForkBytes(precious.id, fork: .data)
        XCTAssertEqual(after, original, "a file whose blocks the bitmap missed was overwritten")
        await volume.close()
        XCTAssertEqual(try mdb(url).attributes & MasterDirectoryBlock.unmountedCleanlyBit, 0, "a volume found damaged must stay marked for checking")
        XCTAssertTrue(try Fixtures.fsck(url).clean, "the corrected bitmap should be what was written")
    }

    /// The HFS Plus volume header lives in allocation block 0; a bitmap that calls it free
    /// must not get it overwritten.
    func testTheHFSPlusVolumeHeaderIsNeverAllocated() async throws {
        let url = try HFSPlusFixtures.makeVolume(in: work, sizeMB: 12)
        let header = try BlockDevice(url: url, writable: false).read(at: 1024, count: 512)
        let blockSize = Int(try header.u32(40))
        let allocationStart = UInt64(try header.u32(112 + 16)) * UInt64(blockSize)
        try patch(url, at: 1024, { $0.put32(0, at: 52) }, count: 512) // nextAllocation = 0
        try patch(url, at: allocationStart, { $0[0] &= 0x7F }, count: 1)

        let volume = try openHFSPlus(url)
        try await volume.createFile(named: "x", in: HFSCatalogID.rootFolder, type: [], creator: [], dataFork: HFSForkSource(bytes: [UInt8](repeating: 0xEE, count: blockSize)), resourceFork: .empty)
        try await volume.flush()
        await volume.close()
        let signature = try BlockDevice(url: url, writable: false).read(at: 1024, count: 2)
        XCTAssertEqual(signature, Array("H+".utf8))
        XCTAssertTrue(try Fixtures.fsck(url).clean)
    }

    // MARK: Finding 2 — fragmentation must not force in-place saves

    func testAFloppyTheAppFragmentedStillSavesByCopy() async throws {
        let url = try Fixtures.makeClassicHFSImage(in: work)
        let volume = try openHFS(url)
        var ids: [UInt32] = []
        while true {
            do {
                ids.append(try await volume.createFile(named: "f\(ids.count)", in: HFSCatalogID.rootFolder, type: [], creator: [],
                                                       dataFork: HFSForkSource(bytes: [UInt8](repeating: 1, count: 512)), resourceFork: .empty))
            } catch HFSError.volumeFull { break }
            if ids.count % 100 == 0 { try await volume.flush() }
        }
        try await volume.flush()
        for (index, id) in ids.enumerated() where index % 2 == 0 { try await volume.delete(id) }
        try await volume.flush()

        let free = Int(await volume.freeBytes)
        XCTAssertGreaterThan(free, 100_000)
        let payload = [UInt8](repeating: 7, count: free)
        let big = try await volume.createFile(named: "big", in: HFSCatalogID.rootFolder, type: [], creator: [], dataFork: HFSForkSource(bytes: payload), resourceFork: .empty)
        let before = try mdb(url)
        try await volume.flush()
        let after = try mdb(url)
        XCTAssertNotEqual(after.extentsFileExtents.extents.first?.startBlock, before.extentsFileExtents.extents.first?.startBlock, "the extents tree was rewritten in place")
        XCTAssertNotEqual(after.catalogFileExtents.extents.first?.startBlock, before.catalogFileExtents.extents.first?.startBlock, "the catalog was rewritten in place")
        let read = try await volume.readForkBytes(big, fork: .data)
        XCTAssertEqual(read, payload)
        await volume.close()
        XCTAssertTrue(try Fixtures.fsck(url).clean)
    }

    // MARK: Finding 3 — dates across daylight-saving changes

    func testDatesRoundTripAcrossDaylightSavingChanges() throws {
        let saved = NSTimeZone.default
        defer { NSTimeZone.default = saved }
        for zone in ["Europe/Berlin", "America/New_York", "Australia/Sydney"] {
            NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: zone))
            for date in [Date(timeIntervalSince1970: 1_736_000_000), Date(timeIntervalSince1970: 1_752_000_000)] {
                let encoded = HFSDate.encode(date)
                XCTAssertEqual(HFSDate.encode(HFSDate.date(encoded)), encoded, "\(zone) \(date)")
                XCTAssertEqual(HFSDate.date(encoded).timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 1, "\(zone) \(date)")
            }
        }
    }

    // MARK: Finding 5 — space freed on a full disk becomes usable

    func testDeletingOnADiskAnotherSystemFilledFreesUsableSpace() async throws {
        let url = try Fixtures.makeClassicHFSImage(in: work)
        try Fixtures.withMounted(url) {
            var index = 0
            while (try? Fixtures.putFile(Data(repeating: UInt8(index & 0xFF), count: 30_000), at: ":h\(index)", scratch: work)) != nil { index += 1 }
            var small = 0
            while small < 200, (try? Fixtures.putFile(Data(repeating: 1, count: 512), at: ":s\(small)", scratch: work)) != nil { small += 1 }
        }
        // hfsutils itself leaves a few complaints on a disk it fills; the engine must add none.
        let baseline = Set(try Fixtures.fsckProblems(url))
        let volume = try openHFS(url)
        // The first deletion only refills the room a safe save needs (the full disk had none);
        // what is freed beyond it is usable.
        try await volume.delete(try await childItem(volume, "h0", in: HFSCatalogID.rootFolder).id)
        try await volume.delete(try await childItem(volume, "h1", in: HFSCatalogID.rootFolder).id)
        try await volume.flush()
        let free = await volume.freeBytes
        XCTAssertGreaterThanOrEqual(free, 10_000)
        try await volume.createFile(named: "after", in: HFSCatalogID.rootFolder, type: [], creator: [], dataFork: HFSForkSource(bytes: [UInt8](repeating: 3, count: 10_000)), resourceFork: .empty)
        try await volume.flush()
        await volume.close()
        let problems = Set(try Fixtures.fsckProblems(url)).subtracting(baseline)
        XCTAssertTrue(problems.isEmpty, "\(problems)")
    }

    // MARK: Finding 6 — copies stream

    func testCopyingAFileOnTheVolumeKeepsBothForks() async throws {
        for plus in [false, true] {
            let url = plus ? try HFSPlusFixtures.makeVolume(in: work, name: "copy.img") : try Fixtures.makeClassicHFSImage(in: work, name: "copy.dsk", sizeKB: 8 * 1024)
            let volume: any DiskVolume = plus ? try openHFSPlus(url) : try openHFS(url)
            let data = (0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 5) }
            let resource = (0..<70_000).map { UInt8(truncatingIfNeeded: $0 &* 13) }
            let id = try await volume.createFile(named: "source", in: HFSCatalogID.rootFolder, metadata: NewFileMetadata(fileType: Array("TEXT".utf8), creator: Array("ttxt".utf8)),
                                                 dataFork: HFSForkSource(bytes: data), resourceFork: HFSForkSource(bytes: resource))
            let copy = try await volume.copyFile(id, to: HFSCatalogID.rootFolder, name: "copy")
            try await volume.flush()
            let copiedData = try await volume.readForkBytes(copy, fork: .data)
            let copiedResource = try await volume.readForkBytes(copy, fork: .resource)
            XCTAssertEqual(copiedData, data, plus ? "HFS+" : "HFS")
            XCTAssertEqual(copiedResource, resource, plus ? "HFS+" : "HFS")
            await volume.close()
            XCTAssertTrue(try Fixtures.fsck(url).clean)
        }
    }

    // MARK: Opened unclean stays unclean

    /// "Open for Writing Anyway" must not vouch for a volume nobody has checked: saving keeps
    /// it marked, so Mac OS checks it the next time it mounts it.
    func testSavingAVolumeOpenedUncleanLeavesItMarkedForChecking() async throws {
        let url = try Fixtures.makeClassicHFSImage(in: work)
        try patch(url, at: 1024 + 10, { $0[0] &= ~UInt8(MasterDirectoryBlock.unmountedCleanlyBit >> 8) }, count: 1)
        XCTAssertEqual(try mdb(url).attributes & MasterDirectoryBlock.unmountedCleanlyBit, 0)
        let volume = try openHFS(url, allowUnclean: true)
        try await volume.createFolder(named: "Added", in: HFSCatalogID.rootFolder)
        try await volume.flush()
        await volume.close()
        XCTAssertEqual(try mdb(url).attributes & MasterDirectoryBlock.unmountedCleanlyBit, 0)
    }
}
