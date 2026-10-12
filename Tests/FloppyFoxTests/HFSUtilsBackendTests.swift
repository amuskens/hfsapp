import AppKit
import XCTest
@testable import FloppyFox

/// Integration tests for the hfsutils backend (classic HFS floppies and hard-disk images), run
/// against fresh `hformat` volumes. Results are checked with hfsutils directly after ejecting,
/// so a test only passes when the change really reached the image file on disk — not merely
/// the app's in-memory listing or a private temporary copy.
@MainActor
final class HFSUtilsBackendTests: XCTestCase {
    private var work: URL!

    override func setUp() async throws {
        guard Fixtures.hfsutilsPrefix != nil else { throw XCTSkip("hfsutils (brew install hfsutils) is not installed") }
        work = try Fixtures.makeWorkDirectory("hfsutils")
    }

    override func tearDown() async throws {
        if let work { try? FileManager.default.removeItem(at: work) }
    }

    private func open(_ image: URL) async throws -> DiskImageManager {
        let manager = DiskImageManager.forTesting()
        await manager.attachImage(imageURL: image)
        addTeardownBlock { await manager.ejectImage() }
        XCTAssertNil(manager.errorMessage)
        XCTAssertTrue(manager.usingHFSUtils, "a partition-less classic HFS image should use the hfsutils backend")
        return manager
    }

    // MARK: Persistence

    func testEditsReachTheImageFileOnDisk() async throws {
        let image = try Fixtures.makeClassicHFSImage(in: work)
        try Fixtures.withMounted(image) {
            try Fixtures.putFile(Data("old".utf8), at: ":Doomed", scratch: work)
        }

        let manager = try await open(image)
        XCTAssertFalse(manager.isReadOnly)
        await manager.createFolder(named: "Kept Folder")
        let host = work.appendingPathComponent("hello.txt")
        try Data("hello".utf8).write(to: host)
        await manager.importFiles(urls: [host], destination: URL(fileURLWithPath: "/"))
        await manager.deleteEntries([try manager.entry(named: "Doomed")])
        XCTAssertNil(manager.errorMessage)
        await manager.ejectImage()

        let names = try Fixtures.withMounted(image) { try Fixtures.names(in: ":") }
        XCTAssertEqual(names, ["Kept Folder", "hello.txt"], "edits were not written to the image file itself")
    }

    /// When the original image is held open by another process the backend switches to a
    /// private temporary copy. Writes to that copy are deleted on eject, so the session must
    /// become read-only rather than reporting "Added …" for changes that will silently vanish.
    func testTemporaryCopyFallbackRefusesWritesInsteadOfLosingThem() async throws {
        let image = try Fixtures.makeClassicHFSImage(in: work)
        let manager = try await open(image)
        try await manager.switchToTemporaryCopy(imagePath: image.path, reason: "test")
        XCTAssertTrue(manager.isReadOnly)

        await manager.createFolder(named: "Lost")
        XCTAssertNotNil(manager.errorMessage, "a write into a throwaway copy must be refused")
        await manager.ejectImage()
        let names = try Fixtures.withMounted(image) { try Fixtures.names(in: ":") }
        XCTAssertFalse(names.contains("Lost"))
    }

    /// Checked against real hls output rather than a hand-written line: a data-only file must
    /// report its bytes as the *data* fork.
    func testInspectorReportsForkSizesAndFinderInfo() async throws {
        let image = try Fixtures.makeClassicHFSImage(in: work)
        try Fixtures.withMounted(image) {
            try Fixtures.putFile(Data(count: 9), at: ":Doc", type: "PICT", creator: "MDRW", scratch: work)
        }
        let manager = try await open(image)
        let doc = try manager.entry(named: "Doc")
        XCTAssertEqual(doc.dataForkSize, 9)
        XCTAssertEqual(doc.resourceForkSize, 0)
        XCTAssertEqual(doc.finderType, "PICT")
        XCTAssertEqual(doc.finderCreator, "MDRW")
    }

    /// An emulator (Mini vMac, Basilisk II, …) holding the image open must make the session
    /// read-only up front, so the two never write the same volume at once.
    func testImageHeldOpenByAnotherProcessOpensReadOnly() async throws {
        let image = try Fixtures.makeClassicHFSImage(in: work)
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/bin/sh")
        holder.arguments = ["-c", "exec 3<>\"$1\"; sleep 60", "holder", image.path]
        try holder.run()
        defer { holder.terminate() }
        let deadline = Date().addingTimeInterval(5)
        while await DiskImageManager.processesHoldingOpen(image.path).isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let holders = await DiskImageManager.processesHoldingOpen(image.path)
        XCTAssertFalse(holders.isEmpty, "test setup: holder never opened the image")

        let manager = DiskImageManager.forTesting()
        await manager.attachImage(imageURL: image)
        addTeardownBlock { await manager.ejectImage() }
        XCTAssertTrue(manager.isReadOnly)
        XCTAssertNotNil(manager.warningMessage)
    }

