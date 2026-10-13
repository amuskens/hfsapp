import XCTest
@testable import FloppyFox

/// Fast unit tests for name handling and small parsers. They need nothing installed.
final class ParsingTests: XCTestCase {
    func testMakesImportedNamesSafeForClassicHFS() throws {
        XCTAssertEqual(DiskImageManager.classicHFSName(from: "a:b"), "a-b")
        XCTAssertEqual(DiskImageManager.classicHFSName(from: ""), "Untitled")
        XCTAssertEqual(DiskImageManager.classicHFSName(from: "."), "Untitled")
        XCTAssertEqual(DiskImageManager.classicHFSName(from: ".."), "Untitled")
        XCTAssertEqual(DiskImageManager.classicHFSName(from: "Café"), "Café")
        XCTAssertEqual(DiskImageManager.classicHFSName(from: String(repeating: "x", count: 40)).count, 31)
        // Multi-byte host characters must still fit the 31 *Mac Roman byte* limit, and every
        // result must be a name the engine accepts.
        for host in [String(repeating: "😀", count: 10), "日本語のファイル名", "naïve résumé.txt", "tab\there"] {
            let name = DiskImageManager.classicHFSName(from: host)
            XCTAssertLessThanOrEqual(name.data(using: .macOSRoman)!.count, 31)
            XCTAssertNoThrow(try HFSName(name), host)
        }
    }

    /// A crafted (or merely odd) disk can contain items named `.` or `..`; classic Mac OS
    /// treats those as ordinary names. Exported verbatim, `..` escapes the chosen folder.
    func testHostNamesNeverEscapeTheDestinationFolder() {
        XCTAssertEqual(DiskImageManager.hostName(fromClassicHFSName: "A/B"), "A:B")
        for hostile in [".", "..", ""] {
            let name = DiskImageManager.hostName(fromClassicHFSName: hostile)
            XCTAssertFalse(["", ".", ".."].contains(name), "\(hostile.debugDescription) mapped to \(name.debugDescription)")
            let base = URL(fileURLWithPath: "/tmp/export", isDirectory: true)
            XCTAssertEqual(base.appendingPathComponent(name).standardizedFileURL.deletingLastPathComponent().path, base.path)
        }
    }

    func testClassicNameComparisonIsCaseInsensitiveAndDiacriticSensitive() throws {
        func order(_ a: String, _ b: String) throws -> Int {
            HFSName.compare(try HFSName(a).bytes, try HFSName(b).bytes)
        }
        XCTAssertEqual(try order("ReadMe", "README"), 0)
        XCTAssertNotEqual(try order("cafe", "café"), 0)
        XCTAssertLessThan(try order("cafe", "café"), 0, "an accented letter sorts after its base letter")
        XCTAssertLessThan(try order("café", "cafg"), 0)
        XCTAssertLessThan(try order("A", "AB"), 0, "a prefix sorts first")
        XCTAssertGreaterThan(try order("Zebra", "apple"), 0, "case doesn't affect order")
    }

    /// `lsof -t` prints bare PIDs; our own process must never count as "another program".
    func testParsesLsofPIDsExcludingOwnProcess() {
        XCTAssertEqual(DiskImageManager.parseLsofPIDs("123\n456\n", excluding: 456), [123])
        XCTAssertEqual(DiskImageManager.parseLsofPIDs("", excluding: 1), [])
        XCTAssertEqual(DiskImageManager.parseLsofPIDs("lsof: WARNING: can't stat() smbfs file system\n", excluding: 1), [])
    }

    func testDecodesClassicMacRomanProcessOutput() {
        XCTAssertEqual(DiskImageManager.decodeProcessOutput(Data([0x43, 0x61, 0x66, 0x8E])), "Café")
        XCTAssertEqual(DiskImageManager.decodeProcessOutput(Data("Café".utf8)), "Café")
    }

    func testGuessesClassicTypeAndCreatorFromExtensionOrFinderInfo() {
        let text = DiskImageManager.typeAndCreator(for: URL(fileURLWithPath: "/x/notes.txt"), finderInfo: nil)
        XCTAssertEqual(text.type, Array("TEXT".utf8))
        XCTAssertEqual(text.creator, Array("ttxt".utf8))
        let unknown = DiskImageManager.typeAndCreator(for: URL(fileURLWithPath: "/x/blob.xyz"), finderInfo: nil)
        XCTAssertEqual(unknown.type, Array("????".utf8))
        let explicit = DiskImageManager.typeAndCreator(for: URL(fileURLWithPath: "/x/notes.txt"), finderInfo: Array("APPLWILD".utf8) + [UInt8](repeating: 0, count: 8))
        XCTAssertEqual(explicit.type, Array("APPL".utf8))
        XCTAssertEqual(explicit.creator, Array("WILD".utf8))
    }
}
