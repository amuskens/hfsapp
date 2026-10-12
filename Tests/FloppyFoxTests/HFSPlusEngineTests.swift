import XCTest
@testable import FloppyFox

/// Tests for the HFS Plus engine. macOS still mounts HFS Plus, so beyond fsck these use the
/// real kernel driver as an oracle: volumes are formatted by `newfs_hfs`, populated by macOS
/// for the read tests, and mounted (read-only) to check what the engine wrote.
final class HFSPlusEngineTests: XCTestCase {
    private var work: URL!

    override func setUp() async throws {
        work = try Fixtures.makeWorkDirectory("hfsplus")
    }

    override func tearDown() async throws {
        if let work, ProcessInfo.processInfo.environment["FLOPPYFOX_KEEP_TEST_IMAGES"] == nil { try? FileManager.default.removeItem(at: work) }
    }

    private func open(_ url: URL, faults: WriteFaultInjector? = nil, readOnly: Bool = false, allowUnclean: Bool = false) throws -> HFSPlusVolume {
        let location = try XCTUnwrap(DiskImageLayout.volumes(in: url).first)
        XCTAssertEqual(location.format, .hfsPlus)
        let device = try BlockDevice(url: url, offset: location.offset, length: location.length, writable: !readOnly, faults: faults)
        return try HFSPlusVolume(device: device, forcedReadOnly: readOnly ? .requested : nil, allowUncleanVolume: allowUnclean)
    }

    private func assertFsckClean(_ image: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let verdict = try Fixtures.fsck(image)
        XCTAssertTrue(verdict.clean, "fsck_hfs rejected the volume:\n\(verdict.output)", file: file, line: line)
    }

