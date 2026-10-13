import XCTest
@testable import FloppyFox

/// Multi-gigabyte volumes and files. They write several GB (on sparse images, so only the
/// data itself takes space), so they run only with FLOPPYFOX_LARGE_TESTS=1.
final class LargeVolumeTests: XCTestCase {
    private var work: URL!

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["FLOPPYFOX_LARGE_TESTS"] != nil else { throw XCTSkip("set FLOPPYFOX_LARGE_TESTS=1 to run multi-GB tests") }
        guard Fixtures.hfsutilsPrefix != nil else { throw XCTSkip("hfsutils (brew install hfsutils) is required as a test oracle") }
        work = try Fixtures.makeWorkDirectory("large")
    }

    override func tearDown() async throws {
        if let work { try? FileManager.default.removeItem(at: work) }
    }

    /// A fork of `length` bytes that is zero except for its own offset stamped (big-endian) at
    /// the start of every 4 KB, generated as it is read.
    private static func stamped(_ length: UInt64) -> HFSForkSource {
        HFSForkSource(length: length) { offset, count in
            var bytes = [UInt8](repeating: 0, count: count)
            var position = (offset + 4095) / 4096 * 4096
            while position + 8 <= offset + UInt64(count) {
                let at = Int(position - offset)
                for i in 0..<8 { bytes[at + i] = UInt8(truncatingIfNeeded: position >> (56 - 8 * UInt64(i))) }
                position += 4096
            }
            return bytes
        }
    }

    private static func checkStamps(_ read: (UInt64) throws -> [UInt8], length: UInt64, file: StaticString = #filePath, line: UInt = #line) rethrows {
        let samples: [UInt64] = [0, 4096, 1 << 30, UInt64(Int32.max) / 4096 * 4096, (length - 8) / 4096 * 4096]
        for position in samples where position + 8 <= length {
            let bytes = try read(position)
            let value = bytes.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            XCTAssertEqual(value, position, "stamp at \(position)", file: file, line: line)
        }
    }

    private func sparseFile(_ name: String, bytes: UInt64) throws -> URL {
        let url = work.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: bytes)
        try handle.close()
        return url
    }

    /// A file over 2 GB (and past 32-bit offsets) on a 6 GB HFS Plus volume, checked through
    /// the real kernel driver.
    func testAFileLargerThan2GBOnAMultiGigabyteHFSPlusVolume() async throws {
        let image = try HFSPlusFixtures.makeVolume(in: work, name: "big.img", sizeMB: 6 * 1024)
        let length: UInt64 = (5 << 29) + 12_345 // 2.5 GB and change
        do {
            let volume = try DiskImageLayout.openVolume(image, readOnly: false)
            let free = await volume.freeBytes
            XCTAssertGreaterThan(free, length)
            try await volume.createFile(named: "huge.bin", in: HFSCatalogID.rootFolder, metadata: NewFileMetadata(fileType: [], creator: []),
                                        dataFork: Self.stamped(length), resourceFork: .empty)
            try await volume.flush()
            await volume.close()
        }
        XCTAssertTrue(try Fixtures.fsck(image).clean)
        try HFSPlusFixtures.withMounted(image) { root in
            let url = root.appendingPathComponent("huge.bin")
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64
            XCTAssertEqual(size, length)
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try Self.checkStamps({ position in
                try handle.seek(toOffset: position)
                return [UInt8](handle.readData(ofLength: 8))
            }, length: length)
        }
    }

    /// Classic HFS on a 3 GB volume (48 KB allocation blocks): a file just under 2 GB is
    /// written and reads back; one past what Mac OS can represent is refused.
    func testClassicHFSOnAThreeGigabyteVolumeHonorsThe2GBFileLimit() async throws {
        let image = try sparseFile("big.dsk", bytes: 3 << 30)
        try Fixtures.hfs("hformat", ["-l", "Big", image.path])
        let length = UInt64(Int32.max) - 100
        do {
            let volume = try DiskImageLayout.openVolume(image, readOnly: false)
            await XCTAssertThrowsErrorAsync {
                try await volume.createFile(named: "too big", in: HFSCatalogID.rootFolder, metadata: NewFileMetadata(fileType: [], creator: []),
                                            dataFork: Self.stamped(UInt64(Int32.max) + 1), resourceFork: .empty)
            }
            try await volume.createFile(named: "almost 2 GB", in: HFSCatalogID.rootFolder, metadata: NewFileMetadata(fileType: [], creator: []),
                                        dataFork: Self.stamped(length), resourceFork: .empty)
            try await volume.flush()
            await volume.close()
        }
        // fsck_hfs rejects hformat's 48 KB allocation blocks (Mac OS accepts any multiple of
        // 512), so hfsutils is the oracle here: mounting it walks both B-trees' headers and
        // map nodes.
        try Fixtures.withMounted(image) {
            XCTAssertTrue(try Fixtures.longListing(of: ":almost 2 GB").contains(String(length)), "hfsutils should see the full length")
        }
        let volume = try DiskImageLayout.openVolume(image, readOnly: true)
        let item = try await childItem(volume, "almost 2 GB", in: HFSCatalogID.rootFolder)
        XCTAssertEqual(item.dataLength, length)
        var stamps: [UInt64: [UInt8]] = [:]
        let wanted: Set<UInt64> = [0, 4096, 1 << 30, UInt64(Int32.max) / 4096 * 4096, (length - 8) / 4096 * 4096]
        let collected = StampCollector(wanted: wanted)
        try await volume.readFork(item.id, fork: .data, chunkSize: 1 << 20) { chunk in collected.take(chunk) }
        stamps = collected.found
        await volume.close()
        Self.checkStamps({ stamps[$0] ?? [] }, length: length)
    }
}

/// Picks the 8 bytes at each wanted offset out of a streamed fork.
private final class StampCollector: @unchecked Sendable {
    let wanted: Set<UInt64>
    private(set) var found: [UInt64: [UInt8]] = [:]
    private var offset: UInt64 = 0

    init(wanted: Set<UInt64>) { self.wanted = wanted }

    func take(_ chunk: [UInt8]) {
        for position in wanted where position >= offset && position + 8 <= offset + UInt64(chunk.count) {
            let at = Int(position - offset)
            found[position] = Array(chunk[at..<(at + 8)])
        }
        offset += UInt64(chunk.count)
    }
}
