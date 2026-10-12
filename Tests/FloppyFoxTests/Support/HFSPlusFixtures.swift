import Foundation
import XCTest

/// Fixtures for HFS Plus volumes. Unlike classic HFS, macOS still mounts HFS Plus itself, so
/// tests can check results with the real kernel driver (mounted read-only) as well as fsck.
enum HFSPlusFixtures {
    /// A blank, non-journaled HFS Plus volume (what Mac OS 8.1–9 writes), made by `newfs_hfs`
    /// on a raw image. `caseSensitive` makes an HFSX volume.
    /// `extraBytes` makes the partition not a whole number of allocation blocks.
    static func makeVolume(in directory: URL, name: String = "Plus.img", sizeMB: Int = 40, extraBytes: Int = 0, label: String = "Plus Test", caseSensitive: Bool = false) throws -> URL {
        let url = directory.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(sizeMB) * 1024 * 1024 + UInt64(extraBytes))
        try handle.close()
        let attach = Fixtures.run("/usr/bin/hdiutil", ["attach", "-nomount", "-noverify", "-imagekey", "diskimage-class=CRawDiskImage", url.path])
        guard attach.status == 0, let device = attach.output.split(whereSeparator: \.isWhitespace).first(where: { $0.hasPrefix("/dev/disk") }).map(String.init) else {
            throw XCTSkip("hdiutil could not attach a blank image: \(attach.output)")
        }
        defer { _ = Fixtures.run("/usr/bin/hdiutil", ["detach", device]) }
        let format = Fixtures.run("/sbin/newfs_hfs", (caseSensitive ? ["-s"] : []) + ["-v", label, device])
        guard format.status == 0 else { throw XCTSkip("newfs_hfs failed: \(format.output)") }
        return url
    }

    /// Mounts `image` read-only (no Finder, no Spotlight), runs `body` with the mount point,
    /// and always detaches.
    static func withMounted<T>(_ image: URL, _ body: (URL) throws -> T) throws -> T {
        let mountPoint = FileManager.default.temporaryDirectory.appendingPathComponent("floppyfox-mnt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: mountPoint) }
        let attach = Fixtures.run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-noautoopen", "-noverify", "-mountpoint", mountPoint.path, "-imagekey", "diskimage-class=CRawDiskImage", image.path])
        guard attach.status == 0, let device = attach.output.split(whereSeparator: \.isWhitespace).first(where: { $0.hasPrefix("/dev/disk") }).map(String.init) else {
            throw NSError(domain: "HFSPlusFixtures", code: 1, userInfo: [NSLocalizedDescriptionKey: "could not mount \(image.lastPathComponent): \(attach.output)"])
        }
        defer { _ = Fixtures.run("/usr/bin/hdiutil", ["detach", device, "-force"]) }
        return try body(mountPoint)
    }

    /// Mounts read-write so a test can populate a volume using macOS itself.
    static func populate(_ image: URL, _ body: (URL) throws -> Void) throws {
        let mountPoint = FileManager.default.temporaryDirectory.appendingPathComponent("floppyfox-mnt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: mountPoint) }
        let attach = Fixtures.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-noautoopen", "-noverify", "-mountpoint", mountPoint.path, "-imagekey", "diskimage-class=CRawDiskImage", image.path])
        guard attach.status == 0, let device = attach.output.split(whereSeparator: \.isWhitespace).first(where: { $0.hasPrefix("/dev/disk") }).map(String.init) else {
            throw NSError(domain: "HFSPlusFixtures", code: 1, userInfo: [NSLocalizedDescriptionKey: "could not mount \(image.lastPathComponent): \(attach.output)"])
        }
        defer { _ = Fixtures.run("/usr/bin/hdiutil", ["detach", device]) }
        try body(mountPoint)
    }
}
