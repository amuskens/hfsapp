import AppKit
import XCTest
@testable import FloppyFox

/// Random operations fired at the app model concurrently — the way a fast user, a drag and a
/// menu command overlap — including Eject and reopening mid-flight. Whatever happens, nothing
/// may hang, the image must stay fsck-clean, and what the browser shows must match the disk.
@MainActor
final class ManagerStressTests: XCTestCase {
    private var work: URL!

    override func setUp() async throws {
        guard Fixtures.hfsutilsPrefix != nil else { throw XCTSkip("hfsutils (brew install hfsutils) is required as a test oracle") }
        work = try Fixtures.makeWorkDirectory("stress")
    }

    override func tearDown() async throws {
        if let work { try? FileManager.default.removeItem(at: work) }
    }

    private struct Rng {
        var state: UInt64
        mutating func next(_ n: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(max(n, 1)))
        }
    }

    func testRandomOverlappingOperationsKeepTheImageConsistent() async throws {
        let seeds = Int(ProcessInfo.processInfo.environment["FLOPPYFOX_STRESS_SEEDS"] ?? "") ?? 6
        for seed in 1...seeds {
            try await runSession(seed: UInt64(seed), plus: seed % 3 == 0)
        }
    }

    private func runSession(seed: UInt64, plus: Bool) async throws {
        var rng = Rng(state: seed)
        let image = plus ? try HFSPlusFixtures.makeVolume(in: work, name: "stress-\(seed).img", sizeMB: 40)
                         : try Fixtures.makeClassicHFSImage(in: work, name: "stress-\(seed).dsk", sizeKB: 4 * 1024)
        let sources = work.appendingPathComponent("src-\(seed)")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let hostFiles = try (0..<12).map { i -> URL in
            let url = sources.appendingPathComponent("host \(i).txt")
            try Data(repeating: UInt8(65 + i), count: 1_000 + 37_000 * (i % 4)).write(to: url)
            return url
        }
        let exports = work.appendingPathComponent("out-\(seed)")
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)

        let manager = DiskImageManager.forTesting()
        await manager.attachImage(imageURL: image)
        XCTAssertTrue(manager.isOpen)

        var tasks: [Task<Void, Never>] = []
        let errors = ErrorLog()
        let watcher = manager.$errorMessage.sink { message in if let message { errors.add(message) } }
        defer { watcher.cancel() }
        for step in 0..<60 {
            let entries = manager.entries
            let pick = entries.isEmpty ? nil : entries[rng.next(entries.count)]
            switch rng.next(16) {
            case 0, 1: tasks.append(Task { await manager.importFiles(urls: [hostFiles[step % hostFiles.count]]) })
            case 2: tasks.append(Task { await manager.createFolder(named: "Folder \(step)") })
            case 3: if let pick { tasks.append(Task { await manager.deleteEntries([pick]) }) }
            case 4: if let pick, pick.isDirectory { tasks.append(Task { await manager.navigate(into: pick) }) }
            case 5: tasks.append(Task { await manager.goUp() })
            case 6: if let pick { manager.copyEntry(pick); tasks.append(Task { await manager.performPaste() }) }
            case 7: if let pick { manager.cutEntry(pick); tasks.append(Task { await manager.performPaste() }) }
            case 8: tasks.append(Task { await manager.refresh() })
            case 9: if let pick, !pick.isDirectory { tasks.append(Task { _ = await manager.materializeForPreview(pick) }) }
            case 10: if let pick { tasks.append(Task { await manager.export(pick, to: exports.appendingPathComponent("e\(step)")) }) }
            case 11: if let pick, !entries.isEmpty, let folder = entries.first(where: \.isDirectory), folder.id != pick.id {
                tasks.append(Task { await manager.moveItems([pick.id], to: folder.id) })
            }
            case 12: if rng.next(4) == 0 {
                // Eject and reopen while other work is queued or running.
                tasks.append(Task {
                    await manager.ejectImage()
                    await manager.attachImage(imageURL: image)
                })
            }
            case 13: if rng.next(3) == 0 { manager.cancelActiveTransfer() }
            case 14: if let pick { tasks.append(Task { await manager.copyItems([pick.id], to: HFSCatalogID.rootFolder) }) }
            default: tasks.append(Task { await manager.navigate(toFolder: HFSCatalogID.rootFolder) })
            }
            // Sometimes let work land before the next command, sometimes pile them up.
            if rng.next(3) == 0 { await Task.yield() }
            if rng.next(8) == 0, let last = tasks.last { await last.value }
        }
        let finished = expectation(description: "session \(seed) settles")
        Task {
            for task in tasks { await task.value }
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 120)
        if ProcessInfo.processInfo.environment["FLOPPYFOX_STRESS_VERBOSE"] != nil { print("STRESS seed \(seed) errors: \(errors.messages)") }

        // What the browser shows must match the volume.
        if !manager.isOpen { await manager.attachImage(imageURL: image) }
        await manager.navigate(toFolder: HFSCatalogID.rootFolder)
        let shown = Set(manager.entries.map(\.name))
        await manager.ejectImage()
        let verdict = try Fixtures.fsck(image)
        XCTAssertTrue(verdict.clean, "seed \(seed): \(verdict.output)")
        let volume = try DiskImageLayout.openVolume(image, readOnly: true)
        let onDisk = Set(try await volume.contents(ofFolder: HFSCatalogID.rootFolder).map(\.name)).subtracting(["Desktop DB", "Desktop DF"])
        await volume.close()
        XCTAssertEqual(shown, onDisk, "seed \(seed): browser and disk disagree")
        let writable = try DiskImageLayout.openVolume(image, readOnly: false)
        XCTAssertNil(writable.readOnlyCause, "seed \(seed): Eject left the volume marked in use")
        await writable.close()
    }
}

private final class ErrorLog: @unchecked Sendable {
    private(set) var messages: [String] = []
    // Messages caused by the image closing are cleared before they're shown (see errorMessage).
    func add(_ message: String) { if !message.contains(HFSError.closed.localizedDescription) { messages.append(message) } }
}
