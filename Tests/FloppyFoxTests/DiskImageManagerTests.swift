import AppKit
import XCTest
@testable import FloppyFox

/// End-to-end tests of the app's model (`DiskImageManager`) on fresh `hformat` volumes. After
/// each operation the image is checked from outside the app — with hfsutils for content and
/// Apple's `fsck_hfs` for structure — so a test only passes when the change really reached the
/// image file, correctly.
@MainActor
final class DiskImageManagerTests: XCTestCase {
    private var work: URL!

    override func setUp() async throws {
        guard Fixtures.hfsutilsPrefix != nil else { throw XCTSkip("hfsutils (brew install hfsutils) is required as a test oracle") }
        work = try Fixtures.makeWorkDirectory("manager")
    }

    override func tearDown() async throws {
        if let work { try? FileManager.default.removeItem(at: work) }
    }

    private func open(_ image: URL, file: StaticString = #filePath, line: UInt = #line) async throws -> DiskImageManager {
        let manager = DiskImageManager.forTesting()
        await manager.attachImage(imageURL: image)
        addTeardownBlock { await manager.ejectImage() }
        XCTAssertNil(manager.errorMessage, file: file, line: line)
        XCTAssertTrue(manager.isOpen, file: file, line: line)
        return manager
    }

    private func assertFsckClean(_ image: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let verdict = try Fixtures.fsck(image)
        XCTAssertTrue(verdict.clean, "fsck_hfs rejected the volume:\n\(verdict.output)", file: file, line: line)
    }

    private func hostFile(_ name: String, _ contents: String) throws -> URL {
        let url = work.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    // MARK: Persistence

    func testEditsReachTheImageFileOnDisk() async throws {
        let image = try Fixtures.makeClassicHFSImage(in: work)
        let manager = try await open(image)
        XCTAssertFalse(manager.isReadOnly)
        await manager.createFolder(named: "Kept Folder")
        await manager.importFiles(urls: [try hostFile("hello.txt", "hello")])
        let doomed = try hostFile("doomed.txt", "bye")
        await manager.importFiles(urls: [doomed])
        await manager.deleteEntries([try manager.entry(named: "doomed.txt")])
        XCTAssertNil(manager.errorMessage)
        await manager.ejectImage()

        try assertFsckClean(image)
        try Fixtures.withMounted(image) {
            XCTAssertEqual(try Fixtures.names(in: ":"), ["Kept Folder", "hello.txt"])
            XCTAssertEqual(try Fixtures.readFile(":hello.txt", scratch: work), Data("hello".utf8))
            XCTAssertTrue(try Fixtures.longListing(of: ":hello.txt").contains("TEXT/ttxt"), "a .txt import should be typed TEXT/ttxt")
        }
    }

    func testEjectReturnsToTheEmptyStateAndRemovesPreviews() async throws {
        let image = try Fixtures.makeClassicHFSImage(in: work)
        let manager = try await open(image)
        await manager.importFiles(urls: [try hostFile("peek.txt", "peek")])
        let preview = await manager.materializeForPreview(try manager.entry(named: "peek.txt"))
        let previewURL = try XCTUnwrap(preview)
        XCTAssertEqual(try String(contentsOf: previewURL, encoding: .utf8), "peek")
        await manager.ejectImage()
        XCTAssertNil(manager.imageURL)
        XCTAssertFalse(manager.isOpen)
        XCTAssertTrue(manager.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: previewURL.path), "previews of an ejected image should be deleted")
    }

    // MARK: Names and the clipboard

    /// Regression (old backend): ":Tom & Jerry" resolved to ":Tom", and Paste moved that
    /// different file instead.
    func testCutAndPasteMovesTheRightFileWhenNamesContainAmpersands() async throws {
        let image = try Fixtures.makeClassicHFSImage(in: work)
        try Fixtures.withMounted(image) {
            try Fixtures.putFile(Data("tom and jerry".utf8), at: ":Tom & Jerry", scratch: work)
            try Fixtures.putFile(Data("just tom".utf8), at: ":Tom", scratch: work)
            try Fixtures.hfs("hmkdir", [":Dest"])
        }
        let manager = try await open(image)
        manager.cutEntry(try manager.entry(named: "Tom & Jerry"))
        await manager.navigate(into: try manager.entry(named: "Dest"))
        await manager.performPaste()
        XCTAssertNil(manager.errorMessage)
        await manager.ejectImage()

        try Fixtures.withMounted(image) {
            XCTAssertEqual(try Fixtures.names(in: ":"), ["Dest", "Tom"])
            XCTAssertEqual(try Fixtures.names(in: ":Dest"), ["Tom & Jerry"])
            XCTAssertEqual(try Fixtures.readFile(":Dest:Tom & Jerry", scratch: work), Data("tom and jerry".utf8))
        }
    }

