import XCTest
@testable import FloppyFox

/// Container formats around a volume, found on real period disk collections.
final class ImageFormatTests: XCTestCase {
    private var work: URL!

    override func setUp() async throws {
        guard Fixtures.hfsutilsPrefix != nil else { throw XCTSkip("hfsutils (brew install hfsutils) is required for classic HFS fixtures") }
        work = try Fixtures.makeWorkDirectory("formats")
    }

    override func tearDown() async throws {
        if let work { try? FileManager.default.removeItem(at: work) }
    }

    /// A DiskCopy 4.2 image: an 84-byte header (name, data size, checksums) then the disk.
    private func diskCopyImage(dropping cut: Int = 0) throws -> (url: URL, payload: [UInt8]) {
        let floppy = try Fixtures.makeClassicHFSImage(in: work, name: "inner.dsk", sizeKB: 800, label: "Copied")
        try Fixtures.withMounted(floppy) { try Fixtures.putFile(Data("inside".utf8), at: ":Note", scratch: work) }
        let payload = Array(try Data(contentsOf: floppy))
        var header = [UInt8](repeating: 0, count: 84)
        header[0] = 6
        header.put(Array("Copied".utf8), at: 1)
        header.put32(UInt32(payload.count), at: 64)
        header[80] = 0x01; header[81] = 0x22 // 800K Mac format
        header[82] = 0x01; header[83] = 0x00 // magic
        let url = work.appendingPathComponent("copied-\(cut).image")
        try Data((header + payload).dropLast(cut)).write(to: url)
        return (url, payload)
    }

    func testDiskCopyImagesOpenReadOnly() async throws {
        let (url, _) = try diskCopyImage()
        let location = try XCTUnwrap(DiskImageLayout.volumes(in: url).first)
        XCTAssertEqual(location.offset, 84)
        XCTAssertNotNil(location.readOnlyReason, "writing would invalidate Disk Copy's checksum")
        let volume = try DiskImageLayout.openVolume(url, readOnly: false)
        XCTAssertTrue(volume.isReadOnly)
        let note = try await childItem(volume, "Note", in: HFSCatalogID.rootFolder)
        let data = try await volume.readForkBytes(note.id, fork: .data)
        XCTAssertEqual(data, Array("inside".utf8))
        await volume.close()
    }

    /// Seen in a real collection: an 800K DiskCopy image saved at exactly 800K, so the last
    /// 84 bytes — the spare MDB area — are missing. Everything else is there.
    func testADiskCopyImageCutShortByItsHeaderSizeStillOpens() async throws {
        let (url, _) = try diskCopyImage(dropping: 84)
        let volume = try DiskImageLayout.openVolume(url, readOnly: false)
        XCTAssertTrue(volume.isReadOnly)
        let note = try await childItem(volume, "Note", in: HFSCatalogID.rootFolder)
        let data = try await volume.readForkBytes(note.id, fork: .data)
        XCTAssertEqual(data, Array("inside".utf8))
        await volume.close()

        // Cut into the allocation blocks, it's refused rather than read wrong.
        let (worse, _) = try diskCopyImage(dropping: 64 * 1024)
        XCTAssertThrowsError(try DiskImageLayout.openVolume(worse, readOnly: true))
    }

    /// The 400K floppies of 1984–86 use MFS; they get a clear explanation, not "not HFS".
    func testMFSDisksAreReportedAsUnsupportedNotUnrecognized() throws {
        var image = [UInt8](repeating: 0, count: 400 * 1024)
        image.put16(0xD2D7, at: 1024)
        let url = work.appendingPathComponent("mfs.dsk")
        try Data(image).write(to: url)
        XCTAssertThrowsError(try DiskImageLayout.volumes(in: url)) { error in
            guard case HFSError.unsupported(let what) = error else { return XCTFail("got \(error)") }
            XCTAssertTrue(what.contains("MFS"), what)
        }
    }

    /// Real period disks (a Windwalker floppy among them) have a catalog header whose leaf
    /// count is off by one. Mac OS doesn't care; FloppyFox opens them read-only, so their
    /// files can still be copied off.
    func testADiskWithAWrongCatalogRecordCountOpensReadOnly() async throws {
        let url = try Fixtures.makeClassicHFSImage(in: work)
        try Fixtures.withMounted(url) { try Fixtures.putFile(Data("kept".utf8), at: ":Kept", scratch: work) }
        var bytes = Array(try Data(contentsOf: url))
        let mdb = try MasterDirectoryBlock(sector: Array(bytes[1024..<1536]))
        let catalogStart = Int(mdb.firstAllocationSector) * 512 + Int(mdb.catalogFileExtents.extents[0].startBlock) * Int(mdb.allocationBlockSize)
        let leafRecords = catalogStart + 14 + 6 // header node, BTHdrRec.leafRecords
        bytes.put32(try bytes.u32(leafRecords) + 1, at: leafRecords)
        try Data(bytes).write(to: url)

        let volume = try DiskImageLayout.openVolume(url, readOnly: false)
        XCTAssertEqual(volume.readOnlyCause, .damaged)
        let kept = try await childItem(volume, "Kept", in: HFSCatalogID.rootFolder)
        let data = try await volume.readForkBytes(kept.id, fork: .data)
        XCTAssertEqual(data, Array("kept".utf8))
        await volume.close()
    }
}
