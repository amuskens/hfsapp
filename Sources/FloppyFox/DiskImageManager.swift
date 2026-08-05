import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum DiskImageError: LocalizedError {
    case attachmentFailed(String)
    case detachmentFailed(String)
    case missingMountPoint
    case exportFailed(URL, Error)
    case importFailed(URL, Error)
    case deleteFailed(URL, Error)
    case loadDirectoryFailed(URL, Error)

    var errorDescription: String? {
        switch self {
        case .attachmentFailed(let details):
            return "Could not attach image: \(details)"
        case .detachmentFailed(let details):
            return "Could not detach image: \(details)"
        case .missingMountPoint:
            return "Mounted image does not have a valid mount point."
        case .exportFailed(let url, let error):
            return "Could not export \(url.lastPathComponent): \(error.localizedDescription)"
        case .importFailed(let url, let error):
            return "Could not import \(url.lastPathComponent): \(error.localizedDescription)"
        case .deleteFailed(let url, let error):
            return "Could not delete \(url.lastPathComponent): \(error.localizedDescription)"
        case .loadDirectoryFailed(let url, let error):
            return "Could not read \(url.path): \(error.localizedDescription)"
        }
    }
}

enum ClipboardOperation {
    case copy
}

struct FileEntry: Identifiable, Hashable {
    // Identity must be stable across repeated listings of the same directory (the entries
    // array is rebuilt from scratch on every refresh), or List's selection tracking breaks.
    // The URL already uniquely identifies a given file/folder, so use it directly rather
    // than a fresh random UUID per instance.
    var id: String { url.absoluteString }
    let url: URL
    let isDirectory: Bool
    let size: Int?
    // For hfsutils-backed entries: the exact colon-separated HFS path (e.g. ":Lorem Ipsum.doc"),
    // taken verbatim from hls output. This is kept as a plain string rather than being
    // round-tripped through the pseudo-URL's query string, because HFS filenames may contain
    // characters (&, =, +) that are legal unencoded in a URL query component but corrupt
    // parsing when decoded back out via URLComponents. nil for entries on a normally-mounted
    // (real file://) volume, where url.lastPathComponent is already reliable.
    let hfsPath: String?

    init(url: URL, isDirectory: Bool, size: Int?, hfsPath: String? = nil) {
        self.url = url
        self.isDirectory = isDirectory
        self.size = size
        self.hfsPath = hfsPath
    }

    var name: String {
        guard let hfsPath else { return url.lastPathComponent }
        let trimmed = hfsPath.hasSuffix(":") ? String(hfsPath.dropLast()) : hfsPath
        if let lastColon = trimmed.range(of: ":", options: .backwards) {
            return String(trimmed[trimmed.index(after: lastColon.lowerBound)...])
        }
        return trimmed.hasPrefix(":") ? String(trimmed.dropFirst()) : trimmed
    }

    var icon: NSImage? {
        let workspace = NSWorkspace.shared
        if hfsPath != nil {
            let ext = (name as NSString).pathExtension
            if !ext.isEmpty, let type = UTType(filenameExtension: ext) {
                return workspace.icon(for: type)
            }
            return workspace.icon(for: isDirectory ? .folder : .data)
        }
        return workspace.icon(forFile: url.path)
    }

    // Make identity & hash based only on URL so selection remains stable across reloads
    func hash(into hasher: inout Hasher) {
        hasher.combine(url.absoluteString)
    }

    static func == (lhs: FileEntry, rhs: FileEntry) -> Bool {
        return lhs.url == rhs.url
    }
}

private actor URLCollector {
    private var urls: [URL] = []

    func append(_ url: URL) {
        urls.append(url)
    }

    func allURLs() -> [URL] {
        urls
    }
}

extension Notification.Name {
    static let didCreateDiagnosticsFile = Notification.Name("didCreateDiagnosticsFile")
}

@MainActor
final class DiskImageManager: ObservableObject {
    @Published var imageURL: URL?
    @Published var mountPoint: URL?
    @Published var mountedDevice: String?
    @Published var currentDirectory: URL?
    @Published var entries: [FileEntry] = []
    @Published var selectedEntry: FileEntry?
    @Published var errorMessage: String?
    @Published var statusMessage: String = "No image loaded"
    @Published var pasteboardContents: [URL] = []
    // True while a background hdiutil/hfsutils/Finder operation is in flight, so the UI can
    // show a lightweight progress indicator instead of the whole app looking frozen.
    @Published var isBusy: Bool = false
    // Set when the currently-open image is read-only, either because its file permissions
    // don't allow writing or because another program (e.g. an emulator) already has it open.
    // Write operations (add/paste/delete) check this and refuse to run.
    @Published var isReadOnly: Bool = false
    @Published var readOnlyReason: String?
    // One-shot informational warning (distinct from `errorMessage`, which represents a failed
    // action) — currently only used to tell the user an image was opened read-only and why.
    @Published var warningMessage: String?

    // For hfsutils-based backend when the image cannot be mounted
    @Published var currentHFSPath: String? = ":" // ':' denotes root for hfsutils

    private let fileManager = FileManager.default
    private var internalClipboardURL: URL?
    private var internalClipboardOperation: ClipboardOperation = .copy
    private var busyDepth = 0

    var isMounted: Bool {
        mountPoint != nil
    }

    var usingHFSUtils: Bool {
        !isMounted && imageURL != nil && hfsutilsAvailable
    }

    // hfsutils paths (discovered at runtime)
    private var hmountPath: String? = nil
    private var hlsPath: String? = nil
    private var hcopyPath: String? = nil
    private var hdelPath: String? = nil
    private var hmkdirPath: String? = nil
    private var humountPath: String? = nil

    // Once we've confirmed (for the currently-open image) that no hdiutil device is attached
    // and the file isn't locked, there's no need to re-run that hdiutil-info/lsof check before
    // every single hls/hcopy/hdel call — that redundant work was the main reason every click
    // felt sluggish. Reset whenever a new image is opened or the current one is closed.
    private var hfsUtilsPrepared = false

    // Bumped every time an image is opened, ejected, or detached. Long-running background
    // operations (a directory listing, say) capture the value that was current when they
    // started and check it again before writing their result into @Published state — if it's
    // stale (e.g. the user ejected while the listing was still in flight), the result is
    // silently discarded instead of resurrecting a browser view for an image that's no longer
    // open. Without this, a slow operation finishing after Eject could make Eject look like it
    // didn't work.
    private var sessionID = UUID()

