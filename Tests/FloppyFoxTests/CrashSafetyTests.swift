import XCTest
@testable import FloppyFox

/// Failure-mode tests for the engines' commit protocol and their defenses, built from the
/// findings of an independent review: interrupted flushes, reuse of freed blocks, catalogs
/// that outgrow their file in fragmented space, hostile images, and other writers.
final class CrashSafetyTests: XCTestCase {
    private var work: URL!

    override func setUp() async throws {
        guard Fixtures.hfsutilsPrefix != nil else { throw XCTSkip("hfsutils (brew install hfsutils) is required as a test oracle") }
        work = try Fixtures.makeWorkDirectory("crash")
    }

    override func tearDown() async throws {
        if let work, ProcessInfo.processInfo.environment["FLOPPYFOX_KEEP_TEST_IMAGES"] == nil { try? FileManager.default.removeItem(at: work) }
    }

    private func open(_ url: URL, faults: WriteFaultInjector? = nil, allowUnclean: Bool = false) throws -> HFSVolume {
        let location = try XCTUnwrap(DiskImageLayout.volumes(in: url).first)
        let device = try BlockDevice(url: url, offset: location.offset, length: location.length, writable: true, faults: faults)
        return try HFSVolume(device: device, allowUncleanVolume: allowUnclean)
    }

    private func names(_ volume: HFSVolume, in folder: UInt32 = HFSCatalogID.rootFolder) async throws -> Set<String> {
        Set(try await volume.contents(ofFolder: folder).map(\.name))
    }