    // MARK: Names

    /// Regression: the hfs:// pseudo-URL carried the HFS path unescaped in its query, so a
    /// Cut of "Tom & Jerry" resolved to ":Tom" — and Paste then moved *that* (different) file.
    func testCutAndPasteMovesTheRightFileWhenNamesContainAmpersands() async throws {
        let image = try Fixtures.makeClassicHFSImage(in: work)
        try Fixtures.withMounted(image) {
            try Fixtures.putFile(Data("tom and jerry".utf8), at: ":Tom & Jerry", scratch: work)
            try Fixtures.putFile(Data("just tom".utf8), at: ":Tom", scratch: work)
            try Fixtures.hfs("hmkdir", [":Dest"])
        }

        let manager = try await open(image)
        manager.selectedEntries = [try manager.entry(named: "Tom & Jerry")]
        manager.cutSelected()
        await manager.navigate(into: try manager.entry(named: "Dest"))
        await manager.performPaste()
        XCTAssertNil(manager.errorMessage)
        await manager.ejectImage()

        try Fixtures.withMounted(image) {
            XCTAssertEqual(try Fixtures.names(in: ":"), ["Dest", "Tom"])
            XCTAssertEqual(try Fixtures.names(in: ":Dest"), ["Tom & Jerry"])
            XCTAssertEqual(try Fixtures.readFile(":Tom", scratch: work), Data("just tom".utf8))
        }
    }

    /// Regression: hls wraps long escaped names over several lines, and those entries silently
    /// disappeared from the browser (so they could not be exported or deleted either).
    func testListsNamesThatHLSWrapsOverSeveralLines() async throws {
        let image = try Fixtures.makeClassicHFSImage(in: work)
        // 30 Mac Roman high-bit bytes: each is escaped to 4 characters, forcing hls to wrap.
        let longName = String(repeating: "™", count: 30)
        let file = work.appendingPathComponent("payload")
        try Data("x".utf8).write(to: file)
        let manager = DiskImageManager.forTesting()
        await manager.attachImage(imageURL: image)
        addTeardownBlock { await manager.ejectImage() }
        // Import through the app (it handles the Mac Roman argument encoding) …
        let renamed = work.appendingPathComponent(longName)
        try FileManager.default.moveItem(at: file, to: renamed)
        await manager.importFiles(urls: [renamed], destination: URL(fileURLWithPath: "/"))
        XCTAssertNil(manager.errorMessage)
        // … and it must show up in the very next listing.
        XCTAssertEqual(manager.entries.map(\.name), [longName])
    }

    func testLargeFolderListsWithoutHanging() async throws {
        let image = try Fixtures.makeClassicHFSImage(in: work, sizeKB: 8 * 1024)
        // Long names so ~2,100 entries comfortably exceed the 64 KB pipe buffer in hls output.
        let count = 2_100
        try Fixtures.withMounted(image) {
            try Fixtures.hfs("hmkdir", [":Many"])
            let empty = work.appendingPathComponent("empty")
            try Data().write(to: empty)
            // One hcopy per file is slow; batch through xargs.
            let list = (1...count).map { String(format: "%@\0:Many:Long file name number %05d\0", empty.path, $0) }.joined()
            let listURL = work.appendingPathComponent("args")
            try Data(list.utf8).write(to: listURL)
            let result = Fixtures.run("/bin/sh", ["-c", "xargs -0 -n2 \(Fixtures.hfsutilsPrefix!)/hcopy -r < '\(listURL.path)'"])
            XCTAssertEqual(result.status, 0, result.output)
        }

        let manager = try await open(image)
        let many = try manager.entry(named: "Many")
        try await withTimeout(300) { @MainActor in await manager.navigate(into: many) }
        XCTAssertNil(manager.errorMessage)
        XCTAssertEqual(manager.entries.count, count)
    }

    // MARK: Copy / paste fidelity

