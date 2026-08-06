#if canImport(XCTest)
import XCTest
@testable import FloppyFox

@MainActor
final class FloppyFoxTests: XCTestCase {
    func testExample() throws {
        XCTAssertTrue(true)
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
#else
// XCTest is unavailable in this Swift toolchain, so this test target is disabled.
#endif