    private func randomBytes(_ count: Int, seed: UInt64) -> [UInt8] {
        var generator = SeededGenerator(seed: seed)
        return (0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) }
    }

    /// Names that exercise Apple's Unicode handling: decomposition, case folding beyond ASCII,
    /// non-Roman scripts, and the `/` ↔ `:` convention.
    private let unicodeNames = ["Café", "naïve résumé", "日本語のファイル", "Ελληνικά", "ÆØÅ æøå", "Tom & Jerry", "Straße", "😀 emoji"]

    // MARK: Reading what macOS wrote

    func testReadsFilesForksFinderInfoAndUnicodeNamesWrittenByMacOS() async throws {
        let image = try HFSPlusFixtures.makeVolume(in: work)
        let resource = randomBytes(3000, seed: 1)
        let data = randomBytes(70_000, seed: 2)
        try HFSPlusFixtures.populate(image) { root in
            let folder = root.appendingPathComponent("Folder/Nested", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = root.appendingPathComponent("Folder/App")
            try Data(data).write(to: file)
            try Data(resource).write(to: HostFiles.resourceForkURL(file))
            XCTAssertTrue(HostFiles.setExtendedAttribute(HostFiles.finderInfoAttribute, value: Array("APPLTEST".utf8) + [UInt8](repeating: 0, count: 24), of: file))
            for name in unicodeNames { try Data(name.utf8).write(to: root.appendingPathComponent(name)) }
        }

        let volume = try open(image, readOnly: true)
        let root = try await volume.contents(ofFolder: HFSCatalogID.rootFolder)
        let names = Set(root.map(\.name))
        XCTAssertTrue(names.isSuperset(of: unicodeNames + ["Folder"]), "\(names)")
        for name in unicodeNames {
            let item = try await childItem(volume, name, in: HFSCatalogID.rootFolder)
            let bytes = try await volume.readForkBytes(item.id, fork: .data)
            XCTAssertEqual(String(decoding: bytes, as: UTF8.self), name)
        }
        let folder = try await childItem(volume, "Folder", in: HFSCatalogID.rootFolder)
        let app = try await childItem(volume, "App", in: folder.id)
        XCTAssertEqual(app.fileType, Array("APPL".utf8))
        XCTAssertEqual(app.creator, Array("TEST".utf8))
        let readData = try await volume.readForkBytes(app.id, fork: .data)
        let readResource = try await volume.readForkBytes(app.id, fork: .resource)
        XCTAssertEqual(readData, data)
        XCTAssertEqual(readResource, resource)
        // Lookups are case-insensitive, with Apple's folding.
        for variant in ["CAFÉ", "straße", "ÆØÅ ÆØÅ"] {
            let found = await volume.child(named: variant, inFolder: HFSCatalogID.rootFolder)
            XCTAssertNotNil(found, "\(variant) should match case-insensitively")
        }
    }

    // MARK: Writing, judged by fsck and by macOS itself

    func testEngineWritesPassFsckAndReadBackThroughMacOS() async throws {
        let image = try HFSPlusFixtures.makeVolume(in: work)
        let data = randomBytes(150_000, seed: 3)
        let resource = randomBytes(4_321, seed: 4)
        do {
            let volume = try open(image)
            let docs = try await volume.createFolder(named: "Documents", in: HFSCatalogID.rootFolder)
            let deep = try await volume.createFolder(named: "Deep ƒ", in: docs)
            try await volume.createFile(named: "App", in: deep, type: Array("APPL".utf8), creator: Array("FFOX".utf8),
                                        dataFork: HFSForkSource(bytes: data), resourceFork: HFSForkSource(bytes: resource))
            for name in unicodeNames {
                try await volume.createFile(named: name, in: docs, type: Array("TEXT".utf8), creator: Array("ttxt".utf8),
                                            dataFork: HFSForkSource(bytes: Array(name.utf8)), resourceFork: .empty)
            }
            let doomed = try await volume.createFile(named: "Doomed", in: docs, type: [], creator: [], dataFork: HFSForkSource(bytes: [1]), resourceFork: .empty)
            let movable = try await volume.createFile(named: "Movable", in: docs, type: [], creator: [], dataFork: HFSForkSource(bytes: Array("move me".utf8)), resourceFork: .empty)
            try await volume.delete(doomed)
            try await volume.move(movable, to: HFSCatalogID.rootFolder, newName: "Moved & Renamed")
            try await volume.flush()
            await volume.close()
        }
        try assertFsckClean(image)

        try HFSPlusFixtures.withMounted(image) { root in
            let docs = root.appendingPathComponent("Documents")
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Moved & Renamed"), encoding: .utf8), "move me")
            XCTAssertFalse(FileManager.default.fileExists(atPath: docs.appendingPathComponent("Doomed").path))
            for name in unicodeNames {
                // The kernel finds each name by binary search with Apple's comparison, so this
                // also proves the catalog is in Apple's order.
                XCTAssertEqual(try String(contentsOf: docs.appendingPathComponent(name), encoding: .utf8), name, name)
            }
            let app = docs.appendingPathComponent("Deep ƒ/App")
            XCTAssertEqual(Array(try Data(contentsOf: app)), data)
            XCTAssertEqual(try HostFiles.readResourceFork(of: app), resource)
            let info = try XCTUnwrap(HostFiles.extendedAttribute(HostFiles.finderInfoAttribute, of: app))
            XCTAssertEqual(Array(info[0..<8]), Array("APPLFFOX".utf8))
        }
    }

    /// Thousands of entries force the catalog file to grow; deleting most shrinks it back.
    func testCatalogGrowsAndShrinksAndStaysValid() async throws {
        let image = try HFSPlusFixtures.makeVolume(in: work, sizeMB: 64)
        let count = 3_000
        do {
            let volume = try open(image)
            let folder = try await volume.createFolder(named: "Many", in: HFSCatalogID.rootFolder)
            for i in 0..<count {
                try await volume.createFile(named: String(format: "Fichier numéro %05d", i), in: folder, type: [], creator: [], dataFork: .empty, resourceFork: .empty)
            }
            try await volume.flush()
            await volume.close()
        }
        try assertFsckClean(image)
        try HFSPlusFixtures.withMounted(image) { root in
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Many").path).count, count)
        }
        do {
            let volume = try open(image)
            let folder = try await childItem(volume, "Many", in: HFSCatalogID.rootFolder)
            for item in try await volume.contents(ofFolder: folder.id).dropFirst(10) { try await volume.delete(item.id) }
            try await volume.flush()
            await volume.close()
        }
        try assertFsckClean(image)
    }

    /// A large file through fragmented free space needs more than eight extents.
    func testFragmentedFileUsesExtentsOverflowRecords() async throws {
        let image = try HFSPlusFixtures.makeVolume(in: work, sizeMB: 8)
        let payload = randomBytes(600 * 1024, seed: 5)
        do {
            let volume = try open(image)
            var fillers: [UInt32] = []
            for i in 0..<300 {
                fillers.append(try await volume.createFile(named: "filler \(i)", in: HFSCatalogID.rootFolder, type: [], creator: [],
                                                           dataFork: HFSForkSource(bytes: [UInt8](repeating: UInt8(i & 0xFF), count: 4096)), resourceFork: .empty))
            }
            try await volume.flush()
            let ballast = Int(await volume.freeBytes) - 64 * 4096
            try await volume.createFile(named: "ballast", in: HFSCatalogID.rootFolder, type: [], creator: [],
                                        dataFork: HFSForkSource(bytes: [UInt8](repeating: 0, count: ballast)), resourceFork: .empty)
            for (index, id) in fillers.enumerated() where index % 2 == 0 { try await volume.delete(id) }
            try await volume.flush()
            try await volume.createFile(named: "Fragmented", in: HFSCatalogID.rootFolder, type: [], creator: [],
                                        dataFork: HFSForkSource(bytes: payload), resourceFork: .empty)
            try await volume.flush()
            await volume.close()
        }
        try assertFsckClean(image)
        try HFSPlusFixtures.withMounted(image) { root in
            XCTAssertEqual(Array(try Data(contentsOf: root.appendingPathComponent("Fragmented"))), payload)
        }
    }

    func testCaseSensitiveHFSXKeepsNamesThatDifferOnlyInCase() async throws {
        let image = try HFSPlusFixtures.makeVolume(in: work, caseSensitive: true)
        do {
            let volume = try open(image)
            try await volume.createFile(named: "readme", in: HFSCatalogID.rootFolder, type: [], creator: [], dataFork: HFSForkSource(bytes: Array("lower".utf8)), resourceFork: .empty)
            try await volume.createFile(named: "README", in: HFSCatalogID.rootFolder, type: [], creator: [], dataFork: HFSForkSource(bytes: Array("upper".utf8)), resourceFork: .empty)
            try await volume.flush()
            await volume.close()
        }
        try assertFsckClean(image)
        try HFSPlusFixtures.withMounted(image) { root in
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("readme"), encoding: .utf8), "lower")
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("README"), encoding: .utf8), "upper")
        }
    }

    func testCaseInsensitiveVolumeRejectsCaseOnlyDuplicates() async throws {
        let image = try HFSPlusFixtures.makeVolume(in: work)
        let volume = try open(image)
        try await volume.createFolder(named: "Ünïcödé", in: HFSCatalogID.rootFolder)
        await XCTAssertThrowsErrorAsync { try await volume.createFolder(named: "ÜNÏCÖDÉ", in: HFSCatalogID.rootFolder) }
        await XCTAssertThrowsErrorAsync { try await volume.createFolder(named: "a:b", in: HFSCatalogID.rootFolder) }
        await volume.close()
    }

    // MARK: Safety

    func testFlushInterruptedAtEveryWriteLeavesTheOldOrTheNewVolume() async throws {
        let template = try HFSPlusFixtures.makeVolume(in: work, name: "template.img", sizeMB: 16)
        do {
            let volume = try open(template)
            for i in 0..<10 {
                try await volume.createFile(named: "file \(i)", in: HFSCatalogID.rootFolder, type: [], creator: [], dataFork: HFSForkSource(bytes: Array("contents \(i)".utf8)), resourceFork: .empty)
            }
            try await volume.flush()
            await volume.close()
        }
        let oldNames = Set((0..<10).map { "file \($0)" })
        let newNames = oldNames.subtracting(["file 3"]).union(["New Folder", "New File"])

        func runEdits(_ volume: HFSPlusVolume) async throws {
            try await volume.createFolder(named: "New Folder", in: HFSCatalogID.rootFolder)
            try await volume.createFile(named: "New File", in: HFSCatalogID.rootFolder, type: [], creator: [], dataFork: HFSForkSource(bytes: Array("new".utf8)), resourceFork: .empty)
            try await volume.delete(try await childItem(volume, "file 3", in: HFSCatalogID.rootFolder).id)
        }

        let probe = work.appendingPathComponent("probe.img")
        try FileManager.default.copyItem(at: template, to: probe)
        let counter = WriteFaultInjector()
        let dry = try open(probe, faults: counter)
        try await runEdits(dry)
        counter.failAfter(nil)
        try await dry.flush()
        let total = counter.writesSeen
        await dry.close()

        for cut in 0...total {
            let image = work.appendingPathComponent("cut-\(cut).img")
            try FileManager.default.copyItem(at: template, to: image)
            let faults = WriteFaultInjector()
            let volume = try open(image, faults: faults)
            try await runEdits(volume)
            faults.failAfter(cut)
            _ = try? await volume.flush()
            await volume.close()
            let reopened = try open(image, readOnly: true)
            let names = Set(try await reopened.contents(ofFolder: HFSCatalogID.rootFolder).map(\.name))
            XCTAssertTrue(names == oldNames || names == newNames, "cut after \(cut) of \(total) writes: \(names)")
            await reopened.close()
            try await assertCleanOrRepairsToKnownState(image, oneOf: [oldNames, newNames], context: "cut after \(cut) of \(total) writes")
            // Mounting works and shows the same state: the kernel accepts the volume.
            try HFSPlusFixtures.withMounted(image) { root in
                let mounted = Set(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { !$0.hasPrefix(".") })
                XCTAssertEqual(mounted, names, "cut after \(cut) writes")
            }
        }
    }

    func testJournaledVolumesOpenReadOnly() async throws {
        let image = try Fixtures.makeHFSPlusImage(in: work, fileSystem: "JHFS+")
        let volume = try DiskImageLayout.openVolume(image, readOnly: false)
        XCTAssertEqual(volume.readOnlyCause, .journaled)
        await volume.close()
    }

    /// The real case this engine exists for: a Mac OS 9 BlueSCSI image, whose HFS Plus volume
    /// sits inside an HFS wrapper. Edits a clone and has fsck check it.
    func testEditsARealMacOS9WrappedVolume() async throws {
        guard let path = ProcessInfo.processInfo.environment["FLOPPYFOX_REAL_HFSPLUS_HDA"], FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("set FLOPPYFOX_REAL_HFSPLUS_HDA to a Mac OS 8.1–9 .hda image")
        }
        let image = work.appendingPathComponent("os9.hda")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: image)
        guard try Fixtures.fsck(image).clean else { throw XCTSkip("the original image isn't fsck-clean to begin with") }
        let location = try XCTUnwrap(DiskImageLayout.volumes(in: image).first)
        XCTAssertEqual(location.format, .hfsPlus)

        let payload = randomBytes(200_000, seed: 9)
        do {
            let volume = try DiskImageLayout.openVolume(image, at: location, readOnly: false)
            XCTAssertFalse(volume.isReadOnly, "\(String(describing: volume.readOnlyCause))")
            let root = try await volume.contents(ofFolder: HFSCatalogID.rootFolder)
            XCTAssertTrue(root.contains { $0.isFolder && $0.name.hasPrefix("System Folder") }, "\(root.map(\.name))")
            let folder = try await volume.createFolder(named: "FloppyFox Test", in: HFSCatalogID.rootFolder)
            try await volume.createFile(named: "Imported", in: folder, type: Array("APPL".utf8), creator: Array("FFOX".utf8),
                                        dataFork: HFSForkSource(bytes: payload), resourceFork: HFSForkSource(bytes: [1, 2, 3]))
            if let app = root.first(where: { !$0.isFolder && $0.resourceLength > 0 }) {
                _ = try await volume.copyFile(app.id, to: folder, name: "\(app.name) copy")
            }
            try await volume.flush()
            await volume.close()
        }
        try assertFsckClean(image)
        let reopened = try DiskImageLayout.openVolume(image, readOnly: true)
        let folder = try await childItem(reopened, "FloppyFox Test", in: HFSCatalogID.rootFolder)
        let imported = try await childItem(reopened, "Imported", in: folder.id)
        let bytes = try await reopened.readForkBytes(imported.id, fork: .data)
        XCTAssertEqual(bytes, payload)
    }
}
