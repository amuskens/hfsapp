import Foundation

/// Reading and writing classic Mac files on the Mac's own filesystem, forks and all: the data
/// fork is the file's normal contents, the resource fork lives at `<file>/..namedfork/rsrc`,
/// and the Finder's type/creator/flags are the `com.apple.FinderInfo` extended attribute.
/// APFS and HFS+ keep all three, so a classic application copied out of an image still has
/// its code and icon, and copying it back in restores it exactly.
enum HostFiles {
    static let finderInfoAttribute = "com.apple.FinderInfo"

    struct Metadata {
        /// 16-byte FInfo (type, creator, flags, location, folder) and 16-byte FXInfo.
        var finderInfo: [UInt8]?
        var extendedFinderInfo: [UInt8]?
        var resourceForkLength: UInt64
        var dataForkLength: UInt64
    }

    static func resourceForkURL(_ url: URL) -> URL {
        URL(fileURLWithPath: url.path + "/..namedfork/rsrc")
    }

    static func metadata(of url: URL) throws -> Metadata {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let dataLength = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        var resourceLength: UInt64 = 0
        if let resourceAttributes = try? FileManager.default.attributesOfItem(atPath: resourceForkURL(url).path) {
            resourceLength = (resourceAttributes[.size] as? NSNumber)?.uint64Value ?? 0
        }
        var finderInfo: [UInt8]?
        var extended: [UInt8]?
        if let raw = extendedAttribute(finderInfoAttribute, of: url), raw.count >= 32 {
            finderInfo = Array(raw[0..<16])
            extended = Array(raw[16..<32])
        }
        return Metadata(finderInfo: finderInfo, extendedFinderInfo: extended, resourceForkLength: resourceLength, dataForkLength: dataLength)
    }

    static func readResourceFork(of url: URL) throws -> [UInt8] {
        guard let data = try? Data(contentsOf: resourceForkURL(url)) else { return [] }
        return Array(data)
    }

    /// Writes a classic file. Finder info is only attached when it says something (a real
    /// type/creator or flags), so ordinary exported documents stay ordinary files.
    static func writeMetadata(to url: URL, resourceFork: [UInt8], finderInfo: [UInt8], extendedFinderInfo: [UInt8], created: Date?, modified: Date?) throws {
        if !resourceFork.isEmpty {
            try Data(resourceFork).write(to: resourceForkURL(url))
        }
        let combined = Array(finderInfo.prefix(16)) + Array(extendedFinderInfo.prefix(16))
        // FInfo's location and folder fields are meaningless on the host; clear them so the
        // Finder doesn't misplace the icon.
        var info = combined + [UInt8](repeating: 0, count: max(0, 32 - combined.count))
        for i in 10..<16 { info[i] = 0 }
        // Worth attaching unless it's all zeroes or just the "????"/"????" placeholder.
        let hasTypeOrCreator = info[0..<8].contains { $0 != 0 && $0 != UInt8(ascii: "?") }
        let hasFlags = info[8..<32].contains { $0 != 0 }
        if hasTypeOrCreator || hasFlags {
            setExtendedAttribute(finderInfoAttribute, value: info, of: url)
        }
        var values = URLResourceValues()
        if let created { values.creationDate = created }
        if let modified { values.contentModificationDate = modified }
        var mutable = url
        try? mutable.setResourceValues(values)
    }

    static func extendedAttribute(_ name: String, of url: URL) -> [UInt8]? {
        let length = getxattr(url.path, name, nil, 0, 0, 0)
        guard length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        let read = getxattr(url.path, name, &buffer, length, 0, 0)
        return read == length ? buffer : nil
    }

    @discardableResult
    static func setExtendedAttribute(_ name: String, value: [UInt8], of url: URL) -> Bool {
        setxattr(url.path, name, value, value.count, 0, 0) == 0
    }
}

/// Positional reads from a host file, shareable with the volume actor while it copies a fork.
final class HostFileReader: @unchecked Sendable {
    private let fd: Int32

    init(url: URL) throws {
        fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    deinit { close(fd) }

    func read(at offset: UInt64, count: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        var done = 0
        while done < count {
            let n = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress! + done, count - done, off_t(offset) + off_t(done)) }
            if n < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if n == 0 { break }
            done += n
        }
        return done == count ? buffer : Array(buffer.prefix(done))
    }
}

/// Sequential writes to a new host file, shareable with the volume actor while it streams a fork.
final class HostFileWriter: @unchecked Sendable {
    private let handle: FileHandle

    init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        handle = try FileHandle(forWritingTo: url)
    }

    deinit { try? handle.close() }

    func write(_ bytes: [UInt8]) throws {
        try handle.write(contentsOf: bytes)
    }

    func close() throws {
        try handle.close()
    }
}

/// A cancel button's state, checked from whichever thread is doing the copying.
final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func check() throws {
        if isCancelled || Task.isCancelled { throw CancellationError() }
    }
}

/// The app's scratch space: `…/tmp/FloppyFox/<pid>-<launch>/`, removed on quit. Anything left
/// behind by a previous run that crashed is swept away at the next launch, so previews and
/// clipboard copies of large files can't pile up across sessions.
final class TemporaryStorage: @unchecked Sendable {
    static let shared = TemporaryStorage()

    let root: URL
    let launchDirectory: URL

    init(root: URL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("FloppyFox", isDirectory: true)) {
        self.root = root
        let pid = ProcessInfo.processInfo.processIdentifier
        launchDirectory = root.appendingPathComponent("\(pid)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: launchDirectory, withIntermediateDirectories: true)
        sweepAbandonedLaunches()
    }

    /// A fresh, empty directory for one purpose (a preview, a clipboard export, …).
    func makeDirectory(_ purpose: String) throws -> URL {
        let url = launchDirectory.appendingPathComponent("\(purpose)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func remove(_ url: URL) {
        guard url.path.hasPrefix(launchDirectory.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Removes this launch's directories whose name starts with `purpose`.
    func removeAll(_ purpose: String) {
        let contents = (try? FileManager.default.contentsOfDirectory(at: launchDirectory, includingPropertiesForKeys: nil)) ?? []
        for url in contents where url.lastPathComponent.hasPrefix("\(purpose)-") {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func removeLaunchDirectory() {
        try? FileManager.default.removeItem(at: launchDirectory)
    }

    /// Deletes directories of launches whose process no longer exists. `kill(pid, 0)` fails
    /// with ESRCH only for a process that is gone (EPERM means it exists but isn't ours —
    /// including under the sandbox — so it is left alone).
    private func sweepAbandonedLaunches() {
        let contents = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for url in contents where url != launchDirectory {
            guard let pidText = url.lastPathComponent.split(separator: "-").first, let pid = Int32(pidText) else { continue }
            if kill(pid, 0) == -1 && errno == ESRCH {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
