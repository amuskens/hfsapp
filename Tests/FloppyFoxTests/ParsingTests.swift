import XCTest
@testable import FloppyFox

/// Pure, fast unit tests for the string/URL handling between the app and hfsutils. These run
/// everywhere (no hfsutils, no hdiutil) and pin down exact behavior for the awkward names real
/// classic Mac disks contain.
final class ParsingTests: XCTestCase {
    // MARK: hls output

    func testDecodesEscapedHLSNames() {
        XCTAssertEqual(DiskImageManager.decodeHLSQuotedName(#""Icon\r""#), "Icon\r")
        XCTAssertEqual(DiskImageManager.decodeHLSQuotedName(#""A\\B\"C""#), #"A\B"C"#)
        XCTAssertEqual(DiskImageManager.decodeHLSQuotedName(#""Caf\216""#), "Café")
        XCTAssertEqual(DiskImageManager.decodeHLSQuotedName(#""Dir\ With\ Space""#), "Dir With Space")
        XCTAssertNil(DiskImageManager.decodeHLSQuotedName("not quoted"))
        XCTAssertNil(DiskImageManager.decodeHLSQuotedName(#"""#))
    }

    /// Captured verbatim from hfsutils 3.2.6: `hls -a1Q` wraps a long *escaped* name onto
    /// several physical lines, each fragment ending in a `\` marker — even in `-1` mode and
    /// regardless of `-w`. Splitting on newlines alone made such files vanish from the browser.
    func testJoinsHLSLinesWrappedForLongEscapedNames() {
        let output = #"""
        "A"
        "\252\252\252\252\252\252\252\252\252\252\252\252\252\252\2\
        52\252\252\252\252\252\252\252\252\252\252\252\252\252\252\\
        252"
        "We\"ird\ &\ Name"

        """#
        XCTAssertEqual(
            DiskImageManager.parseHLSQuotedListing(output),
            ["A", String(repeating: "™", count: 30), #"We"ird & Name"#]
        )
    }

    func testParsesFinderAttributesIncludingSpacesAndQuotesInCodes() throws {
        let plain = try XCTUnwrap(DiskImageManager.finderAttributes(fromHLSLongListing: "f  APPL/ttxt      1234      5678 Oct 12 14:57 SimpleText"))
        XCTAssertEqual(plain.type, "APPL")
        XCTAssertEqual(plain.creator, "ttxt")
        XCTAssertEqual(plain.dataForkSize, 5678)
        XCTAssertEqual(plain.resourceForkSize, 1234)
        XCTAssertFalse(plain.isInvisible)
        XCTAssertFalse(plain.isLocked)

        // Real hls output for type `A "b` / creator ` x y`, invisible and locked.
        let odd = try XCTUnwrap(DiskImageManager.finderAttributes(fromHLSLongListing: #"Fi A "b/ x y         0         9 Oct 12 15:00 We"ird"#))
        XCTAssertEqual(odd.type, #"A "b"#)
        XCTAssertEqual(odd.creator, " x y")
        XCTAssertTrue(odd.isInvisible)
        XCTAssertTrue(odd.isLocked)

        XCTAssertNil(DiskImageManager.finderAttributes(fromHLSLongListing: "d          1 item                Oct 12 14:57 A"))
    }

    func testDecodesClassicMacRomanProcessOutput() {
        XCTAssertEqual(DiskImageManager.decodeProcessOutput(Data([0x43, 0x61, 0x66, 0x8E])), "Café")
        XCTAssertEqual(DiskImageManager.decodeProcessOutput(Data("Café".utf8)), "Café")
    }

    /// `lsof -t` prints bare PIDs; our own process must never count as "another program".
    func testParsesLsofPIDsExcludingOwnProcess() {
        XCTAssertEqual(DiskImageManager.parseLsofPIDs("123\n456\n", excluding: 456), [123])
        XCTAssertEqual(DiskImageManager.parseLsofPIDs("", excluding: 1), [])
        XCTAssertEqual(DiskImageManager.parseLsofPIDs("lsof: WARNING: can't stat() smbfs file system\n", excluding: 1), [])
    }

    // MARK: hfs:// pseudo-URLs

    /// Every name here broke the old string-concatenated pseudo-URL: `&` split the query
    /// (so "Tom & Jerry" resolved to a *different* file, ":Tom"), and a space in the image path
    /// made `URL(string:)` return nil on macOS 13, crashing the force-unwrap in `hfsList`.
    func testHFSPseudoURLsRoundTripReservedCharacters() throws {
        let imagePaths = ["/Users/x/My Disks/HD 1.hda", "/tmp/50% #1?.dsk", "/tmp/plain.img"]
        let hfsPaths = [":Tom & Jerry", ":A=B", ":50% off", ":C++ Notes", ":Read#Me?", ":Folder:Sub:Café™", ":a+b=c&d=e"]
        for imagePath in imagePaths {
            for hfsPath in hfsPaths {
                let url = try XCTUnwrap(DiskImageManager.makeHFSPseudoURL(imagePath: imagePath, hfsPath: hfsPath))
                let parsed = try XCTUnwrap(DiskImageManager.parseHFSPseudoURL(url), "could not parse \(url)")
                XCTAssertEqual(parsed.hfsPath, hfsPath, "\(url)")
                XCTAssertEqual(parsed.imagePath, imagePath, "\(url)")
            }
        }
        XCTAssertNil(DiskImageManager.parseHFSPseudoURL(URL(fileURLWithPath: "/tmp/x")))
    }

    // MARK: Name conversion

    func testMakesImportedNamesSafeForClassicHFS() {
        XCTAssertEqual(DiskImageManager.classicHFSName(from: "a:b"), "a-b")
        XCTAssertEqual(DiskImageManager.classicHFSName(from: ""), "Untitled")
        XCTAssertEqual(DiskImageManager.classicHFSName(from: "Café"), "Café")
        let long = DiskImageManager.classicHFSName(from: String(repeating: "x", count: 40))
        XCTAssertEqual(long.count, 31)
        // Multi-byte host characters must still fit the 31 *Mac Roman byte* limit.
        let emoji = DiskImageManager.classicHFSName(from: String(repeating: "😀", count: 10))
        XCTAssertLessThanOrEqual(emoji.data(using: .macOSRoman)!.count, 31)
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

    func testEscapesHFSGlobCharactersInLiteralPaths() {
        XCTAssertEqual(DiskImageManager.escapedHFSGlobPath(":*Stars*"), #":\*Stars\*"#)
        XCTAssertEqual(DiskImageManager.escapedHFSGlobPath(":a?[b]\\"), #":a\?\[b]\\"#)
        XCTAssertEqual(DiskImageManager.escapedHFSGlobPath(":plain name"), ":plain name")
    }

    func testPrefersWholeDiskFromHdiutilEntities() {
        XCTAssertEqual(DiskImageManager.preferredWholeDiskDevice(from: ["/dev/disk4s1", "/dev/disk4s2", "/dev/disk4"]), "/dev/disk4")
        XCTAssertEqual(DiskImageManager.preferredWholeDiskDevice(from: ["/dev/disk4s1"]), "/dev/disk4s1")
        XCTAssertNil(DiskImageManager.preferredWholeDiskDevice(from: []))
    }
}
