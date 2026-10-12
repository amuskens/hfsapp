import XCTest
@testable import FloppyFox

/// Regression tests for the findings of the second independent review (commit-protocol
/// edge cases and HFS Plus details).
final class ReviewFindingsTests: XCTestCase {
    private var work: URL!

    override func setUp() async throws {
        guard Fixtures.hfsutilsPrefix != nil else { throw XCTSkip("hfsutils (brew install hfsutils) is required as a test oracle") }
        work = try Fixtures.makeWorkDirectory("review")
    }

    override func tearDown() async throws {
        if let work, ProcessInfo.processInfo.environment["FLOPPYFOX_KEEP_TEST_IMAGES"] == nil { try? FileManager.default.removeItem(at: work) }
    }

    private func openHFS(_ url: URL, faults: WriteFaultInjector? = nil, allowUnclean: Bool = false) throws -> HFSVolume {
        let location = try XCTUnwrap(DiskImageLayout.volumes(in: url).first)
        return try HFSVolume(device: try BlockDevice(url: url, offset: location.offset, length: location.length, writable: true, faults: faults), allowUncleanVolume: allowUnclean)
    }

    private func openHFSPlus(_ url: URL, faults: WriteFaultInjector? = nil, readOnly: Bool = false) throws -> HFSPlusVolume {
        let location = try XCTUnwrap(DiskImageLayout.volumes(in: url).first)
        return try HFSPlusVolume(device: try BlockDevice(url: url, offset: location.offset, length: location.length, writable: !readOnly, faults: faults),
                                 forcedReadOnly: readOnly ? .requested : nil)
    }

    /// Fills a floppy through the engine until it refuses more data.
    private func fillThroughEngine(_ volume: HFSVolume) async throws {
        var index = 0
        while true {
            do {
                try await volume.createFile(named: "fill \(index)", in: HFSCatalogID.rootFolder, type: [], creator: [],
                                            dataFork: HFSForkSource(bytes: [UInt8](repeating: 9, count: 8 * 1024)), resourceFork: .empty)
            } catch HFSError.volumeFull {
                break
            }
            index += 1
            if index % 20 == 0 { try await volume.flush() }
        }
        try await volume.flush()
    }

    // MARK: Finding 1 — HFS+ spare header

