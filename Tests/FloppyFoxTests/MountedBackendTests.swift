import AppKit
import XCTest
@testable import FloppyFox

/// Integration tests for the natively mounted backend (HFS+ images macOS can still mount),
/// against fresh `hdiutil create` images.
@MainActor
final class MountedBackendTests: XCTestCase {
    private var work: URL!

    override func setUp() async throws {
        work = try Fixtures.makeWorkDirectory("mounted")
    }

    override func tearDown() async throws {
        if let work { try? FileManager.default.removeItem(at: work) }
    }

    private func open() async throws -> (DiskImageManager, URL) {
        let image = try Fixtures.makeHFSPlusImage(in: work)
        let manager = DiskImageManager.forTesting()
        await manager.attachImage(imageURL: image)
        addTeardownBlock { await manager.ejectImage() }
        XCTAssertNil(manager.errorMessage)
        let mountPoint = try XCTUnwrap(manager.mountPoint, "an HFS+ image should mount natively")
        return (manager, mountPoint)
    }

    /// Regression: ejecting a mounted image left `imageURL` set, so with hfsutils installed
    /// `usingHFSUtils` flipped to true and the window kept showing an empty "open" browser
    /// (with Refresh/Eject still enabled) for an image that was no longer attached.
    func testEjectReturnsToTheEmptyState() async throws {
        let (manager, _) = try await open()
        await manager.ejectImage()
        XCTAssertNil(manager.imageURL)
        XCTAssertFalse(manager.isMounted)
        XCTAssertFalse(manager.usingHFSUtils)
        XCTAssertTrue(manager.entries.isEmpty)
    }

    /// Regression: Copy a folder, open it, Paste. The recursive copy enumerated the source
    /// while writing into it, nesting Folder/Folder/Folder/… until the volume filled up.
    func testPastingAFolderIntoItselfIsRefused() async throws {
        let (manager, mountPoint) = try await open()
        await manager.createFolder(named: "Loop")
        try Data("x".utf8).write(to: mountPoint.appendingPathComponent("Loop/file"))
        let loop = try manager.entry(named: "Loop")

        manager.copyEntry(loop)
        await manager.navigate(into: loop)
        try await withTimeout(30) { @MainActor in await manager.performPaste() }

        XCTAssertNotNil(manager.errorMessage, "pasting a folder into itself should be reported as an error")
        XCTAssertFalse(FileManager.default.fileExists(atPath: mountPoint.appendingPathComponent("Loop/Loop").path))
    }

    /// Regression: after NSSavePanel's own "Replace?" confirmation the export failed with
    /// "Destination already exists", so Replace never worked.
    func testExportReplacesAnExistingFileTheUserChoseToOverwrite() async throws {
        let (manager, mountPoint) = try await open()
        try Data("new contents".utf8).write(to: mountPoint.appendingPathComponent("report.txt"))
        await manager.refresh()
        let destination = work.appendingPathComponent("report.txt")
        try Data("stale".utf8).write(to: destination)

        await manager.export(try manager.entry(named: "report.txt"), to: destination)
        XCTAssertNil(manager.errorMessage)
        XCTAssertEqual(try Data(contentsOf: destination), Data("new contents".utf8))
    }

    func testCutAndPasteIntoTheSameFolderIsANoOp() async throws {
        let (manager, mountPoint) = try await open()
        try Data("stay".utf8).write(to: mountPoint.appendingPathComponent("here.txt"))
        await manager.refresh()
        manager.cutEntry(try manager.entry(named: "here.txt"))
        await manager.performPaste()
        XCTAssertNil(manager.errorMessage)
        XCTAssertEqual(try Data(contentsOf: mountPoint.appendingPathComponent("here.txt")), Data("stay".utf8))
    }

    func testCopyPasteIntoAnotherFolderDuplicatesContent() async throws {
        let (manager, mountPoint) = try await open()
        await manager.createFolder(named: "Dest")
        try Data("dup".utf8).write(to: mountPoint.appendingPathComponent("a.txt"))
        await manager.refresh()
        manager.copyEntry(try manager.entry(named: "a.txt"))
        await manager.navigate(into: try manager.entry(named: "Dest"))
        await manager.performPaste()
        XCTAssertNil(manager.errorMessage)
        XCTAssertEqual(try Data(contentsOf: mountPoint.appendingPathComponent("Dest/a.txt")), Data("dup".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: mountPoint.appendingPathComponent("a.txt").path))
    }

    func testReadOnlyImageRefusesEveryWrite() async throws {
        let image = try Fixtures.makeHFSPlusImage(in: work)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: image.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: image.path) }
        let manager = DiskImageManager.forTesting()
        await manager.attachImage(imageURL: image)
        addTeardownBlock { await manager.ejectImage() }
        XCTAssertTrue(manager.isReadOnly)
        manager.warningMessage = nil

        await manager.createFolder(named: "Nope")
        XCTAssertNotNil(manager.errorMessage)
        manager.errorMessage = nil
        let host = work.appendingPathComponent("f.txt")
        try Data("x".utf8).write(to: host)
        await manager.importFiles(urls: [host], destination: try XCTUnwrap(manager.mountPoint))
        XCTAssertNotNil(manager.errorMessage)
        XCTAssertFalse(manager.entries.contains { $0.name == "Nope" || $0.name == "f.txt" })
    }
}
