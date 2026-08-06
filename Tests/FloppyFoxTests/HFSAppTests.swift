#if canImport(XCTest)
import AppKit
import XCTest
@testable import FloppyFox

@MainActor
final class FloppyFoxTests: XCTestCase {
    func testExample() throws {
        XCTAssertTrue(true)
    }

    func testExtractsMonochromeIconFromMacBinaryResourceFork() throws {
        let macBinary = makeMacBinaryWithICNResource()
        let png = try XCTUnwrap(ClassicMacResourceIcon.iconPNG(fromMacBinary: macBinary))
        let image = try XCTUnwrap(NSImage(data: png))

        XCTAssertEqual(image.size.width, 32)
        XCTAssertEqual(image.size.height, 32)
    }

    func testRejectsTruncatedMacBinaryIconData() {
        XCTAssertNil(ClassicMacResourceIcon.iconPNG(fromMacBinary: Data(repeating: 0, count: 127)))
    }

    func testExpandsDynamicVHDToRawSectors() async throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("floppyfox-test-\(UUID().uuidString).vhd")
        try makeDynamicVHD().write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let prepared = try await VHDImage.prepareForReading(source)
        defer { try? FileManager.default.removeItem(at: prepared.imageURL) }
        XCTAssertNotEqual(prepared.imageURL, source)
        let raw = try Data(contentsOf: prepared.imageURL)
        XCTAssertEqual(raw.count, 512)
        XCTAssertEqual(raw, Data(repeating: 0xa5, count: 512))
    }

    func testUsesFixedVHDWithoutConversion() async throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("floppyfox-fixed-test-\(UUID().uuidString).vhd")
        var fixed = Data(repeating: 0, count: 1024)
        fixed.replaceSubrange(512..<520, with: "conectix".utf8)
        fixed.writeUInt32BE(2, at: 512 + 60)
        try fixed.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let prepared = try await VHDImage.prepareForReading(source)
        XCTAssertEqual(prepared.imageURL, source)
    }

    func testTreatsNonContainerVHDAsRawImage() async throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("floppyfox-raw-test-\(UUID().uuidString).vhd")
        try Data(repeating: 0, count: 1024).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let prepared = try await VHDImage.prepareForReading(source)
        XCTAssertEqual(prepared.imageURL, source)
    }

    func testPrefersWholeDiskFromHdiutilEntities() {
        let devices = ["/dev/disk4s1", "/dev/disk4s2", "/dev/disk4s3", "/dev/disk4"]
        XCTAssertEqual(DiskImageManager.preferredWholeDiskDevice(from: devices), "/dev/disk4")
    }

    func testParsesFinderAttributesFromHLSLongListing() throws {
        let attributes = try XCTUnwrap(DiskImageManager.finderAttributes(
            fromHLSLongListing: "Fi TEXT/ttxt       332       987 Jun 19  2021 :ReadMe"
        ))
        XCTAssertEqual(attributes.type, "TEXT")
        XCTAssertEqual(attributes.creator, "ttxt")
        XCTAssertEqual(attributes.dataForkSize, 332)
        XCTAssertEqual(attributes.resourceForkSize, 987)
        XCTAssertTrue(attributes.isInvisible)
        XCTAssertTrue(attributes.isLocked)
    }

    func testDecodesClassicMacRomanDirectoryOutput() {
        let output = Data([0x41, 0x66, 0x74, 0x65, 0x72, 0x20, 0x44, 0x61, 0x72, 0x6b, 0xa8])
        XCTAssertEqual(DiskImageManager.decodeProcessOutput(output), "After Dark®")
    }

    func testMakesImportedNamesSafeForClassicHFS() {
        XCTAssertEqual(DiskImageManager.classicHFSName(from: "After Dark®"), "After Dark®")
        XCTAssertEqual(DiskImageManager.classicHFSName(from: "Résumé: ２０２６"), "Résumé- 2026")
        XCTAssertEqual(DiskImageManager.classicHFSName(from: "Notes😀.txt"), "Notes~1F600.txt")

        let shortened = DiskImageManager.classicHFSName(from: String(repeating: "é", count: 40))
        XCTAssertEqual(shortened.data(using: .macOSRoman)?.count, 31)
    }

    func testMapsClassicSlashToSafeHostFilename() {
        XCTAssertEqual(
            DiskImageManager.hostName(fromClassicHFSName: "MacDRUMS Instruments/Tracks"),
            "MacDRUMS Instruments:Tracks"
        )
    }

    func testEscapesHFSGlobCharactersInLiteralPaths() {
        XCTAssertEqual(
            DiskImageManager.escapedHFSGlobPath(":Other Plug-ins:*Stars*?[Draft]\\File"),
            #":Other Plug-ins:\*Stars\*\?\[Draft]\\File"#
        )
    }

    func testDecodesEscapedHFSListingNames() {
        XCTAssertEqual(DiskImageManager.decodeHLSQuotedName(#""After\ Dark®""#), "After Dark®")
        XCTAssertEqual(DiskImageManager.decodeHLSQuotedName(#""Icon\r""#), "Icon\r")
        XCTAssertEqual(DiskImageManager.decodeHLSQuotedName(#""A\\B\"C""#), #"A\B"C"#)
        XCTAssertEqual(DiskImageManager.decodeHLSQuotedName(#""Caf\216""#), "Café")
        XCTAssertNil(DiskImageManager.decodeHLSQuotedName("not quoted"))
    }

    func testOpensOptionalVHDIntegrationFixture() async throws {
        guard let path = ProcessInfo.processInfo.environment["FLOPPYFOX_VHD_FIXTURE"] else {
            throw XCTSkip("Set FLOPPYFOX_VHD_FIXTURE to run the VHD integration test")
        }
        let manager = DiskImageManager()
        await manager.attachImage(imageURL: URL(fileURLWithPath: path))
        let error = manager.errorMessage
        let entryCount = manager.entries.count
        await manager.ejectImage()

        XCTAssertNil(error)
        XCTAssertGreaterThan(entryCount, 0)
    }

    func testCopiesOptionalHFSFolderToMacOSPasteboard() async throws {
        guard let path = ProcessInfo.processInfo.environment["FLOPPYFOX_VHD_FIXTURE"] else {
            throw XCTSkip("Set FLOPPYFOX_VHD_FIXTURE to run the VHD clipboard integration test")
        }
        let manager = DiskImageManager()
        await manager.attachImage(imageURL: URL(fileURLWithPath: path))
        defer { Task { await manager.ejectImage() } }

        let folder = try XCTUnwrap(manager.entries.first(where: { $0.isDirectory && $0.name == "System Picker" }))
        manager.copyEntry(folder)

        let deadline = Date().addingTimeInterval(15)
        var copiedURL: URL?
        repeat {
            copiedURL = (NSPasteboard.general.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL])?.first
            if copiedURL != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline

        let url = try XCTUnwrap(copiedURL)
        XCTAssertTrue((try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: url.path).isEmpty)
    }

    func testOpenRealMultiPartitionHDAImage() async throws {
        let url = URL(fileURLWithPath: "/Users/amuskens/Downloads/ PreInstalled MacOS Images/HD0-OpenRetroSCSI-7.1.hda")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "fixture not found at \(url.path)")

        let manager = DiskImageManager()
        await manager.attachImage(imageURL: url)

        print("isMounted=\(manager.isMounted) usingHFSUtils=\(manager.usingHFSUtils) errorMessage=\(manager.errorMessage ?? "nil") statusMessage=\(manager.statusMessage)")
        print("entries=\(manager.entries.map { $0.name })")

        XCTAssertNil(manager.errorMessage)
        XCTAssertFalse(manager.entries.isEmpty, "expected non-empty entries after opening a real multi-partition HDA image")

        await manager.ejectImage()
    }
}

private func makeMacBinaryWithICNResource() -> Data {
    let dataOffset = 256
    let iconLength = 256
    let mapOffset = dataOffset + 4 + iconLength
    let typeListOffset = 28
    let mapLength = 50
    var resourceFork = Data(repeating: 0, count: mapOffset + mapLength)

    resourceFork.writeUInt32BE(UInt32(dataOffset), at: 0)
    resourceFork.writeUInt32BE(UInt32(mapOffset), at: 4)
    resourceFork.writeUInt32BE(UInt32(4 + iconLength), at: 8)
    resourceFork.writeUInt32BE(UInt32(mapLength), at: 12)
    resourceFork.writeUInt32BE(UInt32(iconLength), at: dataOffset)
    // Solid black image plane and fully opaque mask plane.
    resourceFork.replaceSubrange((dataOffset + 4)..<(dataOffset + 4 + 128), with: repeatElement(UInt8(0xff), count: 128))
    resourceFork.replaceSubrange((dataOffset + 4 + 128)..<(dataOffset + 4 + 256), with: repeatElement(UInt8(0xff), count: 128))

    resourceFork.writeUInt16BE(UInt16(typeListOffset), at: mapOffset + 24)
    let typeList = mapOffset + typeListOffset
    resourceFork.writeUInt16BE(0, at: typeList) // one resource type
    resourceFork.replaceSubrange((typeList + 2)..<(typeList + 6), with: "ICN#".utf8)
    resourceFork.writeUInt16BE(0, at: typeList + 6) // one resource
    resourceFork.writeUInt16BE(10, at: typeList + 8)
    let reference = typeList + 10
    resourceFork.writeUInt16BE(UInt16(bitPattern: -16455), at: reference)
    resourceFork.writeUInt16BE(0xffff, at: reference + 2)
    resourceFork.writeUInt32BE(0, at: reference + 4)

    var macBinary = Data(repeating: 0, count: 128)
    macBinary[1] = 4
    macBinary.replaceSubrange(2..<6, with: "Test".utf8)
    macBinary.writeUInt32BE(UInt32(resourceFork.count), at: 87)
    macBinary.append(resourceFork)
    return macBinary
}

private func makeDynamicVHD() -> Data {
    let headerOffset = 512
    let tableOffset = 1536
    let storedBlockOffset = 2048
    let trailingFooterOffset = 3072
    var vhd = Data(repeating: 0, count: trailingFooterOffset + 512)

    func writeFooter(at offset: Int) {
        vhd.replaceSubrange(offset..<(offset + 8), with: "conectix".utf8)
        vhd.writeUInt64BE(UInt64(headerOffset), at: offset + 16)
        vhd.writeUInt64BE(512, at: offset + 48)
        vhd.writeUInt32BE(3, at: offset + 60)
    }
    writeFooter(at: 0)
    writeFooter(at: trailingFooterOffset)

    vhd.replaceSubrange(headerOffset..<(headerOffset + 8), with: "cxsparse".utf8)
    vhd.writeUInt64BE(UInt64(tableOffset), at: headerOffset + 16)
    vhd.writeUInt32BE(1, at: headerOffset + 28)
    vhd.writeUInt32BE(512, at: headerOffset + 32)
    vhd.writeUInt32BE(UInt32(storedBlockOffset / 512), at: tableOffset)
    vhd[storedBlockOffset] = 0x80 // first (and only) virtual sector is present
    vhd.replaceSubrange((storedBlockOffset + 512)..<(storedBlockOffset + 1024), with: repeatElement(UInt8(0xa5), count: 512))
    return vhd
}

private extension Data {
    mutating func writeUInt16BE(_ value: UInt16, at offset: Int) {
        self[offset] = UInt8((value >> 8) & 0xff)
        self[offset + 1] = UInt8(value & 0xff)
    }

    mutating func writeUInt32BE(_ value: UInt32, at offset: Int) {
        self[offset] = UInt8((value >> 24) & 0xff)
        self[offset + 1] = UInt8((value >> 16) & 0xff)
        self[offset + 2] = UInt8((value >> 8) & 0xff)
        self[offset + 3] = UInt8(value & 0xff)
    }


    mutating func writeUInt64BE(_ value: UInt64, at offset: Int) {
        for byte in 0..<8 {
            self[offset + byte] = UInt8((value >> UInt64((7 - byte) * 8)) & 0xff)
        }
    }
}
#else
// XCTest is unavailable in this Swift toolchain, so this test target is disabled.
#endif