    /// fsck output problems that only mean "blocks are marked in use that nothing
    /// references" — the expected residue of a commit interrupted between its bitmap and
    /// header writes. Anything else is damage.
    private func assertOnlyOrphanedBlocks(_ image: URL, context: String = "", file: StaticString = #filePath, line: UInt = #line) async throws {
        let verdict = try Fixtures.fsck(image)
        if verdict.clean { return }
        // Between the primary and spare MDB writes the spare is one commit behind; when fsck
        // also has orphaned blocks to repair it then flags the folder/file counts. That's only
        // harmless if the *primary* MDB's counts really match the catalog, so check that here.
        let primaryCountsCorrect = try await primaryMDBCountsMatchCatalog(image)
        var harmless = ["orphaned blocks", "Invalid volume free block count", "Checking", "Executing fsck_hfs", "volume name is",
                        "Verify Status", "CBTStat", "found corrupt and needs to be repaired", "CheckHFS returned", "NO WRITE",
                        "Can't open", "cacheBlockSize", "volume type", "MDB is at", "VHB is at", "sector size", "VolumeObject",
                        "total sectors", "(", "Volume bitmap needs minor repair"]
        if primaryCountsCorrect {
            harmless += ["Master Directory Block needs minor repair", "invalid MDB drNmRtDirs", "invalid MDB drDirCnt", "invalid MDB drNmFls", "invalid MDB drFilCnt"]
        }
        let problems = verdict.output.split(separator: "\n").map(String.init).filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !harmless.contains { trimmed.contains($0) }
        }
        XCTAssertTrue(problems.isEmpty, "\(context) fsck found damage beyond orphaned blocks:\n\(verdict.output)", file: file, line: line)
    }

    private func primaryMDBCountsMatchCatalog(_ image: URL) async throws -> Bool {
        let bytes = Array(try Data(contentsOf: image))
        let rootFiles = Int(try bytes.u16(1024 + 12)), rootDirs = Int(try bytes.u16(1024 + 82))
        let files = Int(try bytes.u32(1024 + 84)), dirs = Int(try bytes.u32(1024 + 88))
        let volume = try open(image, allowUnclean: true)
        var countedFiles = 0, countedDirs = 0
        var pending: [UInt32] = [HFSCatalogID.rootFolder]
        while let folder = pending.popLast() {
            for item in try await volume.contents(ofFolder: folder) {
                if item.isFolder { countedDirs += 1; pending.append(item.id) } else { countedFiles += 1 }
            }
        }
        let root = try await volume.contents(ofFolder: HFSCatalogID.rootFolder)
        await volume.close()
        return rootFiles == root.filter { !$0.isFolder }.count && rootDirs == root.filter(\.isFolder).count
            && files == countedFiles && dirs == countedDirs
    }

    // MARK: Commit protocol

    /// Cuts the power (stops all writes) after every possible number of writes during a
    /// flush. Whatever was on disk at that moment must open as either the old volume or the
    /// new one, with the right file contents, and nothing worse than orphaned blocks.
    func testFlushInterruptedAtEveryWriteLeavesTheOldOrTheNewVolume() async throws {
        let template = try Fixtures.makeClassicHFSImage(in: work, name: "template.dsk")
        do {
            let volume = try open(template)
            for i in 0..<20 {
                try await volume.createFile(named: "file \(i)", in: HFSCatalogID.rootFolder, type: Array("TEXT".utf8), creator: Array("ttxt".utf8),
                                            dataFork: HFSForkSource(bytes: Array("contents \(i)".utf8)), resourceFork: .empty)
            }
            try await volume.flush()
            await volume.close()
        }
        let oldNames = Set((0..<20).map { "file \($0)" })
        let newNames = oldNames.subtracting(["file 3", "file 4"]).union(["New Folder", "New File"])
        let newData = [UInt8]((0..<3000).map { UInt8(truncatingIfNeeded: $0) })

        func runEdits(_ volume: HFSVolume) async throws {
            let folder = try await volume.createFolder(named: "New Folder", in: HFSCatalogID.rootFolder)
            try await volume.createFile(named: "New File", in: HFSCatalogID.rootFolder, type: Array("TEXT".utf8), creator: Array("ttxt".utf8),
                                        dataFork: HFSForkSource(bytes: newData), resourceFork: .empty)
            let root = try await volume.contents(ofFolder: HFSCatalogID.rootFolder)
            try await volume.delete(try XCTUnwrap(root.first { $0.name == "file 3" }).id)
            try await volume.move(try XCTUnwrap(root.first { $0.name == "file 4" }).id, to: folder)
        }

        // Dry run: how many writes does this flush make?
        let probe = work.appendingPathComponent("probe.dsk")
        try FileManager.default.copyItem(at: template, to: probe)
        let counter = WriteFaultInjector()
        let dry = try open(probe, faults: counter)
        try await runEdits(dry)
        counter.failAfter(nil)
        try await dry.flush()
        let totalWrites = counter.writesSeen
        await dry.close()
        XCTAssertGreaterThan(totalWrites, 5)

        var sawOld = false, sawNew = false
        for cut in 0...totalWrites {
            let image = work.appendingPathComponent("cut-\(cut).dsk")
            try FileManager.default.copyItem(at: template, to: image)
            let faults = WriteFaultInjector()
            let volume = try open(image, faults: faults)
            try await runEdits(volume)
            faults.failAfter(cut)
            let succeeded = (try? await volume.flush()) != nil
            await volume.close()

            let reopened = try open(image, allowUnclean: true)
            let root = try await names(reopened)
            if root == newNames {
                sawNew = true
                let item = try await childItem(reopened, "New File", in: HFSCatalogID.rootFolder)
                let bytes = try await reopened.readForkBytes(item.id, fork: .data)
                XCTAssertEqual(bytes, newData, "cut after \(cut) writes: new file's contents are wrong")
                let folder = try await childItem(reopened, "New Folder", in: HFSCatalogID.rootFolder)
                let inFolder = try await names(reopened, in: folder.id)
                XCTAssertEqual(inFolder, ["file 4"], "cut after \(cut) writes")
            } else {
                XCTAssertEqual(root, oldNames, "cut after \(cut) writes: the volume is neither the old nor the new state")
                XCTAssertFalse(succeeded, "cut after \(cut) writes: flush reported success but the change isn't there")
                sawOld = true
            }
            for name in root where name.hasPrefix("file ") {
                let item = try await childItem(reopened, name, in: HFSCatalogID.rootFolder)
                let bytes = try await reopened.readForkBytes(item.id, fork: .data)
                XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "contents \(name.dropFirst(5))", "cut after \(cut) writes: \(name) damaged")
            }
            await reopened.close()
            try await assertOnlyOrphanedBlocks(image, context: "cut after \(cut) of \(totalWrites) writes (\(root == newNames ? "new" : "old") state):")
        }
        XCTAssertTrue(sawOld && sawNew, "the sweep should cover cuts both before and after the commit point")
    }

    /// Review finding: freed blocks were reused before the delete was committed, so a failed
    /// flush brought deleted files back holding another file's bytes.
    func testBlocksOfAnUncommittedDeleteAreNotReused() async throws {
        let image = try Fixtures.makeClassicHFSImage(in: work)
        let original = [UInt8](repeating: 0xAA, count: 5000)
        do {
            let volume = try open(image)
            try await volume.createFile(named: "Keep Me", in: HFSCatalogID.rootFolder, type: [], creator: [], dataFork: HFSForkSource(bytes: original), resourceFork: .empty)
            try await volume.flush()
            await volume.close()
        }
        let faults = WriteFaultInjector()
        let volume = try open(image, faults: faults)
        let doomed = try await childItem(volume, "Keep Me", in: HFSCatalogID.rootFolder)
        let oldBlocks = Set(try await volume.extents(of: doomed.id, fork: .data).flatMap { Int($0.startBlock)..<(Int($0.startBlock) + Int($0.blockCount)) })
        try await volume.delete(doomed.id)
        let replacement = try await volume.createFile(named: "Other", in: HFSCatalogID.rootFolder, type: [], creator: [],
                                                      dataFork: HFSForkSource(bytes: [UInt8](repeating: 0xEE, count: 5000)), resourceFork: .empty)
        let newBlocks = Set(try await volume.extents(of: replacement, fork: .data).flatMap { Int($0.startBlock)..<(Int($0.startBlock) + Int($0.blockCount)) })
        XCTAssertTrue(oldBlocks.isDisjoint(with: newBlocks), "a new file was written into blocks whose delete isn't committed yet")

        faults.failAfter(0) // the flush fails before writing anything
        await XCTAssertThrowsErrorAsync { try await volume.flush() }
        await volume.close()
        let reopened = try open(image)
        let kept = try await childItem(reopened, "Keep Me", in: HFSCatalogID.rootFolder)
        let bytes = try await reopened.readForkBytes(kept.id, fork: .data)
        XCTAssertEqual(bytes, original)
    }

    /// Review finding: growing a catalog that already had overflow extents corrupted the
    /// volume. Free space is cut into single blocks, so the catalog can only grow by gathering
    /// many one-block runs — which the extents tree then has to record.
    func testCatalogGrowsThroughFragmentedFreeSpaceTwice() async throws {
        let image = try Fixtures.makeClassicHFSImage(in: work)
        do {
            let volume = try open(image)
            var fillers: [UInt32] = []
            for i in 0..<240 {
                fillers.append(try await volume.createFile(named: "filler \(i)", in: HFSCatalogID.rootFolder, type: [], creator: [],
                                                           dataFork: HFSForkSource(bytes: [UInt8](repeating: 1, count: 512)), resourceFork: .empty))
            }
            try await volume.flush()
            let ballast = Int(await volume.freeBytes) - 4 * 512
            try await volume.createFile(named: "ballast", in: HFSCatalogID.rootFolder, type: [], creator: [],
                                        dataFork: HFSForkSource(bytes: [UInt8](repeating: 0, count: ballast)), resourceFork: .empty)
            try await volume.flush()
            for (index, id) in fillers.enumerated() where index % 2 == 0 { try await volume.delete(id) }
            try await volume.flush()
            await volume.close()
        }
        try Fixtures.fsck(image).clean ? () : XCTFail("setup left the volume damaged")

        // Round 0 scatters the catalog over single-block holes (overflow extents); round 1
        // grows a catalog that already has overflow extents — the reviewed failure.
        var sawCatalogOverflow = false
        for round in 0..<2 {
            let volume = try open(image)
            for i in 0..<40 {
                try await volume.createFolder(named: String(format: "Round %d folder %02d padding", round, i), in: HFSCatalogID.rootFolder)
            }
            try await volume.flush()
            let catalogOverflow = await volume.overflowRecords.filter { $0.key.fileID == HFSCatalogID.catalogFile }
            if !catalogOverflow.isEmpty { sawCatalogOverflow = true }
            await volume.close()
            let verdict = try Fixtures.fsck(image)
            XCTAssertTrue(verdict.clean, "round \(round):\n\(verdict.output)")
        }
        XCTAssertTrue(sawCatalogOverflow, "the test should have forced catalog overflow extents")
        let reopened = try open(image)
        let folders = try await reopened.contents(ofFolder: HFSCatalogID.rootFolder).filter(\.isFolder)
        XCTAssertEqual(folders.count, 80)
    }

    // MARK: Hostile images

    func testCatalogWithACycleIsRejected() throws {
        let image = try Fixtures.makeClassicHFSImage(in: work)
        try Fixtures.withMounted(image) { try Fixtures.hfs("hmkdir", [":A"]) }
        var bytes = Array(try Data(contentsOf: image))
        // Leaf record for folder "A" in the root: key (len 7, parent 2, name "A"), padding,
        // then the folder record; its dirID sits 6 bytes into the record.
        let key: [UInt8] = [7, 0, 0, 0, 0, 2, 1, 0x41, 1, 0]
        let position = try XCTUnwrap((0..<(bytes.count - key.count)).first { Array(bytes[$0..<($0 + key.count)]) == key })
        bytes.put32(HFSCatalogID.rootFolder, at: position + 8 + 6) // folder A claims the root's ID
        let damaged = work.appendingPathComponent("cycle.dsk")
        try Data(bytes).write(to: damaged)
        XCTAssertThrowsError(try open(damaged))
    }

    func testHostileGUIDPartitionTablesDoNotCrash() throws {
        for (label, entriesLBA, lastLBA) in [("huge entries LBA", UInt64(0xFFFF_FFFF_FFFF_FFF0), UInt64(10)), ("huge end LBA", UInt64(2), UInt64.max)] {
            var disk = [UInt8](repeating: 0, count: 4096)
            disk.put(Array("EFI PART".utf8), at: 512)
            func putLE(_ value: UInt64, _ offset: Int, _ count: Int) {
                for i in 0..<count { disk[offset + i] = UInt8(truncatingIfNeeded: value >> UInt64(8 * i)) }
            }
            putLE(entriesLBA, 512 + 72, 8)
            putLE(4, 512 + 80, 4)
            putLE(128, 512 + 84, 4)
            disk[1024] = 0xAF // a non-empty type GUID
            putLE(3, 1024 + 32, 8)
            putLE(lastLBA, 1024 + 40, 8)
            let url = work.appendingPathComponent("\(label).img")
            try Data(disk).write(to: url)
            XCTAssertThrowsError(try DiskImageLayout.volumes(in: url), label)
        }
    }

    // MARK: Other writers

    func testAClosedVolumeRejectsLateCalls() async throws {
        let image = try Fixtures.makeClassicHFSImage(in: work)
        let volume = try open(image)
        await volume.close()
        await XCTAssertThrowsErrorAsync { try await volume.createFolder(named: "Late", in: HFSCatalogID.rootFolder) }
        await XCTAssertThrowsErrorAsync { _ = try await volume.contents(ofFolder: HFSCatalogID.rootFolder) }
    }

    func testASecondWriterGetsAReadOnlyVolume() throws {
        let image = try Fixtures.makeClassicHFSImage(in: work)
        let first = try DiskImageLayout.openVolume(image, readOnly: false)
        XCTAssertFalse(first.isReadOnly)
        let second = try DiskImageLayout.openVolume(image, readOnly: false)
        XCTAssertEqual(second.readOnlyCause, .inUse)
        _ = first
    }

    func testChangesMadeByAnotherProgramAreNeverOverwritten() async throws {
        let image = try Fixtures.makeClassicHFSImage(in: work)
        let volume = try open(image)
        try await volume.createFolder(named: "Ours", in: HFSCatalogID.rootFolder)
        // Another program that ignores the advisory lock writes the volume meanwhile: here,
        // bumping the MDB's write count directly, as any change would.
        let handle = try FileHandle(forUpdating: image)
        try handle.seek(toOffset: 1024 + 70)
        let count = try XCTUnwrap(handle.read(upToCount: 4))
        try handle.seek(toOffset: 1024 + 70)
        try handle.write(contentsOf: Data([count[0], count[1], count[2], count[3] &+ 1]))
        try handle.close()
        let before = try Data(contentsOf: image)
        do {
            try await volume.flush()
            XCTFail("the flush should refuse to overwrite another program's changes")
        } catch HFSError.modifiedElsewhere {}
        await volume.close()
        XCTAssertEqual(try Data(contentsOf: image), before, "nothing may be written over the other program's changes")
    }

    func testAVolumeThatWasNotEjectedCleanlyOpensReadOnlyUnlessAllowed() async throws {
        let image = try Fixtures.makeClassicHFSImage(in: work)
        var bytes = Array(try Data(contentsOf: image))
        bytes[1024 + 10] &= ~0x01 // drAtrb bit 8 (high byte bit 0): unmounted cleanly
        try Data(bytes).write(to: image)
        let guarded = try open(image)
        XCTAssertEqual(guarded.readOnlyCause, .notCleanlyUnmounted)
        await guarded.close()
        let allowed = try open(image, allowUnclean: true)
        XCTAssertFalse(allowed.isReadOnly)
        try await allowed.createFolder(named: "Fine", in: HFSCatalogID.rootFolder)
        try await allowed.flush()
        await allowed.close()
        XCTAssertTrue(try Fixtures.fsck(image).clean)
    }
}

func XCTAssertThrowsErrorAsync(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
    do {
        try await body()
        XCTFail("expected an error", file: file, line: line)
    } catch {}
}
