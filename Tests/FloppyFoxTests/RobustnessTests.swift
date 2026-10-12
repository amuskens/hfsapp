import AppKit
import XCTest
@testable import FloppyFox

/// Failure-mode tests: subprocess plumbing under load, and parsers fed hostile bytes. A disk
/// image is untrusted input, so malformed data must produce an error or nil — never a crash or
/// a hang.
@MainActor
final class RobustnessTests: XCTestCase {
    // MARK: Subprocesses

    /// The runner used to call `waitUntilExit()` before draining the pipes. Once a child wrote
    /// more than the 64 KB pipe buffer it blocked forever, and so did the app — e.g. `hls` on a
    /// folder with a couple of thousand files.
    func testProcessRunnerDrainsOutputLargerThanThePipeBuffer() async throws {
        let (out, err, status) = try await withTimeout(20) {
            await DiskImageManager.runProcess("/bin/sh", ["-c", "head -c 1000000 /dev/zero | tr '\\0' x; head -c 300000 /dev/zero | tr '\\0' y >&2"])
        }
        XCTAssertEqual(status, 0)
        XCTAssertEqual(out.count, 1_000_000)
        XCTAssertEqual(err.count, 300_000)
    }

    func testProcessRunnerReportsLaunchFailureInsteadOfThrowing() async {
        let (_, err, status) = await DiskImageManager.runProcess("/nonexistent/tool", [])
        XCTAssertEqual(status, -1)
        XCTAssertFalse(err.isEmpty)
    }

    // MARK: Hostile image contents

    func testVHDParserRejectsCorruptContainersWithoutCrashing() async throws {
        let work = try Fixtures.makeWorkDirectory("vhd-fuzz")
        defer { try? FileManager.default.removeItem(at: work) }

        func footer(type: UInt32, headerOffset: UInt64 = 512, virtualSize: UInt64 = 512) -> Data {
            var data = Data(count: 512)
            data.replaceSubrange(0..<8, with: Data("conectix".utf8))
            data.putUInt64BE(headerOffset, at: 16)
            data.putUInt64BE(virtualSize, at: 48)
            data.putUInt32BE(type, at: 60)
            return data
        }

        let cases: [(String, Data, Bool)] = [
            ("differencing", Data(count: 1024) + footer(type: 4), true),
            ("unknown type", Data(count: 1024) + footer(type: 99), true),
            ("header past EOF", footer(type: 3, headerOffset: 1 << 40), true),
            ("missing cxsparse", Data(count: 2048) + footer(type: 3), true),
            ("huge virtual size, tiny file", Data(count: 2048) + footer(type: 3, virtualSize: UInt64.max / 2), true),
        ]
        for (label, bytes, shouldThrow) in cases {
            let url = work.appendingPathComponent("\(UUID().uuidString).vhd")
            try bytes.write(to: url)
            do {
                let prepared = try await VHDImage.prepareForReading(url)
                XCTAssertFalse(shouldThrow, "\(label): expected an error, got \(prepared.imageURL)")
            } catch {
                XCTAssertTrue(shouldThrow, "\(label): unexpected error \(error)")
            }
        }

        // Random garbage, with and without a plausible footer: any outcome but a crash is fine.
        var generator = SeededGenerator(seed: 0xF10)
        for _ in 0..<200 {
            var bytes = Data((0..<Int.random(in: 0...4096, using: &generator)).map { _ in UInt8.random(in: 0...255, using: &generator) })
            if Bool.random(using: &generator) { bytes += footer(type: [2, 3, 4].randomElement(using: &generator)!, headerOffset: UInt64.random(in: 0...5000, using: &generator)) }
            let url = work.appendingPathComponent("\(UUID().uuidString).vhd")
            try bytes.write(to: url)
            if let prepared = try? await VHDImage.prepareForReading(url), prepared.imageURL != url {
                try? FileManager.default.removeItem(at: prepared.imageURL)
            }
        }
    }

    func testResourceIconParserSurvivesRandomAndTruncatedInput() {
        var generator = SeededGenerator(seed: 0x1C0)
        for _ in 0..<2_000 {
            let length = Int.random(in: 0...2048, using: &generator)
            var bytes = Data((0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) })
            if bytes.count >= 128 {
                // Point the MacBinary header at a "resource fork" inside the buffer so the
                // fuzzer actually reaches the resource-map walker, not just the header check.
                bytes.putUInt32BE(0, at: 83)
                bytes.putUInt32BE(UInt32(bytes.count - 128), at: 87)
            }
            _ = ClassicMacResourceIcon.iconPNG(fromMacBinary: bytes)
        }
    }
}

/// Deterministic PRNG so a fuzz failure reproduces exactly.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension Data {
    mutating func putUInt32BE(_ value: UInt32, at offset: Int) {
        for i in 0..<4 { self[offset + i] = UInt8(truncatingIfNeeded: value >> UInt32((3 - i) * 8)) }
    }

    mutating func putUInt64BE(_ value: UInt64, at offset: Int) {
        for i in 0..<8 { self[offset + i] = UInt8(truncatingIfNeeded: value >> UInt64((7 - i) * 8)) }
    }
}