    /// Copy/Paste duplicates both forks and the Finder info; pasting into the same folder
    /// makes "Name copy" like the Finder.
    func testCopyPasteKeepsForksAndFinderInfoAndNamesDuplicatesLikeTheFinder() async throws {
        let image = try Fixtures.makeClassicHFSImage(in: work)
        let resource = [UInt8]((0..<700).map { UInt8(truncatingIfNeeded: $0 * 13) })
        let bin = MacBinaryFile(name: try HFSName("Drawing"), fileType: Array("PICT".utf8), creator: Array("MDRW".utf8), finderFlags: 0,
                                dataFork: Array("picture data".utf8), resourceFork: resource)
        let binURL = work.appendingPathComponent("drawing.bin")
        try Data(bin.encoded()).write(to: binURL)
        try Fixtures.withMounted(image) {
            try Fixtures.hfs("hcopy", ["-m", binURL.path, ":Drawing"])
            try Fixtures.hfs("hmkdir", [":Dest"])
        }

        let manager = try await open(image)
        manager.copyEntry(try manager.entry(named: "Drawing"))
        await manager.performPaste() // same folder
        await manager.navigate(into: try manager.entry(named: "Dest"))
        await manager.performPaste() // another folder
        XCTAssertNil(manager.errorMessage)
        await manager.ejectImage()

        try Fixtures.withMounted(image) {
            XCTAssertEqual(try Fixtures.names(in: ":"), ["Dest", "Drawing", "Drawing copy"])
            for path in [":Drawing copy", ":Dest:Drawing"] {
                XCTAssertTrue(try Fixtures.longListing(of: path).contains("PICT/MDRW"), path)
                let exported = work.appendingPathComponent(UUID().uuidString)
                try Fixtures.hfs("hcopy", ["-m", path, exported.path])
                let decoded = try XCTUnwrap(MacBinaryFile.decode(Array(try Data(contentsOf: exported))))
                XCTAssertEqual(decoded.resourceFork, resource, path)
                XCTAssertEqual(decoded.dataFork, Array("picture data".utf8), path)
            }
        }
    }

