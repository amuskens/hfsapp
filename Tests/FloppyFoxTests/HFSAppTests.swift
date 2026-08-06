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
}
#else
// XCTest is unavailable in this Swift toolchain, so this test target is disabled.
#endif