    /// A partition that isn't a whole number of blocks keeps its spare volume header at the
    /// partition's end. It must be kept current, or a Disk Utility repair (which trusts it)
    /// throws away everything the app wrote.
    func testSpareVolumeHeaderOnAPartitionThatIsNotAWholeNumberOfBlocks() async throws {
        let image = try HFSPlusFixtures.makeVolume(in: work, sizeMB: 40, extraBytes: 1536)
        do {
            let volume = try openHFSPlus(image)
            for i in 0..<300 { try await volume.createFolder(named: "Folder \(i)", in: HFSCatalogID.rootFolder) }
            try await volume.flush()
            await volume.close()
        }
        let bytes = Array(try Data(contentsOf: image))
        let primary = Array(bytes[1024..<1536])
        let spare = Array(bytes[(bytes.count / 512 * 512 - 1024)..<(bytes.count / 512 * 512 - 512)])
        XCTAssertEqual(spare, primary, "the spare header at the partition end wasn't updated")
        let verdict = try Fixtures.fsck(image)
        XCTAssertTrue(verdict.clean, verdict.output)

        // And what Disk Utility would do: repair from it, then mount.
        let repaired = work.appendingPathComponent("repaired.img")
        try FileManager.default.copyItem(at: image, to: repaired)
        _ = try Fixtures.fsckRepair(repaired)
        try HFSPlusFixtures.withMounted(repaired) { root in
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("Folder") }.count, 300)
        }
    }

    // MARK: Finding 2 — no in-place rewrite from the app's own use

    /// Filling a floppy through the app keeps enough room for a safe save, so even a full
    /// floppy commits by copy — every interrupted save leaves the old or the new volume.
    func testAFloppyFilledByTheAppStillSavesSafely() async throws {
        let template = try Fixtures.makeClassicHFSImage(in: work, name: "full.dsk")
        do {
            let volume = try openHFS(template)
            try await fillThroughEngine(volume)
            await volume.close()
        }
        let original = Set(try await names(template))
        func edit(_ volume: HFSVolume) async throws {
            try await volume.createFolder(named: "Added", in: HFSCatalogID.rootFolder)
            try await volume.delete(try await childItem(volume, "fill 0", in: HFSCatalogID.rootFolder).id)
        }
        let expected = original.subtracting(["fill 0"]).union(["Added"])

        let probe = work.appendingPathComponent("probe.dsk")
        try FileManager.default.copyItem(at: template, to: probe)
        let counter = WriteFaultInjector()
        let dry = try openHFS(probe, faults: counter)
        try await edit(dry)
        counter.failAfter(nil)
        try await dry.flush()
        let total = counter.writesSeen
        await dry.close()

        for cut in 0...total {
            let image = work.appendingPathComponent("cut-\(cut).dsk")
            try FileManager.default.copyItem(at: template, to: image)
            let faults = WriteFaultInjector()
            let volume = try openHFS(image, faults: faults)
            try await edit(volume)
            faults.failAfter(cut)
            let succeeded = (try? await volume.flush()) != nil
            await volume.close()
            let state = Set(try await names(image))
            XCTAssertTrue(state == original || state == expected, "cut after \(cut) of \(total): neither old nor new state")
            if state == expected { XCTAssertTrue(succeeded, "cut after \(cut): saved, but reported as failed") }
            if state == original { XCTAssertFalse(succeeded, "cut after \(cut): reported saved, but isn't") }
            try await assertCleanOrRepairsToKnownState(image, oneOf: [original, expected], context: "cut after \(cut) of \(total)")
        }
    }

    /// A volume another system filled has no room for a copy, so the trees are rewritten in
    /// place. If that is interrupted the engine must not pretend it rolled back.
    func testAnInterruptedInPlaceSaveIsReportedAndBlocksFurtherWrites() async throws {
        let image = try Fixtures.makeClassicHFSImage(in: work)
        try Fixtures.withMounted(image) {
            let free = Int(try Fixtures.hfs("hvol", []).split(separator: "\n").first { $0.contains("bytes free") }?.split(separator: " ").dropFirst(2).first ?? "0") ?? 0
            try Fixtures.putFile(Data(count: max(0, free - 512)), at: ":Filler", scratch: work)
        }
        let faults = WriteFaultInjector()
        let volume = try openHFS(image, faults: faults)
        try await volume.createFolder(named: "Squeezed In", in: HFSCatalogID.rootFolder)
        faults.failAfter(3) // past the in-use header and bitmap, into the tree rewrite
        do {
            try await volume.flush()
            XCTFail("expected the save to fail")
        } catch HFSError.saveIncomplete {
        } catch {
            XCTFail("expected saveIncomplete, got \(error)")
        }
        faults.failAfter(nil)
        await XCTAssertThrowsErrorAsync { try await volume.createFolder(named: "More", in: HFSCatalogID.rootFolder) }
        await volume.close()
    }

    // MARK: Finding 3 — HFSX folder counts

    func testNestedFoldersOnCaseSensitiveHFSXPassFsck() async throws {
        let image = try HFSPlusFixtures.makeVolume(in: work, caseSensitive: true)
        do {
            let volume = try openHFSPlus(image)
            let outer = try await volume.createFolder(named: "Outer", in: HFSCatalogID.rootFolder)
            let inner = try await volume.createFolder(named: "Inner", in: outer)
            try await volume.createFolder(named: "Innermost", in: inner)
            try await volume.flush()
            await volume.close()
        }
        let verdict = try Fixtures.fsck(image)
        XCTAssertTrue(verdict.clean, verdict.output)
    }

    // MARK: Finding 4 — extents past the volume

    func testAnExtentPastTheEndOfTheVolumeIsRejectedAtOpen() async throws {
        let image = try Fixtures.makeClassicHFSImage(in: work)
        do {
            let volume = try openHFS(image)
            try await volume.createFile(named: "Victim", in: HFSCatalogID.rootFolder, type: [], creator: [], dataFork: HFSForkSource(bytes: [1, 2, 3]), resourceFork: .empty)
            try await volume.flush()
            await volume.close()
        }
        var bytes = Array(try Data(contentsOf: image))
        let key: [UInt8] = [12, 0, 0, 0, 0, 2, 6] + Array("Victim".utf8) // keyLength 6+6, parent 2
        let position = try XCTUnwrap((0..<(bytes.count - key.count)).first { Array(bytes[$0..<($0 + key.count)]) == key })
        let dataStart = position + 1 + 12 + 1 // key, then pad to even
        bytes.put16(0xFFF0, at: dataStart + 74) // first data extent's start block
        let damaged = work.appendingPathComponent("damaged.dsk")
        try Data(bytes).write(to: damaged)
        XCTAssertThrowsError(try openHFS(damaged))
    }

    // MARK: Finding 5 — a failed save keeps the volume clean

    func testASaveThatFailsForLackOfSpaceLeavesTheVolumeMarkedClean() async throws {
        let image = try Fixtures.makeClassicHFSImage(in: work)
        do {
            let volume = try openHFS(image)
            try await fillThroughEngine(volume)
            // Far more catalog growth than the reserve covers.
            for i in 0..<1500 { try await volume.createFolder(named: "Too many \(i)", in: HFSCatalogID.rootFolder) }
            await XCTAssertThrowsErrorAsync { try await volume.flush() }
            await volume.close()
        }
        let reopened = try openHFS(image)
        XCTAssertNil(reopened.readOnlyCause, "a failed save must not leave the volume looking unejected")
        await reopened.close()
        XCTAssertTrue(try Fixtures.fsck(image).clean)
    }

    // MARK: Finding 8 — Unicode names

    func testUnicodeNamesTheKernelMustFindAndTheAppMustLookUp() async throws {
        let image = try HFSPlusFixtures.makeVolume(in: work)
        // é with an enclosing circle (U+20DD, in an excluded range), ANGSTROM SIGN (a
        // singleton), and a CJK compatibility ideograph (excluded from decomposition).
        let names = ["caf\u{E9}\u{20DD}", "\u{212B}ngstr\u{F6}m", "\u{F900} kanji"]
        do {
            let volume = try openHFSPlus(image)
            for name in names {
                try await volume.createFile(named: name, in: HFSCatalogID.rootFolder, type: [], creator: [], dataFork: HFSForkSource(bytes: Array(name.utf8)), resourceFork: .empty)
            }
            try await volume.flush()
            for item in try await volume.contents(ofFolder: HFSCatalogID.rootFolder) {
                let found = await volume.child(named: item.name, inFolder: HFSCatalogID.rootFolder)
                XCTAssertEqual(found?.id, item.id, "the displayed name \(item.name.debugDescription) doesn't find its own item")
            }
            await volume.close()
        }
        XCTAssertTrue(try Fixtures.fsck(image).clean)
        try HFSPlusFixtures.withMounted(image) { root in
            for name in names {
                let data = FileManager.default.contents(atPath: root.appendingPathComponent(name).path)
                XCTAssertEqual(data.map { String(decoding: $0, as: UTF8.self) }, name, "macOS can't open \(name.debugDescription)")
            }
        }
    }

    private func names(_ image: URL) async throws -> [String] {
        let volume = try DiskImageLayout.openVolume(image, readOnly: true)
        let names = try await volume.contents(ofFolder: HFSCatalogID.rootFolder).map(\.name)
        await volume.close()
        return names
    }
}