    /// The clipboard used to survive opening a different image; a Cut in A then moved B's
    /// same-named file on Paste.
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
            XCTAssertEqual(try Fixtures.readFile(":Shared", scratch: work), Data("from B".utf8), "B's own file was touched by a cut made in A")
            if try Fixtures.names(in: ":Sub").contains("Shared") {
                XCTAssertEqual(try Fixtures.readFile(":Sub:Shared", scratch: work), Data("from A".utf8))
            }
        }
        try Fixtures.withMounted(imageA) {
            XCTAssertTrue(try Fixtures.names(in: ":").contains("Shared"), "a cut must never delete from an image that is no longer open")
        }
    }

    func testPastingAFolderIntoItselfIsRefused() async throws {
        let image = try Fixtures.makeClassicHFSImage(in: work)
        let manager = try await open(image)
        await manager.createFolder(named: "Loop")
        let loop = try manager.entry(named: "Loop")
        manager.copyEntry(loop)
        await manager.navigate(into: loop)
        try await withTimeout(30) { @MainActor in await manager.performPaste() }
        XCTAssertNotNil(manager.errorMessage)
        XCTAssertTrue(manager.entries.isEmpty)

        manager.errorMessage = nil
        await manager.goUp()
        manager.cutEntry(try manager.entry(named: "Loop"))
        await manager.navigate(into: try manager.entry(named: "Loop"))
        await manager.performPaste()
        XCTAssertNotNil(manager.errorMessage, "moving a folder into itself must be refused too")
        await manager.ejectImage()
        try assertFsckClean(image)
    }

    func testCutAndPasteIntoTheSameFolderIsANoOp() async throws {
        let image = try Fixtures.makeClassicHFSImage(in: work)
        let manager = try await open(image)
        await manager.importFiles(urls: [try hostFile("here.txt", "stay")])
        manager.cutEntry(try manager.entry(named: "here.txt"))
        await manager.performPaste()
        XCTAssertNil(manager.errorMessage)
        XCTAssertEqual(manager.entries.map(\.name), ["here.txt"])
    }

    // MARK: Moving files between the image and the Mac

    /// Export writes the data fork, the resource fork (as the file's native resource fork) and
    /// the type/creator; importing that file into another image reproduces the original.
    func testExportAndReimportRoundTripBothForksAndFinderInfo() async throws {
        let source = try Fixtures.makeClassicHFSImage(in: work, name: "Source.dsk")
        let resource = [UInt8]((0..<5000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let bin = MacBinaryFile(name: try HFSName("Game"), fileType: Array("APPL".utf8), creator: Array("GAME".utf8), finderFlags: 0,
                                dataFork: Array("data fork".utf8), resourceFork: resource)
        let binURL = work.appendingPathComponent("game.bin")
        try Data(bin.encoded()).write(to: binURL)
        try Fixtures.withMounted(source) { try Fixtures.hfs("hcopy", ["-m", binURL.path, ":Game"]) }

        let manager = try await open(source)
        let exportFolder = work.appendingPathComponent("exported", isDirectory: true)
        try FileManager.default.createDirectory(at: exportFolder, withIntermediateDirectories: true)
        await manager.export([try manager.entry(named: "Game")], intoFolder: exportFolder)
        XCTAssertNil(manager.errorMessage)
        let exported = exportFolder.appendingPathComponent("Game")
        XCTAssertEqual(Array(try Data(contentsOf: exported)), Array("data fork".utf8))
        XCTAssertEqual(try HostFiles.readResourceFork(of: exported), resource)
        let finderInfo = try XCTUnwrap(HostFiles.extendedAttribute(HostFiles.finderInfoAttribute, of: exported))
        XCTAssertEqual(Array(finderInfo[0..<8]), Array("APPLGAME".utf8))

        let destination = try Fixtures.makeClassicHFSImage(in: work, name: "Destination.dsk")
        await manager.attachImage(imageURL: destination)
        await manager.importFiles(urls: [exported])
        XCTAssertNil(manager.errorMessage)
        await manager.ejectImage()
        try assertFsckClean(destination)
        try Fixtures.withMounted(destination) {
            XCTAssertTrue(try Fixtures.longListing(of: ":Game").contains("APPL/GAME"))
            let roundTrip = work.appendingPathComponent("roundtrip.bin")
            try Fixtures.hfs("hcopy", ["-m", ":Game", roundTrip.path])
            XCTAssertEqual(MacBinaryFile.decode(Array(try Data(contentsOf: roundTrip)))?.resourceFork, resource)
        }
    }

    func testImportUnpacksMacBinaryDownloads() async throws {
        let image = try Fixtures.makeClassicHFSImage(in: work)
        let bin = MacBinaryFile(name: try HFSName("Installer"), fileType: Array("APPL".utf8), creator: Array("INST".utf8), finderFlags: 0,
                                dataFork: [], resourceFork: [1, 2, 3, 4])
        let url = work.appendingPathComponent("Installer.sea.bin")
        try Data(bin.encoded()).write(to: url)
        let manager = try await open(image)
        await manager.importFiles(urls: [url])
        let installer = try manager.entry(named: "Installer")
        XCTAssertEqual(installer.finderType, "APPL")
        XCTAssertEqual(installer.resourceForkSize, 4)
    }

    func testExportReplacesAFileTheUserChoseToOverwrite() async throws {
        let image = try Fixtures.makeClassicHFSImage(in: work)
        let manager = try await open(image)
        await manager.importFiles(urls: [try hostFile("report.txt", "new contents")])
        let destination = work.appendingPathComponent("existing.txt")
        try Data("stale".utf8).write(to: destination)
        await manager.export(try manager.entry(named: "report.txt"), to: destination)
        XCTAssertNil(manager.errorMessage)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "new contents")
    }

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
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path).count, 1)
    }

    // MARK: Larger and failing operations

    func testDeletingAFolderRemovesItsWholeTree() async throws {
        let image = try Fixtures.makeClassicHFSImage(in: work)
        let tree = work.appendingPathComponent("Tree", isDirectory: true)
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("Inner"), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: tree.appendingPathComponent("a"))
        try Data("b".utf8).write(to: tree.appendingPathComponent("Inner/b"))
        let manager = try await open(image)
        await manager.importFiles(urls: [tree, try hostFile("Keep", "keep")])
        XCTAssertEqual(Set(manager.entries.map(\.name)), ["Tree", "Keep"])
        await manager.deleteEntries([try manager.entry(named: "Tree")])
        XCTAssertNil(manager.errorMessage)
        XCTAssertEqual(manager.entries.map(\.name), ["Keep"])
        await manager.ejectImage()
        try assertFsckClean(image)
    }

    func testLargeFolderImportsAndListsQuickly() async throws {
        let image = try Fixtures.makeClassicHFSImage(in: work, sizeKB: 8 * 1024)
        let folder = work.appendingPathComponent("Many", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let count = 2_100
        for i in 0..<count {
            FileManager.default.createFile(atPath: folder.appendingPathComponent(String(format: "Long file name number %05d", i)).path, contents: Data([UInt8(i & 0xFF)]))
        }
        let manager = try await open(image)
        try await withTimeout(120) { @MainActor in await manager.importFiles(urls: [folder]) }
        let many = try manager.entry(named: "Many")
        try await withTimeout(30) { @MainActor in await manager.navigate(into: many) }
        XCTAssertEqual(manager.entries.count, count)
        await manager.ejectImage()
        try assertFsckClean(image)
    }

    /// Cancelling mid-import keeps the items that finished, discards the one in flight, and
    /// leaves a volume Apple's checker accepts.
    func testCancelledImportKeepsFinishedItemsAndLeavesVolumeConsistent() async throws {
        let image = try Fixtures.makeClassicHFSImage(in: work, sizeKB: 40 * 1024)
        let small = try hostFile("small.txt", "small")
        let big = work.appendingPathComponent("big.bin")
        try Data(repeating: 0x5A, count: 20 * 1024 * 1024).write(to: big)
        let manager = try await open(image)
        manager.transferProgressObserver = { [weak manager] message in
            if message.contains("big.bin") { manager?.cancelActiveTransfer() }
        }
        await manager.importFiles(urls: [small, big])
        XCTAssertEqual(manager.statusMessage, "Import cancelled")
        XCTAssertEqual(manager.entries.map(\.name), ["small.txt"])
        await manager.ejectImage()
        try assertFsckClean(image)
    }

    func testFullVolumeRejectsAnImportWithoutDamage() async throws {
        let image = try Fixtures.makeClassicHFSImage(in: work, sizeKB: 800)
        let manager = try await open(image)
        await manager.importFiles(urls: [try hostFile("keep.txt", "keep")])
        let big = work.appendingPathComponent("toobig.bin")
        try Data(repeating: 1, count: 2 * 1024 * 1024).write(to: big)
        await manager.importFiles(urls: [big])
        XCTAssertNotNil(manager.errorMessage)
        XCTAssertEqual(manager.entries.map(\.name), ["keep.txt"])
        manager.errorMessage = nil
        await manager.importFiles(urls: [try hostFile("after.txt", "fits")])
        XCTAssertNil(manager.errorMessage, "the volume should still accept files that fit")
        await manager.ejectImage()
        try assertFsckClean(image)
    }

    // MARK: Read-only situations

    func testReadOnlyImageFileRefusesEveryWrite() async throws {
        let image = try Fixtures.makeClassicHFSImage(in: work)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: image.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: image.path) }
        let before = try Data(contentsOf: image)
        let manager = try await open(image)
        XCTAssertTrue(manager.isReadOnly)
        XCTAssertNotNil(manager.warningMessage)

        await manager.createFolder(named: "Nope")
        XCTAssertNotNil(manager.errorMessage)
        manager.errorMessage = nil
        await manager.importFiles(urls: [try hostFile("f.txt", "x")])
        XCTAssertNotNil(manager.errorMessage)
        await manager.ejectImage()
        XCTAssertEqual(try Data(contentsOf: image), before)
    }

    func testLockedVolumeOpensReadOnly() async throws {
        let image = try Fixtures.makeClassicHFSImage(in: work)
        var bytes = Array(try Data(contentsOf: image))
        bytes[1024 + 10] |= 0x80 // drAtrb bit 15: software lock
        try Data(bytes).write(to: image)
        let manager = try await open(image)
        XCTAssertTrue(manager.isReadOnly)
        XCTAssertNotNil(manager.readOnlyReason)
    }

    /// An emulator holding the image open must make the session read-only up front.
    /// (Detection relies on lsof, which works outside the App Sandbox.)
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
        let manager = try await open(image)
        XCTAssertTrue(manager.isReadOnly)
        XCTAssertNotNil(manager.warningMessage)
    }

    // MARK: Containers

    func testFixedVHDIsEditableAndItsFooterSurvives() async throws {
        let raw = try Fixtures.makeClassicHFSImage(in: work)
        var footer = [UInt8](repeating: 0, count: 512)
        footer.put(Array("conectix".utf8), at: 0)
        footer.put32(2, at: 60) // fixed disk
        let vhd = work.appendingPathComponent("disk.vhd")
        try Data(Array(try Data(contentsOf: raw)) + footer).write(to: vhd)

        let manager = try await open(vhd)
        XCTAssertFalse(manager.isReadOnly)
        await manager.createFolder(named: "In VHD")
        await manager.ejectImage()
        let bytes = Array(try Data(contentsOf: vhd))
        XCTAssertEqual(Array(bytes.suffix(512)), footer, "the VHD footer must not be overwritten")
        let reopened = try await open(vhd)
        XCTAssertNoThrow(try reopened.entry(named: "In VHD"))
    }

    func testHFSPlusImagesReportAClearError() async throws {
        let image = try Fixtures.makeHFSPlusImage(in: work)
        let manager = DiskImageManager.forTesting()
        await manager.attachImage(imageURL: image)
        XCTAssertFalse(manager.isOpen)
        XCTAssertTrue(manager.errorMessage?.contains("HFS+") == true, manager.errorMessage ?? "no error")
    }

    // MARK: Drag and drop, temporary files

    /// An unbalanced `DispatchGroup.leave()` for non-file providers used to trap.
    func testDroppingNonFileItemsDoesNotCrash() async throws {
        let image = try Fixtures.makeClassicHFSImage(in: work)
        let manager = try await open(image)
        XCTAssertTrue(manager.handleDroppedFiles(providers: [NSItemProvider(object: "just some text" as NSString)]))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(manager.errorMessage)
    }

    func testTemporaryStorageSweepsOnlyAbandonedLaunches() throws {
        let root = work.appendingPathComponent("storage", isDirectory: true)
        let dead = root.appendingPathComponent("999999-dead", isDirectory: true)
        let alive = root.appendingPathComponent("1-launchd", isDirectory: true) // pid 1 always exists
        try FileManager.default.createDirectory(at: dead, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: alive, withIntermediateDirectories: true)
        let storage = TemporaryStorage(root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dead.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: alive.path))
        let scratch = try storage.makeDirectory("preview")
        storage.removeLaunchDirectory()
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.path))
    }

    // MARK: Real images

    /// Edits a clone of a real Mac OS-written BlueSCSI image through the app, including a
    /// cancelled import, then has Apple's checker inspect it.
    func testRealHardDiskImageSurvivesEditsAndCancelledImports() async throws {
        let original = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FLOPPYFOX_REAL_HDA"]
            ?? "/Users/amuskens/Downloads/ PreInstalled MacOS Images/HD0-OpenRetroSCSI-7.1.hda")
        guard FileManager.default.fileExists(atPath: original.path) else { throw XCTSkip("set FLOPPYFOX_REAL_HDA to a Mac OS-written .hda image") }
        let image = work.appendingPathComponent("real.hda")
        try FileManager.default.copyItem(at: original, to: image)
        guard try Fixtures.fsck(image).clean else { throw XCTSkip("the original image isn't fsck-clean to begin with") }

        let manager = try await open(image)
        let baseline = Set(manager.entries.map(\.name))
        await manager.createFolder(named: "FloppyFox Test")
        await manager.navigate(into: try manager.entry(named: "FloppyFox Test"))
        let big = work.appendingPathComponent("big.bin")
        try Data(repeating: 0x33, count: 30 * 1024 * 1024).write(to: big)
        let first = try hostFile("first.txt", "first")
        manager.transferProgressObserver = { [weak manager] message in
            if message.contains("big.bin") { manager?.cancelActiveTransfer() }
        }
        await manager.importFiles(urls: [first, big])
        XCTAssertEqual(manager.entries.map(\.name), ["first.txt"])
        await manager.ejectImage()
        try assertFsckClean(image)

        let reopened = try await open(image)
        XCTAssertEqual(Set(reopened.entries.map(\.name)), baseline.union(["FloppyFox Test"]))
    }
}
