#if canImport(XCTest)
import AppKit
import CryptoKit
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

    func testChunkedFileCopyStopsMidTransferAndRemovesPartialOutput() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("floppyfox-cancel-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let source = tempDir.appendingPathComponent("source.bin")
        let destination = tempDir.appendingPathComponent("destination.bin")
        // 10 one-byte chunks; cancelling after the 3rd proves the copy actually stops instead
        // of just being asked to and finishing anyway.
        try Data(repeating: 0x42, count: 10).write(to: source)

        let chunksSeen = Counter()
        do {
            try await DiskImageManager.copyFileChunked(from: source, to: destination, chunkSize: 1) {
                chunksSeen.increment() > 3
            }
            XCTFail("expected copyFileChunked to throw CancellationError once shouldCancel returned true")
        } catch is CancellationError {
            // expected: cancellation was honored before the copy reached the end of the file
        }

        XCTAssertEqual(chunksSeen.value, 4, "copy should stop right after shouldCancel first reports true, not run to completion")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destination.path),
            "a cancelled transfer should not leave a partially-written file behind"
        )
    }

    func testChunkedFileCopyCompletesAndMatchesSourceWhenNotCancelled() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("floppyfox-copy-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let source = tempDir.appendingPathComponent("source.bin")
        let destination = tempDir.appendingPathComponent("destination.bin")
        let payload = Data((0..<10_000).map { UInt8($0 % 256) })
        try payload.write(to: source)

        try await DiskImageManager.copyFileChunked(from: source, to: destination, chunkSize: 777) { false }

        XCTAssertEqual(try Data(contentsOf: destination), payload)
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
        addTeardownBlock { await manager.ejectImage() }

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

    /// End-to-end exercise of the natively-mounted (`isMounted`) backend's full read/write
    /// surface — create folder, import, navigate, move, delete — against a throwaway HFS+
    /// image built fresh with `hdiutil create` so nothing outside the temp directory is
    /// touched. Skips rather than fails if `hdiutil` can't create/mount here, since that's an
    /// environment limitation, not a regression in the app.
    func testMountedBackendSupportsFullReadWriteLifecycle() async throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("floppyfox-mounted-lifecycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let imageURL = workDir.appendingPathComponent("lifecycle.dmg")
        let create = Process()
        create.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        create.arguments = ["create", "-size", "256m", "-fs", "HFS+", "-volname", "FloppyFoxLifecycle", imageURL.path]
        create.standardOutput = Pipe()
        create.standardError = Pipe()
        try create.run()
        create.waitUntilExit()
        guard create.terminationStatus == 0 else {
            throw XCTSkip("hdiutil create is unavailable in this environment")
        }

        let manager = DiskImageManager()
        await manager.attachImage(imageURL: imageURL)
        addTeardownBlock { await manager.ejectImage() }

        XCTAssertNil(manager.errorMessage)
        XCTAssertTrue(manager.isMounted, "a plain HFS+ image should mount natively rather than falling back to hfsutils")
        guard let mountPoint = manager.mountPoint else {
            XCTFail("expected a mount point once attached")
            return
        }

        // Create folder
        await manager.createFolder(named: "Documents")
        XCTAssertNil(manager.errorMessage)
        guard let documentsEntry = manager.entries.first(where: { $0.name == "Documents" && $0.isDirectory }) else {
            XCTFail("expected a Documents folder after createFolder"); return
        }

        // Import a small file and a large-ish one (big enough to span many chunks of the new
        // chunked copy, so a bug at a chunk boundary would show up as corrupted content here).
        let smallFile = workDir.appendingPathComponent("note.txt")
        try "Hello from FloppyFox".write(to: smallFile, atomically: true, encoding: .utf8)
        let bigFile = workDir.appendingPathComponent("big.bin")
        let bigPayload = Data((0..<(20 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0) })
        try bigPayload.write(to: bigFile)

        await manager.navigate(into: documentsEntry)
        await manager.importFiles(urls: [smallFile, bigFile], destination: mountPoint.appendingPathComponent("Documents"))
        XCTAssertNil(manager.errorMessage)
        XCTAssertEqual(manager.entries.map(\.name).sorted(), ["big.bin", "note.txt"])

        let importedBigPath = mountPoint.appendingPathComponent("Documents/big.bin")
        XCTAssertEqual(try Data(contentsOf: importedBigPath), bigPayload, "imported file content should round-trip exactly through the chunked copy")

        // Move: pull big.bin back up to the volume root.
        guard let bigEntry = manager.entries.first(where: { $0.name == "big.bin" }) else {
            XCTFail("expected big.bin after import"); return
        }
        await manager.moveFiles(urls: [bigEntry.url], destination: mountPoint)
        XCTAssertNil(manager.errorMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mountPoint.appendingPathComponent("big.bin").path))
        await manager.refresh()
        XCTAssertEqual(manager.entries.map(\.name), ["note.txt"], "big.bin should be gone from Documents after being moved out")

        // Cancel an in-flight import of a large file and confirm it actually stops instead of
        // completing regardless — the behavior this whole backend was fixed to support.
        await manager.goUp()
        let hugeFile = workDir.appendingPathComponent("huge.bin")
        try Data(repeating: 0x7E, count: 150 * 1024 * 1024).write(to: hugeFile)
        let importTask = Task { await manager.importFiles(urls: [hugeFile], destination: mountPoint) }
        // Let importFiles reach its first real suspension point (handing the copy to a
        // detached task) before cancelling — its synchronous prefix up to that point has no
        // awaits, so a few milliseconds is ample, while a 150MB chunked copy is nowhere near
        // done that quickly.
        try await Task.sleep(for: .milliseconds(5))
        manager.cancelActiveTransfer()
        await importTask.value
        XCTAssertEqual(manager.statusMessage, "Import cancelled")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: mountPoint.appendingPathComponent("huge.bin").path),
            "a cancelled import should not leave a partially-copied file on the mounted volume"
        )

        // Delete: remove the Documents folder (and note.txt inside it) recursively.
        await manager.deleteEntries([documentsEntry])
        XCTAssertNil(manager.errorMessage)
        await manager.refresh()
        XCTAssertFalse(manager.entries.contains(where: { $0.name == "Documents" }))
    }

    /// Exercises the legacy hfsutils backend's write path (create folder, import, move,
    /// delete) against a disposable *copy* of the real multi-partition fixture used by
    /// `testOpenRealMultiPartitionHDAImage` — never the original file — since hfsutils writes
    /// directly to whatever image path it's given.
    func testHFSUtilsBackendSupportsFullReadWriteLifecycle() async throws {
        let fixture = URL(fileURLWithPath: "/Users/amuskens/Downloads/ PreInstalled MacOS Images/HD0-OpenRetroSCSI-7.1.hda")
        guard FileManager.default.fileExists(atPath: fixture.path) else {
            throw XCTSkip("Real HDA fixture not present on this machine")
        }

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("floppyfox-hfsutils-lifecycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let workingCopy = workDir.appendingPathComponent("working.hda")
        try FileManager.default.copyItem(at: fixture, to: workingCopy)

        let manager = DiskImageManager()
        await manager.attachImage(imageURL: workingCopy)
        addTeardownBlock { await manager.ejectImage() }

        XCTAssertNil(manager.errorMessage)
        XCTAssertTrue(manager.usingHFSUtils)
        let originalCount = manager.entries.count
        XCTAssertGreaterThan(originalCount, 0)

        // Create folder
        await manager.createFolder(named: "FloppyFoxTest")
        XCTAssertNil(manager.errorMessage)
        guard let folderEntry = manager.entries.first(where: { $0.name == "FloppyFoxTest" && $0.isDirectory }) else {
            XCTFail("expected FloppyFoxTest folder after createFolder"); return
        }

        // Import a host file into that folder.
        await manager.navigate(into: folderEntry)
        let hostFile = workDir.appendingPathComponent("note.txt")
        try "Hello from the hfsutils backend".write(to: hostFile, atomically: true, encoding: .utf8)
        await manager.importFiles(urls: [hostFile], destination: workDir)
        XCTAssertNil(manager.errorMessage)
        XCTAssertTrue(manager.entries.contains(where: { $0.name == "note.txt" }))

        // Move: pull note.txt back up to the volume root using the same synthetic
        // hfs://localhost/<image>?path=<hfs path> pseudo-URL `copyEntry`/`cutEntry` produce.
        guard let noteEntry = manager.entries.first(where: { $0.name == "note.txt" }),
              let hfsPath = noteEntry.hfsPath,
              let pseudo = URL(string: "hfs://localhost\(workingCopy.path)?path=\(hfsPath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? hfsPath)")
        else {
            XCTFail("expected note.txt with a resolvable hfs path after import"); return
        }
        await manager.navigate(toHFSDirectory: ":")
        await manager.moveFiles(urls: [pseudo], destination: workDir)
        XCTAssertNil(manager.errorMessage)
        await manager.refresh()
        XCTAssertTrue(manager.entries.contains(where: { $0.name == "note.txt" }), "note.txt should now be at the volume root")

        // Delete: remove the (now-empty) FloppyFoxTest folder.
        guard let emptyFolderEntry = manager.entries.first(where: { $0.name == "FloppyFoxTest" }) else {
            XCTFail("expected FloppyFoxTest folder to still exist"); return
        }
        await manager.deleteEntries([emptyFolderEntry])
        XCTAssertNil(manager.errorMessage)
        await manager.refresh()
        XCTAssertFalse(manager.entries.contains(where: { $0.name == "FloppyFoxTest" }))
        XCTAssertEqual(manager.entries.count, originalCount + 1, "root should have the original entries plus the relocated note.txt")
    }

    /// Repeatedly cancels large imports mid-transfer against a real natively-mounted HFS+
    /// image and checks, at the filesystem level (not just "is the file there"), that nothing
    /// was damaged: pre-existing "canary" files stay byte-identical, `diskutil verifyVolume`
    /// reports no problems both while still mounted and after a full eject/reattach cold
    /// round-trip, and the volume remains usable afterward.
    func testCancellingMountedImportsRepeatedlyLeavesVolumeUncorrupted() async throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("floppyfox-corruption-mounted-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let imageURL = workDir.appendingPathComponent("corruption.dmg")
        let create = Process()
        create.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        create.arguments = ["create", "-size", "400m", "-fs", "HFS+", "-volname", "FloppyFoxCorruptionTest", imageURL.path]
        create.standardOutput = Pipe()
        create.standardError = Pipe()
        try create.run()
        create.waitUntilExit()
        guard create.terminationStatus == 0 else {
            throw XCTSkip("hdiutil create is unavailable in this environment")
        }

        let manager = DiskImageManager()
        await manager.attachImage(imageURL: imageURL)
        XCTAssertNil(manager.errorMessage)
        XCTAssertTrue(manager.isMounted)
        guard let mountPoint = manager.mountPoint else {
            XCTFail("expected a mount point once attached"); return
        }

        // Baseline content that must survive every cancelled transfer completely untouched.
        let canaryTextPayload = Data("Canary file — must survive every cancelled transfer untouched.".utf8)
        let canaryBinaryPayload = Data((0..<(3 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 * 7 + 13) })
        let canaryText = workDir.appendingPathComponent("canary.txt")
        let canaryBinary = workDir.appendingPathComponent("canary.bin")
        try canaryTextPayload.write(to: canaryText)
        try canaryBinaryPayload.write(to: canaryBinary)
        await manager.importFiles(urls: [canaryText, canaryBinary], destination: mountPoint)
        XCTAssertNil(manager.errorMessage)

        func assertCanariesIntact(at mountPoint: URL, line: UInt = #line) throws {
            XCTAssertEqual(try Data(contentsOf: mountPoint.appendingPathComponent("canary.txt")), canaryTextPayload, "canary text file corrupted", line: line)
            XCTAssertEqual(try Data(contentsOf: mountPoint.appendingPathComponent("canary.bin")), canaryBinaryPayload, "canary binary file corrupted", line: line)
        }
        try assertCanariesIntact(at: mountPoint)

        // Repeatedly cancel a large import mid-transfer (proven mid-transfer, not mid-batch,
        // by the earlier lifecycle test) and confirm neither the canaries nor the volume
        // itself take any damage.
        for i in 0..<3 {
            let bigFile = workDir.appendingPathComponent("victim-\(i).bin")
            try Data(repeating: UInt8(truncatingIfNeeded: i), count: 120 * 1024 * 1024).write(to: bigFile)
            let importTask = Task { await manager.importFiles(urls: [bigFile], destination: mountPoint) }
            try await Task.sleep(for: .milliseconds(5))
            manager.cancelActiveTransfer()
            await importTask.value
            try? FileManager.default.removeItem(at: bigFile)

            XCTAssertEqual(manager.statusMessage, "Import cancelled")
            XCTAssertFalse(FileManager.default.fileExists(atPath: mountPoint.appendingPathComponent("victim-\(i).bin").path))
            try assertCanariesIntact(at: mountPoint)
        }

        // Filesystem-level integrity check while still mounted.
        try assertVolumeVerifies(at: mountPoint)

        // The volume must still be genuinely usable afterward, not just superficially intact.
        let postCancelFile = workDir.appendingPathComponent("after.txt")
        try "still works".write(to: postCancelFile, atomically: true, encoding: .utf8)
        await manager.importFiles(urls: [postCancelFile], destination: mountPoint)
        XCTAssertNil(manager.errorMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mountPoint.appendingPathComponent("after.txt").path))

        await manager.ejectImage()

        // Full cold round-trip: reattach fresh (a completely new manager instance, no
        // leftover in-memory state) and confirm everything still checks out.
        let manager2 = DiskImageManager()
        await manager2.attachImage(imageURL: imageURL)
        addTeardownBlock { await manager2.ejectImage() }
        XCTAssertNil(manager2.errorMessage)
        XCTAssertTrue(manager2.isMounted)
        guard let mountPoint2 = manager2.mountPoint else {
            XCTFail("expected a mount point after reattaching"); return
        }
        try assertCanariesIntact(at: mountPoint2)
        try assertVolumeVerifies(at: mountPoint2)
    }

    /// Cancels an import partway through a multi-file batch against a disposable *copy* of the
    /// real multi-partition fixture (never the original) and confirms pre-existing volume
    /// content is byte-identical afterward, and that any file which *did* make it through
    /// before cancellation landed is complete rather than truncated. The hfsutils backend only
    /// checks cancellation between files (each `hcopy` call always runs to completion — see
    /// `importHostItemRecursive`), so this is the granularity that actually applies here.
    func testCancellingHFSUtilsImportsDoesNotCorruptExistingVolumeContent() async throws {
        let fixture = URL(fileURLWithPath: "/Users/amuskens/Downloads/ PreInstalled MacOS Images/HD0-OpenRetroSCSI-7.1.hda")
        guard FileManager.default.fileExists(atPath: fixture.path) else {
            throw XCTSkip("Real HDA fixture not present on this machine")
        }

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("floppyfox-corruption-hfsutils-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let workingCopy = workDir.appendingPathComponent("working.hda")
        try FileManager.default.copyItem(at: fixture, to: workingCopy)

        let manager = DiskImageManager()
        await manager.attachImage(imageURL: workingCopy)
        addTeardownBlock { await manager.ejectImage() }
        XCTAssertNil(manager.errorMessage)
        XCTAssertTrue(manager.usingHFSUtils)

        guard let simpleText = manager.entries.first(where: { $0.name == "SimpleText" }) else {
            XCTFail("expected SimpleText in the fixture volume"); return
        }
        guard let baselineURL = await manager.materializeForPreview(simpleText) else {
            XCTFail("failed to extract baseline SimpleText"); return
        }
        let baselineContent = try Data(contentsOf: baselineURL)
        XCTAssertFalse(baselineContent.isEmpty)

        // A big enough batch that hfsutils's per-file hmount+hcopy+humount subprocess
        // overhead reliably keeps the whole thing running past the progress UI's 180ms
        // display delay (a smaller batch of 5 was found, empirically, to sometimes finish
        // *inside* that window — before `transferMessage` ever became observable — which made
        // polling for it hang until timeout and cancellation land too late to mean anything).
        let sources = (1...40).map { index -> (URL, String) in
            let name = "victim-\(index).txt"
            let url = workDir.appendingPathComponent(name)
            return (url, name)
        }
        for (url, name) in sources {
            try "content of \(name)".write(to: url, atomically: true, encoding: .utf8)
        }

        let importTask = Task { await manager.importFiles(urls: sources.map(\.0), destination: workDir) }
        // Poll the live per-item progress message — not `entries`, which for this backend
        // only refreshes once after the *entire* batch finishes, so waiting on it would
        // silently wait for completion and make the subsequent cancel a no-op — until any
        // per-item message becomes visible, then cancel right away. This backend only checks
        // cancellation between files (each `hcopy` call always runs to completion), so there's
        // no point racing any finer than that, and with 40 files still queued up the moment
        // the very first message appears, there's a wide margin before the batch would
        // otherwise finish on its own.
        let deadline = Date().addingTimeInterval(15)
        while manager.transferMessage == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        let messageAtCancelTime = manager.transferMessage
        XCTAssertNotNil(messageAtCancelTime, "expected the import to still be mid-batch before cancelling")
        manager.cancelActiveTransfer()
        await importTask.value
        let importedCount = sources.filter { _, name in manager.entries.contains(where: { $0.name == name }) }.count
        XCTAssertLessThan(importedCount, sources.count, "cancelling partway through a 40-file batch (caught at \"\(messageAtCancelTime ?? "nil")\") should leave some files un-imported — otherwise this didn't actually test a mid-batch cancel")

        guard let simpleTextAfter = manager.entries.first(where: { $0.name == "SimpleText" }),
              let afterURL = await manager.materializeForPreview(simpleTextAfter) else {
            XCTFail("failed to extract SimpleText after the cancelled import"); return
        }
        XCTAssertEqual(try Data(contentsOf: afterURL), baselineContent, "pre-existing volume content changed after a cancelled import")

        // Whatever DID land before cancellation must be complete, not truncated.
        for (source, name) in sources {
            guard let entry = manager.entries.first(where: { $0.name == name }) else { continue }
            guard let extracted = await manager.materializeForPreview(entry) else {
                XCTFail("failed to extract imported \(name)"); continue
            }
            XCTAssertEqual(try Data(contentsOf: extracted), try Data(contentsOf: source), "\(name) was imported but its content doesn't match the source — a truncated/corrupt write")
        }
    }

    /// Cancels a multi-file folder export (`materializeForPreview`, the same code path used by
    /// drag-out, Quick Look, and double-click-to-open) partway through, against a disposable
    /// *copy* of the real fixture, and confirms the source image is byte-for-byte unchanged —
    /// expected, since export only ever opens the source for reading, but verified here rather
    /// than just assumed. Cancels via native `Task.cancel()` rather than
    /// `cancelActiveTransfer()`, since `materializeForPreview`'s cancellation checks respond to
    /// `Task.isCancelled` directly when called with no `progressID`.
    func testCancellingHFSUtilsFolderExportDoesNotModifySourceImage() async throws {
        let fixture = URL(fileURLWithPath: "/Users/amuskens/Downloads/ PreInstalled MacOS Images/HD0-OpenRetroSCSI-7.1.hda")
        guard FileManager.default.fileExists(atPath: fixture.path) else {
            throw XCTSkip("Real HDA fixture not present on this machine")
        }

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("floppyfox-corruption-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let workingCopy = workDir.appendingPathComponent("working.hda")
        try FileManager.default.copyItem(at: fixture, to: workingCopy)
        let beforeDigest = try sha256(of: workingCopy)

        let manager = DiskImageManager()
        await manager.attachImage(imageURL: workingCopy)
        addTeardownBlock { await manager.ejectImage() }
        XCTAssertNil(manager.errorMessage)
        XCTAssertTrue(manager.usingHFSUtils)

        guard let systemFolder = manager.entries.first(where: { $0.name == "System Folder 7.1" && $0.isDirectory }) else {
            XCTFail("expected System Folder 7.1 in the fixture volume"); return
        }

        let materializeTask = Task { await manager.materializeForPreview(systemFolder) }
        // A System Folder has dozens of files, and hfsutils spawns three subprocesses
        // (hmount/hcopy/humount) per file, so this is comfortably still mid-export.
        try await Task.sleep(for: .milliseconds(150))
        materializeTask.cancel()
        let result = await materializeTask.value
        XCTAssertNil(result, "a cancelled materialize should not report a usable destination")

        // Attaching/reading during the export may have touched `~/.hcwd` and other hfsutils
        // bookkeeping state, but must never touch the image file's own bytes.
        let afterDigest = try sha256(of: workingCopy)
        XCTAssertEqual(beforeDigest, afterDigest, "the source image's bytes changed after a cancelled export — export must only ever read from it")
    }

    /// The "Eject" button stays enabled while a transfer is in progress (it's only disabled
    /// when nothing is mounted at all — see `ContentView.header`), and `ejectImage()`'s
    /// hfsutils branch calls `humount` directly rather than through
    /// `serializedHFSUtilsOperation`, unlike every other hmount/hcopy/hdel/humount call site in
    /// the file. Every one of those *other* call sites is deliberately serialized because
    /// hfsutils tracks "the current volume" as global state shared across every subprocess
    /// invocation, and interleaving two hmount/humount sequences is exactly the corruption mode
    /// the existing `hfsUtilsQueueTail` machinery was built to prevent. This reproduces the race
    /// for real: eject a real fixture copy while a large import batch is still mid-flight, then
    /// checks the volume is still readable and its pre-existing content is intact afterward.
    func testEjectingWhileImportInFlightDoesNotCorruptVolume() async throws {
        let fixtureName = "HD1 BlueSCSI Bootstrap.hda"
        let fixture = repoRootFixture(fixtureName)
        guard FileManager.default.fileExists(atPath: fixture.path) else {
            throw XCTSkip("Real fixture \(fixtureName) not present in the repo root on this machine")
        }
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("floppyfox-eject-race-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let workingCopy = workDir.appendingPathComponent(fixtureName)
        try FileManager.default.copyItem(at: fixture, to: workingCopy)

        let manager = DiskImageManager()
        await manager.attachImage(imageURL: workingCopy)
        XCTAssertNil(manager.errorMessage)
        XCTAssertTrue(manager.usingHFSUtils)

        guard let baselineEntry = manager.entries.first(where: { $0.name == "BlueSCSI Bootstrap Usage" }) else {
            XCTFail("expected the baseline file on the fixture"); return
        }
        guard let baselineURL = await manager.materializeForPreview(baselineEntry) else {
            XCTFail("failed to extract baseline file"); return
        }
        let baselineContent = try Data(contentsOf: baselineURL)

        let sources = (1...80).map { index -> URL in
            let url = workDir.appendingPathComponent("eject-race-\(index).txt")
            return url
        }
        for url in sources {
            try "payload".write(to: url, atomically: true, encoding: .utf8)
        }

        let importTask = Task { await manager.importFiles(urls: sources, destination: workDir) }
        // Each item runs a real hmount+hcopy+humount subprocess sequence (spawn/exec/wait, not
        // instant) inside the serialized hfsutils queue. Firing the eject the instant we see
        // *any* progress message — rather than after a fixed guess of a delay — reliably lands
        // it while some item's subprocess sequence is still actually running, which is the
        // real-world timing of a user clicking Eject partway through watching a big import.
        let deadline = Date().addingTimeInterval(30)
        while manager.transferMessage == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertNotNil(manager.transferMessage, "expected the import to still be in progress before ejecting")
        async let ejectResult: Void = manager.ejectImage()
        await importTask.value
        await ejectResult

        // Whatever the outcome (error, partial completion, clean cancellation), the volume
        // must still be intact: reattaching fresh must succeed, list correctly, and the
        // pre-existing baseline file must be byte-identical to before the race.
        let manager2 = DiskImageManager()
        await manager2.attachImage(imageURL: workingCopy)
        addTeardownBlock { await manager2.ejectImage() }
        XCTAssertNil(manager2.errorMessage, "volume failed to reattach after an eject raced against an in-flight import — possible corruption")
        XCTAssertFalse(manager2.entries.isEmpty, "volume listed no entries after the race — possible catalog corruption")
        guard let baselineAfter = manager2.entries.first(where: { $0.name == "BlueSCSI Bootstrap Usage" }),
              let afterURL = await manager2.materializeForPreview(baselineAfter) else {
            XCTFail("failed to extract baseline file after the race"); return
        }
        XCTAssertEqual(try Data(contentsOf: afterURL), baselineContent, "pre-existing content damaged after an eject raced against an in-flight import")
    }

    /// `importFiles` must refresh `entries` after *any* early exit from its per-item loop, not
    /// just a full success. Found while corruption-testing against the real
    /// "HD1 BlueSCSI Bootstrap.hda" fixture: cancelling a multi-file import partway through
    /// `return`ed immediately without calling `refresh()`, so files that had genuinely already
    /// landed on disk stayed invisible in the browser — a real-vs-displayed state mismatch
    /// that could plausibly cause a later import of the same name to fail with a confusing
    /// "already exists" error for a file the user can't even see. The same bug applied to a
    /// genuine per-item error mid-batch, not just cancellation.
    func testImportRefreshesEntriesAfterCancellationEvenWithPartialProgress() async throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("floppyfox-import-refresh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let imageURL = workDir.appendingPathComponent("refresh.dmg")
        let create = Process()
        create.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        create.arguments = ["create", "-size", "200m", "-fs", "HFS+", "-volname", "FloppyFoxRefreshTest", imageURL.path]
        create.standardOutput = Pipe()
        create.standardError = Pipe()
        try create.run()
        create.waitUntilExit()
        guard create.terminationStatus == 0 else {
            throw XCTSkip("hdiutil create is unavailable in this environment")
        }

        let manager = DiskImageManager()
        await manager.attachImage(imageURL: imageURL)
        addTeardownBlock { await manager.ejectImage() }
        XCTAssertNil(manager.errorMessage)
        guard let mountPoint = manager.mountPoint else {
            XCTFail("expected a mount point once attached"); return
        }

        // A small file (completes essentially instantly) followed by a large one (still
        // mid-copy when we cancel a few milliseconds in) — the small one must show up in
        // `entries` immediately after `importFiles` returns, with no extra manual refresh.
        let smallFile = workDir.appendingPathComponent("landed-before-cancel.txt")
        try "this should be visible".write(to: smallFile, atomically: true, encoding: .utf8)
        let bigFile = workDir.appendingPathComponent("still-copying-when-cancelled.bin")
        try Data(repeating: 0x33, count: 150 * 1024 * 1024).write(to: bigFile)

        let importTask = Task { await manager.importFiles(urls: [smallFile, bigFile], destination: mountPoint) }
        try await Task.sleep(for: .milliseconds(5))
        manager.cancelActiveTransfer()
        await importTask.value

        XCTAssertEqual(manager.statusMessage, "Import cancelled")
        XCTAssertTrue(
            manager.entries.contains(where: { $0.name == "landed-before-cancel.txt" }),
            "a file that successfully landed before cancellation should be visible in `entries` immediately, without a separate manual refresh"
        )
        XCTAssertFalse(manager.entries.contains(where: { $0.name == "still-copying-when-cancelled.bin" }))
    }

    /// A real disk-full write failure — not a cancellation — partway through a chunked copy
    /// must be cleaned up exactly like a cancelled one. Found empirically while testing
    /// `copyFileChunked`: the original implementation only removed the partial destination
    /// file on the cancellation path, leaving a truncated file with a plausible-looking size
    /// behind on any other I/O failure (a full volume, a source read error, ...) — which is
    /// arguably worse than the cancel bug, since nothing in the UI would ever call attention
    /// to it. Uses a real, deliberately tiny HFS+ volume to trigger a genuine ENOSPC from the
    /// filesystem rather than mocking the error.
    func testWriteFailureMidCopyCleansUpPartialFileAndLeavesVolumeUsable() async throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("floppyfox-diskfull-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let imageURL = workDir.appendingPathComponent("tiny.dmg")
        let create = Process()
        create.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        create.arguments = ["create", "-size", "20m", "-fs", "HFS+", "-volname", "FloppyFoxDiskFullTest", imageURL.path]
        create.standardOutput = Pipe()
        create.standardError = Pipe()
        try create.run()
        create.waitUntilExit()
        guard create.terminationStatus == 0 else {
            throw XCTSkip("hdiutil create is unavailable in this environment")
        }

        let manager = DiskImageManager()
        await manager.attachImage(imageURL: imageURL)
        addTeardownBlock { await manager.ejectImage() }
        XCTAssertNil(manager.errorMessage)
        XCTAssertTrue(manager.isMounted)
        guard let mountPoint = manager.mountPoint else {
            XCTFail("expected a mount point once attached"); return
        }

        // A baseline file that must survive the failed import untouched, same as the
        // cancellation tests — a write failure shouldn't damage anything already on the
        // volume any more than a cancellation should.
        let canaryPayload = Data("still here after the volume fills up".utf8)
        let canaryURL = workDir.appendingPathComponent("canary.txt")
        try canaryPayload.write(to: canaryURL)
        await manager.importFiles(urls: [canaryURL], destination: mountPoint)
        XCTAssertNil(manager.errorMessage)

        // 60MB into a ~20MB volume guarantees ENOSPC partway through, not a clean rejection
        // up front.
        let tooBigURL = workDir.appendingPathComponent("toobig.bin")
        try Data(repeating: 0x41, count: 60 * 1024 * 1024).write(to: tooBigURL)
        await manager.importFiles(urls: [tooBigURL], destination: mountPoint)

        XCTAssertNotNil(manager.errorMessage, "expected an error once the volume ran out of space")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: mountPoint.appendingPathComponent("toobig.bin").path),
            "a failed import should not leave a truncated partial file on the volume"
        )
        XCTAssertEqual(try Data(contentsOf: mountPoint.appendingPathComponent("canary.txt")), canaryPayload, "pre-existing content should be untouched by the failed import")

        // The volume must still be genuinely usable afterward — this was a write failure, not
        // a crash, so nothing should be left wedged.
        try assertVolumeVerifies(at: mountPoint)
        let smallFollowUp = workDir.appendingPathComponent("after.txt")
        try "still works after running out of space".write(to: smallFollowUp, atomically: true, encoding: .utf8)
        await manager.importFiles(urls: [smallFollowUp], destination: mountPoint)
        XCTAssertNil(manager.errorMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mountPoint.appendingPathComponent("after.txt").path))
    }

    /// Smoke test confirming all four real period-accurate fixtures still open cleanly — a
    /// regression here would mean something in attach/hfsutils-detection broke for real-world
    /// images, as opposed to the synthetic ones the other tests build with `hdiutil create`.
    func testRealFixturesAllOpenSuccessfully() async throws {
        for name in Self.realFixtureNames {
            let url = repoRootFixture(name)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw XCTSkip("Real fixture \(name) not present in the repo root on this machine")
            }
            let manager = DiskImageManager()
            await manager.attachImage(imageURL: url)
            addTeardownBlock { await manager.ejectImage() }
            XCTAssertNil(manager.errorMessage, "\(name) failed to attach: \(manager.errorMessage ?? "")")
            XCTAssertFalse(manager.entries.isEmpty, "\(name) attached but listed no entries")
        }
    }

    private static let realFixtureNames = [
        "HD1 BlueSCSI Bootstrap.hda",
        "StuffIt Deluxe 3.0.7 Disk 1.dsk",
        "StuffIt Deluxe 3.0.7 Disk 2.dsk",
        "boot.vhd",
    ]

    /// The StuffIt Deluxe floppy fixtures ship almost completely full (a handful of KB free on
    /// an 800K disk) — a perfect real-world trigger for a volume-full write failure, rather
    /// than the synthetic near-empty volume `testWriteFailureMidCopyCleansUpPartialFileAndLeavesVolumeUsable`
    /// used. Confirms hfsutils's `hcopy` failing partway (or refusing up front) doesn't corrupt
    /// the existing installer file already on the disk, and that the volume is still usable
    /// afterward.
    func testNearlyFullFloppyRejectsOversizedImportWithoutCorruption() async throws {
        let fixtureName = "StuffIt Deluxe 3.0.7 Disk 1.dsk"
        let fixture = repoRootFixture(fixtureName)
        guard FileManager.default.fileExists(atPath: fixture.path) else {
            throw XCTSkip("Real fixture \(fixtureName) not present in the repo root on this machine")
        }
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("floppyfox-realfixture-full-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let workingCopy = workDir.appendingPathComponent(fixtureName)
        try FileManager.default.copyItem(at: fixture, to: workingCopy)

        let manager = DiskImageManager()
        await manager.attachImage(imageURL: workingCopy)
        addTeardownBlock { await manager.ejectImage() }
        XCTAssertNil(manager.errorMessage)
        XCTAssertTrue(manager.usingHFSUtils)

        guard let installer = manager.entries.first(where: { $0.name.contains("Installer") }) else {
            XCTFail("expected the StuffIt installer file on the fixture floppy"); return
        }
        guard let baselineURL = await manager.materializeForPreview(installer) else {
            XCTFail("failed to extract baseline installer file"); return
        }
        let baselineContent = try Data(contentsOf: baselineURL)
        XCTAssertFalse(baselineContent.isEmpty)
        let baselineEntryCount = manager.entries.count

        // The fixture ships with only a few KB free — anything beyond a trivial file exceeds
        // capacity.
        let oversizedURL = workDir.appendingPathComponent("toobig.bin")
        try Data(repeating: 0x99, count: 512 * 1024).write(to: oversizedURL)
        await manager.importFiles(urls: [oversizedURL], destination: workDir)
        XCTAssertNotNil(manager.errorMessage, "expected an error importing a 512KB file onto a floppy with only a few KB free")

        // The pre-existing installer must be untouched, and the volume must not have gained a
        // corrupt/incomplete "toobig.bin" catalog entry.
        guard let installerAfter = manager.entries.first(where: { $0.name.contains("Installer") }),
              let afterURL = await manager.materializeForPreview(installerAfter) else {
            XCTFail("failed to extract the installer file after the failed import"); return
        }
        XCTAssertEqual(try Data(contentsOf: afterURL), baselineContent, "pre-existing installer content changed after a failed (volume-full) import")
        XCTAssertFalse(manager.entries.contains(where: { $0.name.hasPrefix("toobig") }), "a failed import should not leave a partial catalog entry behind")
        XCTAssertEqual(manager.entries.count, baselineEntryCount, "entry count changed even though the import should have failed cleanly")

        // Confirm the volume is still genuinely usable — not left wedged by the failed write —
        // by attempting to import something that actually fits.
        let tinyURL = workDir.appendingPathComponent("tiny.txt")
        try "ok".write(to: tinyURL, atomically: true, encoding: .utf8)
        await manager.importFiles(urls: [tinyURL], destination: workDir)
        // Even a trivial file may still not fit in a few KB once catalog overhead is
        // accounted for — what matters is that the outcome is either a clean success or a
        // clean, non-corrupting failure, never silent damage. Either way the installer must
        // still be intact.
        guard let installerFinal = manager.entries.first(where: { $0.name.contains("Installer") }),
              let finalURL = await manager.materializeForPreview(installerFinal) else {
            XCTFail("installer file disappeared entirely after further use of a full volume"); return
        }
        XCTAssertEqual(try Data(contentsOf: finalURL), baselineContent, "installer content damaged after further activity on the full volume")
    }

    /// Cancels mid-batch imports and a mid-folder export against a disposable copy of the real
    /// "HD1 BlueSCSI Bootstrap.hda" fixture (a real multi-folder BlueSCSI installer disk, ~512MB)
    /// and confirms nothing on the volume was damaged — the same shape of test as the earlier
    /// OpenRetroSCSI-based corruption tests, but against a different, independently-sourced real
    /// image to widen coverage.
    func testHD1BlueSCSIBootstrapSurvivesCancelledTransfers() async throws {
        try await assertRealFixtureSurvivesCancelledTransfers(
            fixtureName: "HD1 BlueSCSI Bootstrap.hda",
            baselineFileName: "BlueSCSI Bootstrap Usage",
            exportFolderName: "Fresh OS Installs"
        )
    }

    /// Same treatment as `testHD1BlueSCSIBootstrapSurvivesCancelledTransfers`, but for the real
    /// "boot.vhd" fixture — a genuine multi-System-Folder bootable Mac hard disk (~1.6GB), and
    /// notably a `.vhd`-named file that (verified in `testRealFixturesAllOpenSuccessfully`'s
    /// setup) has no actual VHD container footer, exercising `VHDImage`'s raw-passthrough path
    /// with real data rather than only the synthetic fixture in `testTreatsNonContainerVHDAsRawImage`.
    func testBootVHDSurvivesCancelledTransfers() async throws {
        try await assertRealFixtureSurvivesCancelledTransfers(
            fixtureName: "boot.vhd",
            baselineFileName: "MacPack ReadMe",
            exportFolderName: "System 6.0.5"
        )
    }

    private func assertRealFixtureSurvivesCancelledTransfers(
        fixtureName: String,
        baselineFileName: String,
        exportFolderName: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let fixture = repoRootFixture(fixtureName)
        guard FileManager.default.fileExists(atPath: fixture.path) else {
            throw XCTSkip("Real fixture \(fixtureName) not present in the repo root on this machine")
        }
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("floppyfox-realfixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let workingCopy = workDir.appendingPathComponent(fixtureName)
        try FileManager.default.copyItem(at: fixture, to: workingCopy)

        let manager = DiskImageManager()
        await manager.attachImage(imageURL: workingCopy)
        addTeardownBlock { await manager.ejectImage() }
        XCTAssertNil(manager.errorMessage, file: file, line: line)
        XCTAssertTrue(manager.usingHFSUtils, file: file, line: line)
        let baselineEntryNames = Set(manager.entries.map(\.name))

        guard let baselineEntry = manager.entries.first(where: { $0.name == baselineFileName }) else {
            XCTFail("expected \(baselineFileName) on \(fixtureName)", file: file, line: line); return
        }
        guard let baselineURL = await manager.materializeForPreview(baselineEntry) else {
            XCTFail("failed to extract baseline \(baselineFileName)", file: file, line: line); return
        }
        let baselineContent = try Data(contentsOf: baselineURL)
        XCTAssertFalse(baselineContent.isEmpty, file: file, line: line)

        // 1) Cancel mid-batch import (per-file granularity — see importHostItemRecursive) and
        // confirm the pre-existing baseline file is untouched, and whatever did land is intact.
        let sources = (1...40).map { index -> (URL, String) in
            let name = "corruption-probe-\(index).txt"
            return (workDir.appendingPathComponent(name), name)
        }
        for (url, name) in sources {
            try "content of \(name)".write(to: url, atomically: true, encoding: .utf8)
        }
        let importTask = Task { await manager.importFiles(urls: sources.map(\.0), destination: workDir) }
        let importDeadline = Date().addingTimeInterval(30)
        while manager.transferMessage == nil, Date() < importDeadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertNotNil(manager.transferMessage, "expected the import to still be mid-batch before cancelling", file: file, line: line)
        manager.cancelActiveTransfer()
        await importTask.value

        guard let baselineAfterImport = manager.entries.first(where: { $0.name == baselineFileName }),
              let afterImportURL = await manager.materializeForPreview(baselineAfterImport) else {
            XCTFail("failed to extract \(baselineFileName) after the cancelled import", file: file, line: line); return
        }
        XCTAssertEqual(try Data(contentsOf: afterImportURL), baselineContent, "pre-existing content changed after a cancelled import", file: file, line: line)
        for (source, name) in sources {
            guard let entry = manager.entries.first(where: { $0.name == name }) else { continue }
            guard let extracted = await manager.materializeForPreview(entry) else {
                XCTFail("failed to extract imported \(name)", file: file, line: line); continue
            }
            XCTAssertEqual(try Data(contentsOf: extracted), try Data(contentsOf: source), "\(name) landed but its content doesn't match — truncated/corrupt write", file: file, line: line)
        }
        // Clean up whatever DID land, so the export test below starts from the original entry
        // set and the entry-count check at the end is meaningful.
        let landedProbes = manager.entries.filter { $0.name.hasPrefix("corruption-probe-") }
        if !landedProbes.isEmpty {
            await manager.deleteEntries(landedProbes)
            XCTAssertNil(manager.errorMessage, file: file, line: line)
        }

        // 2) Cancel a multi-file folder export/materialize partway through (native Task
        // cancellation — see the equivalent OpenRetroSCSI-based export test for why this
        // doesn't need progressID/beginTransfer) and confirm the source image's bytes never
        // changed, since export only ever reads from it.
        let beforeExportDigest = try sha256(of: workingCopy)
        guard let exportFolder = manager.entries.first(where: { $0.name == exportFolderName && $0.isDirectory }) else {
            XCTFail("expected folder \(exportFolderName) on \(fixtureName)", file: file, line: line); return
        }
        let materializeTask = Task { await manager.materializeForPreview(exportFolder) }
        try await Task.sleep(for: .milliseconds(150))
        materializeTask.cancel()
        _ = await materializeTask.value
        let afterExportDigest = try sha256(of: workingCopy)
        XCTAssertEqual(beforeExportDigest, afterExportDigest, "source image bytes changed after a cancelled export", file: file, line: line)

        // 3) Full cold round-trip: eject and reattach fresh, confirming the volume's directory
        // listing and baseline content are unchanged from where we started.
        await manager.ejectImage()
        let manager2 = DiskImageManager()
        await manager2.attachImage(imageURL: workingCopy)
        addTeardownBlock { await manager2.ejectImage() }
        XCTAssertNil(manager2.errorMessage, file: file, line: line)
        XCTAssertEqual(Set(manager2.entries.map(\.name)), baselineEntryNames, "top-level entry set changed after cancelled transfers and a cold reattach", file: file, line: line)
        guard let baselineFinal = manager2.entries.first(where: { $0.name == baselineFileName }),
              let finalURL = await manager2.materializeForPreview(baselineFinal) else {
            XCTFail("failed to extract \(baselineFileName) after reattaching", file: file, line: line); return
        }
        XCTAssertEqual(try Data(contentsOf: finalURL), baselineContent, "baseline content changed after a cold reattach", file: file, line: line)
    }
}

/// The real, period-accurate fixture images the user placed at the repo root for corruption
/// testing — gitignored (see `.gitignore`'s `*.hda`/`*.dsk`/`*.vhd`/`*.img` rules) so they're
/// never committed. Resolved relative to this source file rather than hardcoded to a specific
/// checkout path.
private func repoRootFixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent(name)
}

/// Shells out to `diskutil verifyVolume`, which unmounts, runs `fsck_hfs`, and remounts a
/// modern HFS+/APFS volume — the same check Disk Utility's "First Aid" performs. Used to
/// verify at the filesystem level (not just "expected files are present") that a mounted
/// volume survived cancelled transfers undamaged.
private func assertVolumeVerifies(at mountPoint: URL, file: StaticString = #filePath, line: UInt = #line) throws {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
    proc.arguments = ["verifyVolume", mountPoint.path]
    let outPipe = Pipe()
    proc.standardOutput = outPipe
    proc.standardError = outPipe
    try proc.run()
    proc.waitUntilExit()
    let output = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    XCTAssertEqual(proc.terminationStatus, 0, "diskutil verifyVolume reported a problem:\n\(output)", file: file, line: line)
}

private func sha256(of url: URL) throws -> String {
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
}

/// Lock-guarded counter for use inside `@Sendable` `shouldCancel` closures in tests, which
/// `copyFileChunked` always calls one at a time (never concurrently), so a simple lock is
/// enough to satisfy the compiler without needing real concurrent-access handling.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    @discardableResult
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
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