    private var hfsutilsAvailable: Bool {
        if hmountPath != nil { return true }
        // probe known locations
        let candidates = ["/opt/homebrew/bin/hmount", "/usr/local/bin/hmount", "/usr/bin/hmount"]
        for cand in candidates {
            if fileManager.isExecutableFile(atPath: cand) {
                hmountPath = cand
                break
            }
        }
        guard hmountPath != nil else { return false }
        // set other tools by same prefix
        let prefix = (hmountPath! as NSString).deletingLastPathComponent
        let map = ["hls", "hcopy", "hdel", "hmkdir", "humount"]
        for tool in map {
            let p = "\(prefix)/\(tool)"
            if fileManager.isExecutableFile(atPath: p) {
                switch tool {
                case "hls": hlsPath = p
                case "hcopy": hcopyPath = p
                case "hdel": hdelPath = p
                case "hmkdir": hmkdirPath = p
                case "humount": humountPath = p
                default: break
                }
            }
        }
        // fallback to /opt/homebrew/bin for others
        if hlsPath == nil { hlsPath = fileManager.isExecutableFile(atPath: "/opt/homebrew/bin/hls") ? "/opt/homebrew/bin/hls" : "/usr/local/bin/hls" }
        if hcopyPath == nil { hcopyPath = fileManager.isExecutableFile(atPath: "/opt/homebrew/bin/hcopy") ? "/opt/homebrew/bin/hcopy" : "/usr/local/bin/hcopy" }
        if hdelPath == nil { hdelPath = fileManager.isExecutableFile(atPath: "/opt/homebrew/bin/hdel") ? "/opt/homebrew/bin/hdel" : "/usr/local/bin/hdel" }
        if hmkdirPath == nil { hmkdirPath = fileManager.isExecutableFile(atPath: "/opt/homebrew/bin/hmkdir") ? "/opt/homebrew/bin/hmkdir" : "/usr/local/bin/hmkdir" }
        if humountPath == nil { humountPath = fileManager.isExecutableFile(atPath: "/opt/homebrew/bin/humount") ? "/opt/homebrew/bin/humount" : "/usr/local/bin/humount" }
        return true
    }

    var canGoBack: Bool {
        if let currentDirectory, let mountPoint {
            return currentDirectory.path != mountPoint.path
        }
        if usingHFSUtils, let currentHFSPath {
            return currentHFSPath != ":"
        }
        return false
    }

    /// Marks `isBusy` for the duration of `work`. Reentrant (tracked via a depth counter) so
    /// nested calls (e.g. `exportSelected` awaiting `prepareForHFSUtils`) don't cause the
    /// indicator to flicker off before the outermost operation actually finishes.
    private func withBusy<T>(_ work: () async throws -> T) async rethrows -> T {
        busyDepth += 1
        isBusy = true
        defer {
            busyDepth -= 1
            if busyDepth <= 0 {
                busyDepth = 0
                isBusy = false
            }
        }
        return try await work()
    }

