import AppKit
import XCTest
@testable import FloppyFox

/// Builders for throwaway disk images, so integration tests never depend on files that only
/// exist on one developer's machine. Classic HFS fixtures are made with hfsutils' `hformat`
/// (the same toolchain the app's fallback backend drives); HFS+ fixtures with `hdiutil create`.
/// Every fixture lives in its own temp directory, removed by the returned `cleanup`.
enum Fixtures {
    static let hfsutilsPrefix: String? = ["/opt/homebrew/bin", "/usr/local/bin"]
        .first { FileManager.default.isExecutableFile(atPath: "\($0)/hformat") }

    static func makeWorkDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floppyfox-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A blank classic HFS volume with no partition map — exactly what macOS can no longer
    /// mount, so the app always routes it through the hfsutils backend.
    static func makeClassicHFSImage(in directory: URL, name: String = "Test Disk.dsk", sizeKB: Int = 1440, label: String = "Test") throws -> URL {
        guard hfsutilsPrefix != nil else { throw XCTSkip("hfsutils (brew install hfsutils) is required for classic HFS fixtures") }
        let url = directory.appendingPathComponent(name)
        try Data(count: sizeKB * 1024).write(to: url)
        try hfs("hformat", ["-l", label, url.path])
        return url
    }

    static func makeHFSPlusImage(in directory: URL, name: String = "Plus.dmg", sizeMB: Int = 32, label: String = "FloppyFoxPlus") throws -> URL {
        let url = directory.appendingPathComponent(name)
        let result = run("/usr/bin/hdiutil", ["create", "-size", "\(sizeMB)m", "-fs", "HFS+", "-volname", label, url.path])
        guard result.status == 0 else { throw XCTSkip("hdiutil create is unavailable here: \(result.output)") }
        return url
    }

    /// Runs `body` with `image` hmounted, then always humounts. hfsutils keeps the "current
    /// volume" in ~/.hcwd, so callers must not interleave this with an app operation in flight.
    static func withMounted<T>(_ image: URL, _ body: () throws -> T) throws -> T {
        try hfs("hmount", [image.path])
        defer { _ = try? hfs("humount", []) }
        return try body()
    }

    @discardableResult
    static func hfs(_ tool: String, _ arguments: [String]) throws -> String {
        guard let prefix = hfsutilsPrefix else { throw XCTSkip("hfsutils is not installed") }
        let result = run("\(prefix)/\(tool)", arguments)
        guard result.status == 0 else {
            throw NSError(domain: "Fixtures", code: Int(result.status), userInfo: [NSLocalizedDescriptionKey: "\(tool) \(arguments) failed: \(result.output)"])
        }
        return result.output
    }

    /// Writes `contents` into the mounted volume at `hfsPath`, optionally stamping Finder
    /// type/creator codes, using hfsutils directly (independently of the app under test).
    static func putFile(_ contents: Data, at hfsPath: String, type: String? = nil, creator: String? = nil, scratch: URL) throws {
        let host = scratch.appendingPathComponent(UUID().uuidString)
        try contents.write(to: host)
        defer { try? FileManager.default.removeItem(at: host) }
        try hfs("hcopy", ["-r", host.path, hfsPath])
        if let type, let creator {
            try hfs("hattrib", ["-t", type, "-c", creator, hfsPath])
        }
    }

    /// `hls -l` style line for one entry, e.g. `f  PICT/MDRW         0         9 ...`.
    static func longListing(of hfsPath: String) throws -> String {
        try hfs("hls", ["-dl", hfsPath]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func names(in hfsPath: String) throws -> Set<String> {
        let out = try hfs("hls", ["-a1Q", hfsPath])
        return Set(out.split(separator: "\n").compactMap { DiskImageManager.decodeHLSQuotedName(String($0)) })
    }

    static func readFile(_ hfsPath: String, scratch: URL) throws -> Data {
        let host = scratch.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: host) }
        try hfs("hcopy", ["-r", hfsPath, host.path])
        return try Data(contentsOf: host)
    }

    static func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, "\(error)") }
        // Read before waiting: a child that fills the pipe buffer would otherwise never exit.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, DiskImageManager.decodeProcessOutput(data))
    }
}

@MainActor
extension DiskImageManager {
    /// A manager wired to a private pasteboard, so tests never clobber the developer's real
    /// clipboard and never see stray contents from it.
    static func forTesting() -> DiskImageManager {
        let manager = DiskImageManager()
        manager.pasteboard = NSPasteboard(name: NSPasteboard.Name("com.floppyfox.tests.\(UUID().uuidString)"))
        return manager
    }

    func entry(named name: String, file: StaticString = #filePath, line: UInt = #line) throws -> FileEntry {
        try XCTUnwrap(entries.first { $0.name == name }, "no entry named \(name) in \(entries.map(\.name))", file: file, line: line)
    }
}

/// Fails (rather than hanging the whole test run) when `operation` exceeds `seconds`.
func withTimeout<T: Sendable>(_ seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw NSError(domain: "Timeout", code: 1, userInfo: [NSLocalizedDescriptionKey: "Timed out after \(seconds)s — likely a hang"])
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