    /// Copy/Paste inside an image used to round-trip through hcopy's automatic mode, which
    /// writes plain data forks — the copy came back as `????/UNIX`, so classic Mac OS no longer
    /// knew which application opens it. MacBinary keeps both forks and the Finder info.
    func testCopyPasteWithinImagePreservesTypeCreatorAndResourceFork() async throws {
        let image = try Fixtures.makeClassicHFSImage(in: work)
        try Fixtures.withMounted(image) {
            try Fixtures.putFile(Data("picture data".utf8), at: ":Drawing", type: "PICT", creator: "MDRW", scratch: work)
            try Fixtures.hfs("hmkdir", [":Dest"])
        }

        let manager = try await open(image)
        manager.copyEntry(try manager.entry(named: "Drawing"))
        await manager.navigate(into: try manager.entry(named: "Dest"))
        await manager.performPaste()
        XCTAssertNil(manager.errorMessage)
        await manager.ejectImage()

        try Fixtures.withMounted(image) {
            let copied = try Fixtures.longListing(of: ":Dest:Drawing")
            XCTAssertTrue(copied.contains("PICT/MDRW"), copied)
            XCTAssertEqual(try Fixtures.readFile(":Dest:Drawing", scratch: work), Data("picture data".utf8))
            XCTAssertTrue(try Fixtures.longListing(of: ":Drawing").contains("PICT/MDRW"), "the original must be untouched")
        }
    }

    /// The internal clipboard used to survive opening a different image. Cutting ":Shared" in
    /// image A and pasting in image B then ran `hrename :Shared` against *B* — moving an
    /// unrelated file the user never selected.
    func testClipboardFromPreviousImageNeverMovesFilesInTheNewImage() async throws {
        let imageA = try Fixtures.makeClassicHFSImage(in: work, name: "A.dsk", label: "A")
        let imageB = try Fixtures.makeClassicHFSImage(in: work, name: "B.dsk", label: "B")
        try Fixtures.withMounted(imageA) { try Fixtures.putFile(Data("from A".utf8), at: ":Shared", scratch: work) }
        try Fixtures.withMounted(imageB) {
            try Fixtures.putFile(Data("from B".utf8), at: ":Shared", scratch: work)
            try Fixtures.hfs("hmkdir", [":Sub"])
        }

        let manager = try await open(imageA)
        manager.cutEntry(try manager.entry(named: "Shared"))
        await manager.attachImage(imageURL: imageB)
        await manager.navigate(into: try manager.entry(named: "Sub"))
        await manager.performPaste()
        await manager.ejectImage()

        try Fixtures.withMounted(imageB) {
            XCTAssertTrue(try Fixtures.names(in: ":").contains("Shared"), "B's own file was moved by a cut made in A")
            XCTAssertEqual(try Fixtures.readFile(":Shared", scratch: work), Data("from B".utf8))
            // Pasting a *copy* of A's file is acceptable; pasting B's own file is not.
            if try Fixtures.names(in: ":Sub").contains("Shared") {
                XCTAssertEqual(try Fixtures.readFile(":Sub:Shared", scratch: work), Data("from A".utf8))
            }
        }
        try Fixtures.withMounted(imageA) {
            XCTAssertTrue(try Fixtures.names(in: ":").contains("Shared"), "a cut must never delete from an image that is no longer open")
        }
    }

    // MARK: Export safety

    func testExportOfDotDotNamedFolderStaysInsideDestination() async throws {
        let image = try Fixtures.makeClassicHFSImage(in: work)
        try Fixtures.withMounted(image) {
            try Fixtures.hfs("hmkdir", [":.."])
            try Fixtures.putFile(Data("escaped?".utf8), at: ":..:payload", scratch: work)
        }
        let manager = try await open(image)
        let destination = work.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        await manager.export([try manager.entry(named: "..")], intoFolder: destination)
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.appendingPathComponent("payload").path), "export wrote outside the chosen folder")
        let exported = try FileManager.default.contentsOfDirectory(atPath: destination.path)
        XCTAssertEqual(exported.count, 1)
    }

    // MARK: Lifecycle

    func testDeletingAFolderRemovesItsWholeTree() async throws {
        let image = try Fixtures.makeClassicHFSImage(in: work)
        try Fixtures.withMounted(image) {
            try Fixtures.hfs("hmkdir", [":Tree"])
            try Fixtures.hfs("hmkdir", [":Tree:Inner"])
            try Fixtures.putFile(Data("a".utf8), at: ":Tree:a", scratch: work)
            try Fixtures.putFile(Data("b".utf8), at: ":Tree:Inner:b", scratch: work)
            try Fixtures.putFile(Data("keep".utf8), at: ":Keep", scratch: work)
        }
        let manager = try await open(image)
        await manager.deleteEntries([try manager.entry(named: "Tree")])
        XCTAssertNil(manager.errorMessage)
        XCTAssertEqual(manager.entries.map(\.name), ["Keep"])
    }

    func testEjectReturnsToTheEmptyState() async throws {
        let image = try Fixtures.makeClassicHFSImage(in: work)
        let manager = try await open(image)
        await manager.ejectImage()
        XCTAssertNil(manager.imageURL)
        XCTAssertFalse(manager.usingHFSUtils)
        XCTAssertTrue(manager.entries.isEmpty)
    }
}
