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

    static func makeHFSPlusImage(in directory: URL, name: String = "Plus.dmg", sizeMB: Int = 32, label: String = "FloppyFoxPlus", fileSystem: String = "HFS+") throws -> URL {
        let url = directory.appendingPathComponent(name)
        let result = run("/usr/bin/hdiutil", ["create", "-size", "\(sizeMB)m", "-fs", fileSystem, "-volname", label, url.path])
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
        Set(HLSOutput.names(try hfs("hls", ["-a1Q", hfsPath])))
    }

    static func readFile(_ hfsPath: String, scratch: URL) throws -> Data {
        let host = scratch.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: host) }
        try hfs("hcopy", ["-r", hfsPath, host.path])
        return try Data(contentsOf: host)
    }

    /// Runs Apple's `fsck_hfs -n` (check only, never repair) on a bare HFS volume image and
    /// returns its verdict. Apple's checker validates catalog key order, B-tree structure,
    /// valences, the allocation bitmap and the MDB totals — an oracle independent of both this
    /// app and hfsutils. (It also flags reserved catalog fields hfsutils leaves non-zero, so
    /// only use it on volumes this app alone has written to after `hformat`.)
    static func fsck(_ image: URL) throws -> (clean: Bool, output: String) {
        let attach = run("/usr/bin/hdiutil", ["attach", "-nomount", "-readonly", "-noverify", "-imagekey", "diskimage-class=CRawDiskImage", image.path])
        let lines = attach.output.split(separator: "\n").map(String.init)
        func device(in line: String) -> String? {
            line.split(whereSeparator: \.isWhitespace).first(where: { $0.hasPrefix("/dev/disk") }).map(String.init)
        }
        guard attach.status == 0, let wholeDisk = lines.lazy.compactMap(device).first else {
            // A failure, not a skip: a skipped fsck would hide exactly the problems it checks for.
            throw NSError(domain: "Fixtures", code: 2, userInfo: [NSLocalizedDescriptionKey: "hdiutil could not attach \(image.lastPathComponent) for fsck (is it still open?): \(attach.output)"])
        }
        defer { _ = run("/usr/bin/hdiutil", ["detach", wholeDisk]) }
        // A partitioned image: check its HFS partition rather than the whole disk.
        let target = lines.first(where: { $0.contains("Apple_HFS") }).flatMap(device) ?? wholeDisk
        let check = run("/sbin/fsck_hfs", ["-n", "-d", target.replacingOccurrences(of: "/dev/disk", with: "/dev/rdisk")])
        return (check.status == 0 && check.output.contains("appears to be OK"), check.output)
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
        // Private scratch space, so tests never sweep (or get swept by) a running app.
        let storage = TemporaryStorage(root: FileManager.default.temporaryDirectory.appendingPathComponent("FloppyFoxTests-\(UUID().uuidString)"))
        let manager = DiskImageManager(storage: storage)
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

/// Parsing of hfsutils' `hls -Q` output, used to read results back through the oracle.
enum HLSOutput {
    static func decodeQuotedName(_ line: String) -> String? {
        guard line.first == "\"", line.last == "\"", line.count >= 2 else { return nil }
        let contents = Array(line.dropFirst().dropLast())
        var bytes: [UInt8] = []
        var index = 0
        while index < contents.count {
            let character = contents[index]
            guard character == "\\" else {
                bytes += Array(String(character).data(using: .macOSRoman) ?? Data(String(character).utf8))
                index += 1
                continue
            }
            index += 1
            guard index < contents.count else { return nil }
            let escaped = contents[index]
            switch escaped {
            case "n": bytes.append(0x0A); index += 1
            case "b": bytes.append(0x08); index += 1
            case "r": bytes.append(0x0D); index += 1
            case "t": bytes.append(0x09); index += 1
            case "f": bytes.append(0x0C); index += 1
            case "0"..."7":
                var digits = ""
                while digits.count < 3, index < contents.count, ("0"..."7").contains(contents[index]) {
                    digits.append(contents[index])
                    index += 1
                }
                guard let byte = UInt8(digits, radix: 8) else { return nil }
                bytes.append(byte)
            default:
                bytes += Array(String(escaped).utf8)
                index += 1
            }
        }
        return String(data: Data(bytes), encoding: .macOSRoman)
    }

    /// hls wraps long escaped names over several lines, each fragment ending in `\`.
    static func names(_ output: String) -> [String] {
        var names: [String] = []
        var pending = ""
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasSuffix("\\") {
                pending += line.dropLast()
                continue
            }
            let record = pending + line
            pending = ""
            if let name = decodeQuotedName(record) { names.append(name) }
        }
        return names
    }
}

extension DiskVolume {
    /// The pre-`NewFileMetadata` shape of `createFile`, for brevity in tests.
    @discardableResult
    func createFile(named name: String, in parentID: UInt32, type: [UInt8], creator: [UInt8], dataFork: HFSForkSource, resourceFork: HFSForkSource) throws -> UInt32 {
        try createFile(named: name, in: parentID, metadata: NewFileMetadata(fileType: type, creator: creator), dataFork: dataFork, resourceFork: resourceFork)
    }
}

/// `volume.child(named:inFolder:)`, unwrapped (await can't appear inside XCTUnwrap).
func childItem(_ volume: any DiskVolume, _ name: String, in folder: UInt32, file: StaticString = #filePath, line: UInt = #line) async throws -> VolumeItem {
    let item = await volume.child(named: name, inFolder: folder)
    return try XCTUnwrap(item, "no \(name) in folder \(folder)", file: file, line: line)
}