    func openImage() {
        let panel = NSOpenPanel()
        // .hda is the raw hard disk image extension BlueSCSI (and similar SCSI emulators) use;
        // structurally it's just another raw disk image, same as .img — hdiutil/hfsutils don't
        // care about the extension at all, so allowing it here is the only change needed.
        panel.allowedContentTypes = [UTType(filenameExtension: "dsk"), UTType(filenameExtension: "img"), UTType(filenameExtension: "hda")].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Open HFS Disk Image"
        panel.message = "Choose a .dsk, .img, or .hda file formatted with the Apple HFS filesystem."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await attachImage(imageURL: url) }
    }

    func attachImage(imageURL: URL) async {
        await withBusy {
            await detachImageIfMounted()
            hfsUtilsPrepared = false

            let reason = await detectReadOnlyReason(for: imageURL.path)
            self.isReadOnly = reason != nil
            self.readOnlyReason = reason

            do {
                let result = try await attachImageUsingHdiutil(imageURL, readOnly: self.isReadOnly)
                guard let mountPoint = result.mountPoint else {
                    throw DiskImageError.missingMountPoint
                }
                self.imageURL = imageURL
                self.mountPoint = mountPoint
                self.mountedDevice = result.device
                self.currentDirectory = mountPoint
                self.statusMessage = self.isReadOnly ? "Mounted read-only at \(mountPoint.path)" : "Mounted at \(mountPoint.path)"
                self.errorMessage = nil
                try await loadDirectory(at: mountPoint)
            } catch {
                // macOS's Disk Arbitration/hdiutil stack cannot mount classic HFS Standard
                // volumes at all (common for real floppy images, which also usually lack a
                // partition table). Fall back to the userspace hfsutils backend, which reads
                // the raw image bytes directly and doesn't depend on kernel filesystem support.
                await attachImageUsingHFSUtilsFallback(imageURL, hdiutilError: error)
            }

            // Only surface the warning if the image actually ended up open — a read-only file
            // that also fails to mount at all should just show its normal attach error instead.
            if let reason, self.imageURL != nil {
                self.warningMessage = reason
            }
        }
    }

    private func attachImageUsingHFSUtilsFallback(_ imageURL: URL, hdiutilError: Error) async {
        self.mountPoint = nil
        self.mountedDevice = nil
        self.currentDirectory = nil

        guard hfsutilsAvailable else {
            self.imageURL = nil
            self.errorMessage = hdiutilError.localizedDescription
            self.statusMessage = "Failed to mount image"
            return
        }

        self.imageURL = imageURL
        self.currentHFSPath = ":"
        do {
            try await loadDirectory(at: URL(fileURLWithPath: "/"))
            self.statusMessage = self.isReadOnly
                ? "Opened read-only via hfsutils (macOS could not mount this volume directly)"
                : "Opened via hfsutils (macOS could not mount this volume directly)"
            self.errorMessage = nil
        } catch {
            self.imageURL = nil
            self.currentHFSPath = ":"
            self.errorMessage = error.localizedDescription
            self.statusMessage = "Failed to mount image"
        }
    }

    private func attachImageUsingHdiutil(_ imageURL: URL, readOnly: Bool) async throws -> (mountPoint: URL?, device: String?) {
        let accessFlag = readOnly ? "-readonly" : "-readwrite"

        // First try the normal attach that auto-detects filesystem and mounts.
        let options = ["attach", accessFlag, "-noverify", "-nobrowse", "-noautoopen", "-plist", imageURL.path]
        do {
            let res = try await runHdiutil(arguments: options)
            if res.mountPoint != nil { return res }
            // If no mount point but a device was returned, continue to try mounting partitions below.
            if let device = res.device {
                if let mp = try await tryMountPartitions(of: device) {
                    return (mp, device)
                }
            }
        } catch {
            // fallthrough to try raw image class below
        }

        // Some raw disk images need the raw disk image class; try attaching that way.
        let rawOptions = ["attach", accessFlag, "-noverify", "-nobrowse", "-noautoopen", "-imagekey", "diskimage-class=CRawDiskImage", "-plist", imageURL.path]
        do {
            let res = try await runHdiutil(arguments: rawOptions)
            if res.mountPoint != nil { return res }
            if let device = res.device {
                if let mp = try await tryMountPartitions(of: device) {
                    return (mp, device)
                }
            }
        } catch {
            // final fallback: try attach nomount then mount partitions explicitly
        }

        // Try attach nomount + mount HFS partitions explicitly as a final fallback.
        let nomountOptions = ["attach", "-nomount", accessFlag, "-noverify", "-nobrowse", "-noautoopen", "-imagekey", "diskimage-class=CRawDiskImage", "-plist", imageURL.path]
        let nomountRes = try await runHdiutil(arguments: nomountOptions)
        if let device = nomountRes.device {
            if let mp = try await tryMountPartitions(of: device) {
                return (mp, device)
            }
            // If we couldn't mount partitions, detach the raw device and fail.
            _ = try? await runHdiutil(arguments: ["detach", device])
        }

        throw DiskImageError.attachmentFailed("hdiutil could not find a mountable HFS partition in the image.")
    }

    /// Runs `executable` with `arguments` on a background thread so callers never block the
    /// main run loop (the actual per-call latency is usually small, but doing this synchronously
    /// on the main thread is what made every click feel like a beachball).
    private nonisolated func runProcess(_ executable: String, _ arguments: [String]) async -> (String, String, Int32) {
        await Task.detached(priority: .userInitiated) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: executable)
            proc.arguments = arguments
            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            do {
                try proc.run()
                proc.waitUntilExit()
                let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                return (out, err, proc.terminationStatus)
            } catch {
                return ("", "\(error)", Int32(-1))
            }
        }.value
    }

    private nonisolated func runCommand(_ cmd: [String]) async -> (String, String, Int32) {
        await runProcess(cmd[0], Array(cmd.dropFirst()))
    }

    /// Try to find HFS partitions on the attached device using `diskutil` and mount the first mountable HFS partition.
    private nonisolated func tryMountPartitions(of device: String) async throws -> URL? {
        // Normalize device to device identifier (e.g., /dev/disk2 -> disk2)
        let deviceIdentifier = URL(fileURLWithPath: device).lastPathComponent

        let (out, _, code) = await runProcess("/usr/sbin/diskutil", ["list", "-plist", deviceIdentifier])
        guard code == 0, let data = out.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }

        // The structure has 'AllDisksAndPartitions' with entries that include 'DeviceIdentifier' and 'Partitions'
        guard let all = plist["AllDisksAndPartitions"] as? [[String: Any]],
              let target = all.first(where: { ($0["DeviceIdentifier"] as? String) == deviceIdentifier }) else {
            return nil
        }

        // Search partitions for Apple_HFS content
        if let partitions = target["Partitions"] as? [[String: Any]] {
            for part in partitions {
                if let content = part["Content"] as? String, content.contains("Apple_HFS") || content.contains("Apple_HFSX") {
                    if let pdid = part["DeviceIdentifier"] as? String {
                        if let mountRes = try await mountPartition("/dev/\(pdid)") {
                            return mountRes
                        }
                    }
                }
            }
        }

        return nil
    }

    private nonisolated func mountPartition(_ devicePath: String) async throws -> URL? {
        let (_, _, mountCode) = await runProcess("/usr/sbin/diskutil", ["mount", devicePath])
        guard mountCode == 0 else { return nil }

        let (infoOut, _, infoCode) = await runProcess("/usr/sbin/diskutil", ["info", "-plist", devicePath])
        guard infoCode == 0, let data = infoOut.data(using: .utf8),
              let infoPlist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let mp = infoPlist["MountPoint"] as? String else {
            return nil
        }
        return URL(fileURLWithPath: mp)
    }

    private nonisolated func runHdiutil(arguments: [String]) async throws -> (mountPoint: URL?, device: String?) {
        let (outputText, errorText, code) = await runProcess("/usr/bin/hdiutil", arguments)

        guard code == 0 else {
            throw DiskImageError.attachmentFailed(errorText.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // Try parse plist output safely - sometimes hdiutil returns non-plist or empty output
        var plistAny: Any?
        if let data = outputText.data(using: .utf8), !data.isEmpty {
            plistAny = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        }

        var mountPointURL: URL?
        var device: String?

        if let plist = plistAny as? [String: Any], let entities = plist["system-entities"] as? [[String: Any]] {
            for entity in entities {
                if mountPointURL == nil, let path = entity["mount-point"] as? String {
                    mountPointURL = URL(fileURLWithPath: path)
                    device = entity["dev-entry"] as? String
                    break
                }
                if device == nil, let dev = entity["dev-entry"] as? String {
                    device = dev
                }
            }
        } else {
            // If no plist parsed, try to scan stdout text for /dev/diskN
            let regex = try? NSRegularExpression(pattern: "/dev/disk\\\\d+", options: [])
            if let matches = regex?.matches(in: outputText, options: [], range: NSRange(location: 0, length: outputText.utf16.count)), let m = matches.first, let range = Range(m.range, in: outputText) {
                device = String(outputText[range])
            }
        }

        return (mountPointURL, device)
    }

    // Find attachments for an image path by querying hdiutil info -plist and parsing for devices referencing the image
    private nonisolated func findAttachedDevices(for imagePath: String) async -> [String] {
        let (out, _, code) = await runProcess("/usr/bin/hdiutil", ["info", "-plist"])
        guard code == 0 else { return [] }

        var devices: [String] = []
        if let data = out.data(using: .utf8), let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
            // Recursively walk plist to find dicts that contain our image path and collect their dev-entry values
            func walk(_ any: Any) {
                if let dict = any as? [String: Any] {
                    // If this dict seems to reference our image path
                    for (_, v) in dict {
                        if let s = v as? String, s == imagePath || s.contains(imagePath) {
                            // look for dev-entry or device
                            if let dev = dict["dev-entry"] as? String {
                                devices.append(dev)
                            }
                            if let sysEnt = dict["system-entities"] as? [[String: Any]] {
                                for e in sysEnt {
                                    if let dev = e["dev-entry"] as? String { devices.append(dev) }
                                }
                            }
                        }
                    }
                    // continue walking
                    for (_, v) in dict { walk(v) }
                } else if let arr = any as? [Any] {
                    for item in arr { walk(item) }
                }
            }
            walk(plist)
        } else {
            // fallback: find lines where image path appears and search nearby for /dev/diskN
            let lines = out.split(separator: "\n").map { String($0) }
            for (i, line) in lines.enumerated() {
                if line.contains(imagePath) {
                    let start = max(0, i-6)
                    let end = min(lines.count-1, i+1)
                    let window = lines[start...end].joined(separator: "\n")
                    let regex = try? NSRegularExpression(pattern: "/dev/disk\\\\d+", options: [])
                    if let matches = regex?.matches(in: window, options: [], range: NSRange(location: 0, length: window.utf16.count)) {
                        for m in matches {
                            if let range = Range(m.range, in: window) {
                                let dev = String(window[range])
                                devices.append(dev)
                            }
                        }
                    }
                }
            }
        }
        return Array(Set(devices))
    }

    private var tempImageCopyURL: URL? = nil
    @Published var confirmBeforeDetach: Bool = false {
        didSet {
            UserDefaults.standard.set(confirmBeforeDetach, forKey: "confirmBeforeDetach")
        }
    }

    init() {
        // Load persisted preference
        self.confirmBeforeDetach = UserDefaults.standard.bool(forKey: "confirmBeforeDetach")
    }

    private func prepareForHFSUtils(imagePath: String) async throws {
        if hfsUtilsPrepared { return }

        let attached = await findAttachedDevices(for: imagePath)
        if !attached.isEmpty {
            if confirmBeforeDetach {
                // Ask user for confirmation before detaching
                let alert = NSAlert()
                alert.messageText = "Detach device(s) for image?"
                alert.informativeText = "The image appears to be attached as raw device(s): \(attached.joined(separator: ", ")).\nDetaching them is required to allow exclusive access for HFS operations. Detaching is safe but will unmount the raw device. Proceed?"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Detach")
                alert.addButton(withTitle: "Use Temporary Copy")
                alert.addButton(withTitle: "Cancel")

                let resp = alert.runModal()
                if resp == .alertFirstButtonReturn {
                    // user chose Detach: proceed
                    for dev in attached {
                        do {
                            try await runHdiutilDetach(device: dev)
                            print("Detached \(dev) for image \(imagePath)")
                        } catch {
                            print("Failed to detach \(dev): \(error)")
                            // continue trying others
                        }
                    }
                } else if resp == .alertSecondButtonReturn {
                    // Use temporary copy instead of detaching
                    try await createTempCopyAndUse(imagePath: imagePath)
                    hfsUtilsPrepared = true
                    return
                } else {
                    // Cancel: throw to abort the hfsutils operation
                    throw NSError(domain: "HFSApp", code: 1, userInfo: [NSLocalizedDescriptionKey: "User cancelled detaching devices"]) as Error
                }
            } else {
                // Auto-detach behavior (existing behavior)
                for dev in attached {
                    do {
                        try await runHdiutilDetach(device: dev)
                        print("Detached \(dev) for image \(imagePath)")
                    } catch {
                        print("Failed to detach \(dev): \(error)")
                        // continue trying others
                    }
                }
            }
        }

        // Wait until the file is no longer held open by any process. If it remains locked, fall back to operating on a temporary copy.
        if await !isFileUnlocked(path: imagePath, timeout: 5.0) {
            // Create a temporary copy and operate on it to avoid locks
            try await createTempCopyAndUse(imagePath: imagePath)
        }
        hfsUtilsPrepared = true
    }

    private func createTempCopyAndUse(imagePath: String) async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hfsapp-temp-\(UUID().uuidString).img")
        do {
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.copyItem(atPath: imagePath, toPath: tmp.path)
            }.value
            tempImageCopyURL = tmp
            statusMessage = "Using temporary copy for image operations"
            print("Created temp copy at \(tmp.path) due to lock on original image")
        } catch {
            print("Failed to create temp copy: \(error)")
            throw error
        }
    }

    private func imagePathToUse(original: String) -> String {
        if let tmp = tempImageCopyURL { return tmp.path }
        return original
    }

    private func cleanupTempCopyIfAny() {
        if let tmp = tempImageCopyURL {
            try? fileManager.removeItem(at: tmp)
            tempImageCopyURL = nil
            statusMessage = "Removed temporary copy"
        }
    }

    private nonisolated func isFileUnlocked(path: String, timeout: TimeInterval) async -> Bool {
        // Poll lsof to check whether any process holds the file open
        let interval: TimeInterval = 0.2
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let (out, err, code) = await runProcess("/usr/sbin/lsof", [path])
            if code != 0 {
                // If lsof returns non-zero and no output, assume no process holds it
                if out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return true
                }
            } else {
                // code == 0; if output empty, unlocked
                if out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return true
                }
            }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        return false
    }

    /// Checked once, up front, when opening an image — separate from (and much cheaper than)
    /// `isFileUnlocked`'s polling loop, which exists for a different purpose (waiting out a
    /// transient lock before falling back to a temp copy mid-session). This is a single quick
    /// check so we can decide *before* attaching whether to open read-only and tell the user
    /// why, rather than silently discovering it later.
    private nonisolated func detectReadOnlyReason(for imagePath: String) async -> String? {
        if !FileManager.default.isWritableFile(atPath: imagePath) {
            return "This image's file permissions don't allow writing, so it was opened read-only."
        }
        let (out, _, code) = await runProcess("/usr/sbin/lsof", [imagePath])
        if code == 0, !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "This image is currently open in another program (e.g. an emulator like Mini vMac), so it was opened read-only to avoid conflicting changes."
        }
        return nil
    }

    func detachImageIfMounted() async {
        if let device = mountedDevice {
            do {
                try await runHdiutilDetach(device: device)
            } catch {
                // If detach fails, ignore here because a new mount may still work.
            }
            // Bumped here, immediately before clearing state and with no `await` in between,
            // rather than at the top of this function: bumping earlier would leave a window
            // (while the `await` above was in flight) where some other in-flight listing could
            // capture the *already-bumped* sessionID as its own baseline, pass the staleness
            // check, and then write its result right after — undoing the clear below.
            sessionID = UUID()
            mountedDevice = nil
            mountPoint = nil
            currentDirectory = nil
            entries = []
            selectedEntry = nil
            hfsUtilsPrepared = false
            isReadOnly = false
            readOnlyReason = nil
            statusMessage = "Image detached"
            return
        }

        if imageURL != nil {
            // Previous image was hfsutils-backed (no real device to detach); make sure its
            // lock is released and its temp copy cleaned up before attaching a new image.
            if let humount = humountPath {
                _ = await runCommand([humount])
            }
            sessionID = UUID()
            cleanupTempCopyIfAny()
            imageURL = nil
            entries = []
            selectedEntry = nil
            currentHFSPath = ":"
            hfsUtilsPrepared = false
            isReadOnly = false
            readOnlyReason = nil
        }
    }

    func ejectImage() async {
        await withBusy {
            if let device = mountedDevice {
                do {
                    try await runHdiutilDetach(device: device)
                    // See the comment in `detachImageIfMounted` on why this is bumped here,
                    // right alongside the clear, rather than before the `await` above.
                    sessionID = UUID()
                    mountPoint = nil
                    mountedDevice = nil
                    currentDirectory = nil
                    entries = []
                    selectedEntry = nil
                    hfsUtilsPrepared = false
                    isReadOnly = false
                    readOnlyReason = nil
                    statusMessage = "Image ejected"
                    errorMessage = nil
                } catch {
                    self.errorMessage = error.localizedDescription
                    statusMessage = "Failed to eject image"
                }
                return
            }

            if usingHFSUtils {
                // Best-effort: explicitly release the hfsutils-level lock rather than relying
                // on it being implicitly dropped when the last hmount/hcopy/hdel process
                // exited, in case anything is still outstanding.
                if let humount = humountPath {
                    _ = await runCommand([humount])
                }
                sessionID = UUID()
                cleanupTempCopyIfAny()
                imageURL = nil
                entries = []
                selectedEntry = nil
                currentHFSPath = ":"
                hfsUtilsPrepared = false
                isReadOnly = false
                readOnlyReason = nil
                statusMessage = "Image ejected"
                errorMessage = nil
            }
        }
    }

    private nonisolated func runHdiutilDetach(device: String) async throws {
        // Try a normal detach, then fall back to force detach and diskutil if necessary
        let (_, normalErr, normalCode) = await runProcess("/usr/bin/hdiutil", ["detach", device])
        if normalCode == 0 { return }

        let (_, forceErr, forceCode) = await runProcess("/usr/bin/hdiutil", ["detach", "-force", device])
        if forceCode == 0 { return }

        let (_, _, diskutilCode) = await runProcess("/usr/sbin/diskutil", ["unmountDisk", "force", device])
        if diskutilCode == 0 { return }

        // If all attempts failed, surface the last error message
        let lastErr = forceErr.isEmpty ? normalErr : forceErr
        throw DiskImageError.detachmentFailed(lastErr.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func loadDirectory(at url: URL) async throws {
        // Captured so that if the image gets ejected (or a different one opened) while this
        // listing is still in flight, we can tell our result is stale and discard it instead
        // of clobbering the now-current (possibly empty) state — see `sessionID`.
        let session = sessionID

        // If the image is mounted normally, use FileManager
        if isMounted {
            let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
            let entries = try await Task.detached(priority: .userInitiated) {
                let directoryContents = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: resourceKeys, options: [.skipsHiddenFiles])
                return try directoryContents.map { itemURL -> FileEntry in
                    let resourceValues = try itemURL.resourceValues(forKeys: Set(resourceKeys))
                    let isDirectory = resourceValues.isDirectory ?? false
                    let fileSize = resourceValues.fileSize
                    return FileEntry(url: itemURL, isDirectory: isDirectory, size: fileSize)
                }
            }.value
            guard session == sessionID else { return }

            self.entries = entries.sorted { first, second in
                if first.isDirectory == second.isDirectory {
                    return first.name.lowercased() < second.name.lowercased()
                }
                return first.isDirectory && !second.isDirectory
            }
            self.currentDirectory = url
            self.currentHFSPath = ":"
            self.errorMessage = nil
            return
        }

        // Otherwise, if hfsutils is available, use it
        guard let image = imageURL, hfsutilsAvailable else {
            throw DiskImageError.loadDirectoryFailed(url, NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError, userInfo: [NSLocalizedDescriptionKey: "No available backend to read directory"]))
        }

        let hfsPath = currentHFSPath ?? ":"
        let list = try await hfsList(path: hfsPath, imagePath: image.path)
        guard session == sessionID else { return }
        self.entries = list
        self.currentDirectory = nil
        self.errorMessage = nil
    }

    func refresh() async {
        await withBusy {
            if let currentDirectory {
                do {
                    try await loadDirectory(at: currentDirectory)
                } catch {
                    self.errorMessage = DiskImageError.loadDirectoryFailed(currentDirectory, error).localizedDescription
                }
            } else if usingHFSUtils {
                do {
                    try await loadDirectory(at: URL(fileURLWithPath: "/"))
                } catch {
                    self.errorMessage = DiskImageError.loadDirectoryFailed(URL(fileURLWithPath: "/"), error).localizedDescription
                }
            }
        }
    }

    func navigate(into entry: FileEntry) async {
        guard entry.isDirectory else { return }
        await withBusy {
            do {
                if isMounted {
                    try await loadDirectory(at: entry.url)
                } else if usingHFSUtils {
                    // update currentHFSPath and load via hfsutils
                    if let current = currentHFSPath {
                        // append entry name to path
                        let newPath = current.hasSuffix(":" ) ? "\(current)\(entry.name)" : "\(current):\(entry.name)"
                        currentHFSPath = newPath
                    } else {
                        currentHFSPath = ":\(entry.name)"
                    }
                    try await loadDirectory(at: URL(fileURLWithPath: "/"))
                }
                selectedEntry = nil
            } catch {
                self.errorMessage = DiskImageError.loadDirectoryFailed(entry.url, error).localizedDescription
            }
        }
    }

    func goUp() async {
        await withBusy {
            if isMounted {
                guard let currentDirectory, let mountPoint else { return }
                guard currentDirectory.path != mountPoint.path else { return }
                let parent = currentDirectory.deletingLastPathComponent()
                if parent.path.hasPrefix(mountPoint.path) {
                    do {
                        try await loadDirectory(at: parent)
                        selectedEntry = nil
                    } catch {
                        self.errorMessage = DiskImageError.loadDirectoryFailed(parent, error).localizedDescription
                    }
                }
            } else if usingHFSUtils {
                // go up in HFS path
                if let path = currentHFSPath, path != ":" {
                    if let idx = path.range(of: ":", options: .backwards)?.lowerBound {
                        let trimmed = String(path[..<idx])
                        currentHFSPath = trimmed.isEmpty ? ":" : trimmed
                    } else {
                        currentHFSPath = ":"
                    }
                    do {
                        try await loadDirectory(at: URL(fileURLWithPath: "/"))
                        selectedEntry = nil
                    } catch {
                        self.errorMessage = DiskImageError.loadDirectoryFailed(URL(fileURLWithPath: "/"), error).localizedDescription
                    }
                }
            }
        }
    }

    func deleteSelected() {
        guard let selectedEntry else { return }
        Task { await deleteEntry(selectedEntry) }
    }

    func deleteEntry(_ entry: FileEntry) async {
        guard !isReadOnly else {
            self.errorMessage = "This image is read-only, so \(entry.name) can't be deleted."
            return
        }
        await withBusy {
            if isMounted {
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try FileManager.default.removeItem(at: entry.url)
                    }.value
                    if selectedEntry?.url == entry.url {
                        selectedEntry = nil
                    }
                    await refresh()
                    statusMessage = "Deleted \(entry.name)"
                } catch {
                    self.errorMessage = DiskImageError.deleteFailed(entry.url, error).localizedDescription
                }
                return
            }

            // hfsutils backend
            guard usingHFSUtils, let image = imageURL, let hdel = hdelPath, let hmount = hmountPath else {
                self.errorMessage = "Delete not supported for this backend"
                return
            }

            // Build HFS path
            let hfsPath = pathForEntry(entry)
            let humount = humountPath ?? hmount
            // hmount, hdel, and humount run as separate calls (not `a && b && c` in one shell
            // string) so humount always runs even if hdel fails — otherwise a failed delete
            // would leave the volume locked from hfsutils's point of view until something else
            // happened to humount it.
            let (mountOut, mountErr, mountCode) = await runCommand([hmount, image.path])
            guard mountCode == 0 else {
                errorMessage = "hmount failed: \(mountErr.isEmpty ? mountOut : mountErr)"
                return
            }
            let (out, err, code) = await runCommand([hdel, hfsPath])
            _ = await runCommand([humount])
            if code == 0 {
                statusMessage = "Deleted \(entry.name)"
                await refresh()
            } else {
                errorMessage = "hdel failed: \(err.isEmpty ? out : err)"
            }
        }
    }

    func copySelected() {
        guard let selectedEntry else { return }
        copyEntry(selectedEntry)
    }

    func copyEntry(_ entry: FileEntry) {
        if isMounted {
            internalClipboardURL = entry.url
            internalClipboardOperation = .copy
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([entry.url as NSURL])
            statusMessage = "Copied \(entry.name)"
            return
        }
        // For hfsutils backend, store HFS path as pseudo-URL using scheme hfs://
        guard usingHFSUtils else { return }
        let hfsPath = pathForEntry(entry)
        if let image = imageURL {
            let pseudo = URL(string: "hfs://localhost\(image.path)?path=\(hfsPath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? hfsPath)")
            internalClipboardURL = pseudo
            internalClipboardOperation = .copy
            statusMessage = "Copied \(entry.name)"
        }
    }

    func paste() {
        guard let target = currentDirectory ?? mountPoint ?? (usingHFSUtils ? URL(fileURLWithPath: "/") : nil) else { return }
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            Task { await importFiles(urls: urls, destination: target) }
            return
        }
        if let source = internalClipboardURL {
            Task { await importFiles(urls: [source], destination: target) }
            return
        }
    }

    func addFiles() {
        guard let target = currentDirectory ?? mountPoint ?? (usingHFSUtils ? URL(fileURLWithPath: "/") : nil) else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.title = "Add Files to Volume"
        panel.message = "Choose files or folders to copy into the mounted HFS volume."

        guard panel.runModal() == .OK else { return }
        Task { await importFiles(urls: panel.urls, destination: target) }
    }

    /// Run diagnostic commands against the provided disk image and write the combined output to a temp file. The file path is returned.
    func runDiagnostics(on imageURL: URL) async -> URL? {
        await withBusy {
            // Running diagnostics may take a while; ensure UI has time to update
            statusMessage = "Running diagnostics..."
            defer { statusMessage = "Diagnostics complete" }
            var combined = "Diagnostics for \(imageURL.path)\n\n"
            let cmds: [[String]] = [
                ["/usr/bin/hdiutil", "attach", "-plist", imageURL.path],
                ["/usr/bin/hdiutil", "attach", "-imagekey", "diskimage-class=CRawDiskImage", "-plist", imageURL.path],
                ["/usr/bin/hdiutil", "attach", "-nomount", "-imagekey", "diskimage-class=CRawDiskImage", "-plist", imageURL.path],
                ["/usr/bin/hdiutil", "imageinfo", imageURL.path]
            ]

            for cmd in cmds {
                combined += "$ \(cmd.joined(separator: " "))\n"
                let (out, err, code) = await runCommand(cmd)
                combined += "Exit: \(code)\n"
                if !out.isEmpty { combined += "STDOUT:\n\(out)\n" }
                if !err.isEmpty { combined += "STDERR:\n\(err)\n" }
                combined += "---\n\n"

                // `attach` (including -nomount) leaves the device attached even when no
                // filesystem is mountable. Detach it again immediately so diagnostics doesn't
                // leak raw devices, and so the hfsutils probe below isn't blocked by the lock.
                if code == 0, cmd.contains("attach"), let device = extractDeviceEntry(from: out) {
                    _ = await runCommand(["/usr/bin/hdiutil", "detach", device])
                }
            }

            // Also clean up any devices left attached by earlier (e.g. pre-fix) diagnostics
            // runs or failed attach attempts, so the hfsutils probe below has exclusive access.
            for device in await findAttachedDevices(for: imageURL.path) {
                _ = await runCommand(["/usr/bin/hdiutil", "detach", device])
            }

            // If hfsutils installed, try a quick hfsutils probe (hmount+hls), always humounting
            // afterward (as separate calls, not `a && b && c`) so this probe can't itself leave
            // the volume locked if hls fails.
            if FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/hmount") || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/hmount") {
                let hmountPath = FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/hmount") ? "/opt/homebrew/bin/hmount" : "/usr/local/bin/hmount"
                let hlsPath = FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/hls") ? "/opt/homebrew/bin/hls" : "/usr/local/bin/hls"
                let humountPath = FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/humount") ? "/opt/homebrew/bin/humount" : "/usr/local/bin/humount"
                combined += "$ \(hmountPath) 'image' && \(hlsPath) ':' && \(humountPath)\n"
                let (mountOut, mountErr, mountCode) = await runCommand([hmountPath, imageURL.path])
                if mountCode == 0 {
                    let (out, err, code) = await runCommand([hlsPath, ":"])
                    _ = await runCommand([humountPath])
                    combined += "Exit: \(code)\n"
                    if !out.isEmpty { combined += "STDOUT:\n\(out)\n" }
                    if !err.isEmpty { combined += "STDERR:\n\(err)\n" }
                } else {
                    combined += "Exit: \(mountCode)\n"
                    if !mountOut.isEmpty { combined += "STDOUT:\n\(mountOut)\n" }
                    if !mountErr.isEmpty { combined += "STDERR:\n\(mountErr)\n" }
                }
                combined += "---\n\n"
            }

            // Write to temporary file
            let timestamp = Int(Date().timeIntervalSince1970)
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hfsapp-diagnostics-\(timestamp).txt")
            do {
                try combined.write(to: tmp, atomically: true, encoding: .utf8)
                NotificationCenter.default.post(name: .didCreateDiagnosticsFile, object: tmp)
                return tmp
            } catch {
                self.errorMessage = "Could not write diagnostics: \(error.localizedDescription)"
                return nil
            }
        }
    }

    private nonisolated func extractDeviceEntry(from plistOutput: String) -> String? {
        guard let data = plistOutput.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else { return nil }
        for entity in entities {
            if let dev = entity["dev-entry"] as? String { return dev }
        }
        return nil
    }

    func exportSelected() async {
        await withBusy {
            // if using hfsutils, ensure no hdiutil attached device blocks the file
            if usingHFSUtils, let image = imageURL {
                try? await prepareForHFSUtils(imagePath: image.path)
            }
            guard let selectedEntry else { return }
            if !isMounted && selectedEntry.isDirectory {
                self.errorMessage = "Exporting folders isn't supported yet; only individual files can be exported."
                return
            }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = selectedEntry.name
            panel.canCreateDirectories = true
            panel.title = "Export File from Volume"
            panel.message = "Choose a destination to export the selected item."

            guard panel.runModal() == .OK, let destination = panel.url else { return }
            if isMounted {
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try Self.copyItem(from: selectedEntry.url, to: destination)
                    }.value
                    statusMessage = "Exported \(selectedEntry.name)"
                } catch {
                    self.errorMessage = DiskImageError.exportFailed(selectedEntry.url, error).localizedDescription
                }
                return
            }

            // hfsutils backend
            guard usingHFSUtils else {
                self.errorMessage = "Export not supported for this backend"
                return
            }
            do {
                try await exportHFSEntry(selectedEntry, to: destination)
                statusMessage = "Exported \(selectedEntry.name)"
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Copies an hfsutils-backed entry out to a real file at `destination`, using its actual
    /// HFS name/extension. Shared by the Export button and drag-out-to-Finder.
    private func exportHFSEntry(_ entry: FileEntry, to destination: URL) async throws {
        guard let hcopy = hcopyPath, let hmount = hmountPath, let image = imageURL else {
            throw NSError(domain: "hfsutils", code: 0, userInfo: [NSLocalizedDescriptionKey: "hfsutils backend unavailable"])
        }
        let hfsPath = pathForEntry(entry)
        let humount = humountPath ?? hmount
        let usePath = imagePathToUse(original: image.path)
        // hmount, hcopy, and humount run as separate calls so humount always runs even if
        // hcopy fails — otherwise a failed export would leave the volume locked from
        // hfsutils's point of view.
        let (mountOut, mountErr, mountCode) = await runCommand([hmount, usePath])
        guard mountCode == 0 else {
            throw NSError(domain: "hfsutils", code: Int(mountCode), userInfo: [NSLocalizedDescriptionKey: "hmount failed: \(mountErr.isEmpty ? mountOut : mountErr)"])
        }
        let (out, err, code) = await runCommand([hcopy, hfsPath, destination.path])
        _ = await runCommand([humount])
        guard code == 0, fileManager.fileExists(atPath: destination.path) else {
            throw NSError(domain: "hfsutils", code: Int(code), userInfo: [NSLocalizedDescriptionKey: "hcopy failed: \(err.isEmpty ? out : err)"])
        }
    }

    /// Returns a URL to a real file on disk suitable for dragging out (e.g. to Finder or
    /// another app). Mounted volumes already expose real files at `entry.url`. The hfsutils
    /// backend's entries are synthetic hfs://localhost/<image-path>?path=<hfs-path> pseudo-URLs
    /// with no bytes on the host filesystem, so the file has to be copied out to a temporary
    /// location first, named after its real HFS name (including extension) rather than the
    /// pseudo-URL (which would otherwise show up in Finder as an unnamed "localhost" item).
    ///
    /// This stays synchronous: SwiftUI's `.onDrag` closure must return an `NSItemProvider`
    /// immediately and can't `await`. By the time a drag can happen the volume has already
    /// been prepared once during the initial directory listing (see `hfsUtilsPrepared`), so
    /// this is just one fast hmount+hcopy+humount round trip rather than a full lock check.
    func materializedURLForDrag(_ entry: FileEntry) -> URL? {
        if isMounted {
            return entry.url
        }
        guard usingHFSUtils, !entry.isDirectory, let image = imageURL, let hcopy = hcopyPath, let hmount = hmountPath,
              let destination = makeTempExtractionDestination(for: entry, prefix: "hfsapp-drag") else { return nil }

        let hfsPath = pathForEntry(entry)
        let humount = humountPath ?? hmount
        let usePath = imagePathToUse(original: image.path)
        // Separate calls (not `a && b && c`) so humount always runs even if hcopy fails.
        let (_, _, mountCode) = Self.runCommandSync([hmount, usePath])
        guard mountCode == 0 else { return nil }
        let (_, _, code) = Self.runCommandSync([hcopy, hfsPath, destination.path])
        _ = Self.runCommandSync([humount])
        guard code == 0, fileManager.fileExists(atPath: destination.path) else { return nil }
        return destination
    }

    private func makeTempExtractionDestination(for entry: FileEntry, prefix: String) -> URL? {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        guard (try? fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)) != nil else { return nil }
        return tempDir.appendingPathComponent(entry.name)
    }

    /// Materializes a file for previewing or opening in its default application (double-click /
    /// "Open" / Quick Look), unlike `materializedURLForDrag` this can genuinely `await`, since
    /// it isn't constrained by a synchronous SwiftUI callback — so it reuses `exportHFSEntry`
    /// (which always runs humount even on failure) instead of duplicating that logic
    /// synchronously. Shared by `openEntry` and `QuickLookController`.
    func materializeForPreview(_ entry: FileEntry) async -> URL? {
        if isMounted {
            return entry.url
        }
        guard usingHFSUtils, !entry.isDirectory,
              let destination = makeTempExtractionDestination(for: entry, prefix: "hfsapp-preview") else { return nil }
        do {
            try await exportHFSEntry(entry, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    /// Double-click / "Open" on a row: descends into folders as before, and for files, opens
    /// them in their default application the way Finder would. hfsutils-backed files aren't
    /// real files on disk, so they're first materialized to a temp location — as with drag and
    /// Quick Look, edits made in the external app won't propagate back into the disk image;
    /// use Export for that.
    func openEntry(_ entry: FileEntry) async {
        if entry.isDirectory {
            await navigate(into: entry)
            return
        }
        await withBusy {
            guard let url = await materializeForPreview(entry) else {
                self.errorMessage = "Could not open \(entry.name)."
                return
            }
            if !NSWorkspace.shared.open(url) {
                self.errorMessage = "No application could open \(entry.name)."
            }
        }
    }

    func importFiles(urls: [URL], destination: URL) async {
        guard !isReadOnly else {
            self.errorMessage = "This image is read-only, so files can't be added to it."
            return
        }
        await withBusy {
            if isMounted {
                for source in urls {
                    let targetURL = destination.appendingPathComponent(source.lastPathComponent)
                    do {
                        try await Task.detached(priority: .userInitiated) {
                            try Self.copyItem(from: source, to: targetURL)
                        }.value
                    } catch {
                        self.errorMessage = DiskImageError.importFailed(source, error).localizedDescription
                        return
                    }
                }
                statusMessage = urls.count == 1 ? "Added \(urls[0].lastPathComponent)" : "Added \(urls.count) items"
                await refresh()
                return
            }

            // hfsutils backend: copy each file into image at currentHFSPath
            guard usingHFSUtils, let image = imageURL, let hcopy = hcopyPath, let hmount = hmountPath else {
                self.errorMessage = "Import not supported for this backend"
                return
            }

            // Detach any hdiutil attachments to the image so hfsutils can lock it
            do { try await prepareForHFSUtils(imagePath: image.path) } catch {
                print("prepareForHFSUtils failed before import: \(error)")
            }

            let destPath = currentHFSPath ?? ":"
            for source in urls {
                let hfsDest = destPath.hasSuffix(":" ) ? "\(destPath)\(source.lastPathComponent)" : "\(destPath):\(source.lastPathComponent)"
                let humount = humountPath ?? hmount
                let usePath = imagePathToUse(original: image.path)
                // Separate calls (not `a && b && c`) so humount always runs even if hcopy fails.
                let (mountOut, mountErr, mountCode) = await runCommand([hmount, usePath])
                guard mountCode == 0 else {
                    self.errorMessage = DiskImageError.importFailed(source, NSError(domain: "hfsutils", code: Int(mountCode), userInfo: [NSLocalizedDescriptionKey: mountErr.isEmpty ? mountOut : mountErr])).localizedDescription
                    return
                }
                let (out, err, code) = await runCommand([hcopy, source.path, hfsDest])
                _ = await runCommand([humount])
                if code != 0 {
                    self.errorMessage = DiskImageError.importFailed(source, NSError(domain: "hfsutils", code: Int(code), userInfo: [NSLocalizedDescriptionKey: err.isEmpty ? out : err])).localizedDescription
                    return
                }
            }
            statusMessage = urls.count == 1 ? "Added \(urls[0].lastPathComponent)" : "Added \(urls.count) items"
            await refresh()
        }
    }

    private nonisolated static func copyItem(from source: URL, to destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError, userInfo: [NSLocalizedDescriptionKey: "Destination already exists."])
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    // MARK: - hfsutils integration helpers

    private func hfsList(path: String, imagePath: String) async throws -> [FileEntry] {
        guard let hmount = hmountPath, let hls = hlsPath else { return [] }
        // Ensure exclusive access: detach any hdiutil-attached devices for this image to avoid lock errors
        do { try await prepareForHFSUtils(imagePath: imagePath) } catch {
            // Log but continue; hfsutils may still work
            print("prepareForHFSUtils failed: \(error)")
        }
        // Normalize path for hls: ':' denotes root; other paths should be prefixed appropriately
        var query = path
        if query == ":" { query = ":" }
        let humount = humountPath ?? hmount
        let usePath = imagePathToUse(original: imagePath)

        // Run hmount, hls, and humount as separate processes (rather than one shell one-liner)
        // so we only capture hls's own stdout. hmount persists the current volume across
        // process invocations via ~/.hcwd, and hmount's own banner text ("Volume name is...")
        // would otherwise get parsed as bogus file entries if captured together with hls's output.
        let (mountOut, mountErr, mountCode) = await runCommand([hmount, usePath])
        guard mountCode == 0 else {
            throw NSError(domain: "hfsutils", code: Int(mountCode), userInfo: [NSLocalizedDescriptionKey: "hmount failed: \(mountErr.isEmpty ? mountOut : mountErr)"])
        }
        let (out, err, code) = await runCommand([hls, query])
        guard code == 0 else {
            _ = await runCommand([humount])
            throw NSError(domain: "hfsutils", code: Int(code), userInfo: [NSLocalizedDescriptionKey: "hls failed: \(err.isEmpty ? out : err)"])
        }
        var results: [FileEntry] = []
        // Plain `hls` prints exactly one full entry name per line (spaces and all) with no
        // other decoration and no directory marker at all — unlike some ls-alikes, it does
        // NOT append a trailing ':' or '/' for folders. Taking the last whitespace-separated
        // "token" here (as this used to) silently truncates every multi-word name (e.g.
        // "Lorem Ipsum.doc" -> "Ipsum.doc"), which is why exports of such files failed with
        // "no such file or directory": hcopy was asked for a name that doesn't actually exist.
        let lines = out.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map { String($0) }
        for line in lines {
            let name = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { continue }

            let hfsFullPath: String
            if query == ":" {
                hfsFullPath = ":\(name)"
            } else if query.hasSuffix(":" ) {
                hfsFullPath = "\(query)\(name)"
            } else {
                hfsFullPath = "\(query):\(name)"
            }

            // Plain `hls` gives us no way to tell files from folders, so ask about this
            // specific entry individually (`-d` lists the entry itself instead of descending
            // into it, `-l` adds the leading 'd'/'f' type marker) while the volume is still
            // mounted. Passed as separate process arguments (no shell), so spaces/quotes in
            // the name can't cause any escaping issues here.
            let (dlOut, _, dlCode) = await runCommand([hls, "-dl", hfsFullPath])
            let isDir = dlCode == 0 && dlOut.hasPrefix("d")

            let pseudo = URL(string: "hfs://localhost\(imagePath)?path=\(hfsFullPath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? hfsFullPath)")!
            let entry = FileEntry(url: pseudo, isDirectory: isDir, size: nil, hfsPath: hfsFullPath)
            results.append(entry)
        }
        _ = await runCommand([humount])

        // Sort directories first
        results.sort { a, b in
            if a.isDirectory == b.isDirectory { return a.name.lowercased() < b.name.lowercased() }
            return a.isDirectory && !b.isDirectory
        }
        return results
    }

    private func pathForEntry(_ entry: FileEntry) -> String {
        // hfsutils-backed entries already carry their exact colon-separated HFS path.
        if let hfsPath = entry.hfsPath {
            return hfsPath
        }
        // If it's a real file URL inside a mountpoint, return path relative to volume root
        if let mount = mountPoint {
            let rel = entry.url.path.replacingOccurrences(of: mount.path, with: "")
            return rel.isEmpty ? ":" : ":\(rel)"
        }
        return entry.url.path
    }

    /// Synchronous variant of `runCommand`, used only by `materializedURLForDrag` since SwiftUI's
    /// `.onDrag` closure must return synchronously and can't `await`.
    private nonisolated static func runCommandSync(_ cmd: [String]) -> (String, String, Int32) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: cmd[0])
        if cmd.count > 1 { proc.arguments = Array(cmd.dropFirst()) }
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do {
            try proc.run()
            proc.waitUntilExit()
            let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return (out, err, proc.terminationStatus)
        } catch {
            return ("", "\(error)", -1)
        }
    }

    func handleDroppedFiles(providers: [NSItemProvider]) -> Bool {
        guard currentDirectory != nil || mountPoint != nil || usingHFSUtils else { return false }
        let collector = URLCollector()
        let group = DispatchGroup()

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    // Extract the URL (a Sendable value) here, outside the Task, since `item`
                    // itself (`Any?`) isn't Sendable and can't be captured into one directly.
                    var droppedURL: URL?
                    if let url = item as? URL {
                        droppedURL = url
                    } else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                        droppedURL = url
                    }
                    // `group.leave()` must happen *after* the append actually completes, not
                    // right after merely starting it — otherwise `group.notify` below can (and
                    // reliably does under real drag timing) fire before any URL has actually
                    // landed in the collector, silently running the import with an empty list.
                    Task {
                        if let droppedURL {
                            await collector.append(droppedURL)
                        }
                        group.leave()
                    }
                }
            } else {
                group.leave()
            }
        }

        group.notify(queue: .main) {
            Task {
                let urls = await collector.allURLs()
                if !urls.isEmpty {
                    if self.isMounted {
                        let dest = self.currentDirectory ?? self.mountPoint!
                        await self.importFiles(urls: urls, destination: dest)
                    } else if self.usingHFSUtils {
                        await self.importFiles(urls: urls, destination: URL(fileURLWithPath: "/"))
                    }
                }
            }
        }

        return true
    }

    /// Opens the first dropped file as a disk image — used by the placeholder view so a
    /// `.dsk`/`.img` file can be dragged straight onto the (empty) window to open it, the same
    /// way `openImage()`'s panel would.
    func handleDroppedImageToOpen(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            var droppedURL: URL?
            if let url = item as? URL {
                droppedURL = url
            } else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                droppedURL = url
            }
            guard let droppedURL else { return }
            Task { @MainActor in
                await self.attachImage(imageURL: droppedURL)
            }
        }
        return true
    }
}
