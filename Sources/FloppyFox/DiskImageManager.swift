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

    // For hfsutils-based backend when the image cannot be mounted
    @Published var currentHFSPath: String? = ":" // ':' denotes root for hfsutils

    private let fileManager = FileManager.default
    private var internalClipboardURL: URL?
    private var internalClipboardOperation: ClipboardOperation = .copy

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

    func openImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "dsk"), UTType(filenameExtension: "img")].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Open HFS Disk Image"
        panel.message = "Choose a .dsk or .img file formatted with the Apple HFS filesystem."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        attachImage(imageURL: url)
    }

    func attachImage(imageURL: URL) {
        detachImageIfMounted()
        do {
            let result = try attachImageUsingHdiutil(imageURL)
            guard let mountPoint = result.mountPoint else {
                throw DiskImageError.missingMountPoint
            }
            self.imageURL = imageURL
            self.mountPoint = mountPoint
            self.mountedDevice = result.device
            self.currentDirectory = mountPoint
            self.statusMessage = "Mounted at \(mountPoint.path)"
            self.errorMessage = nil
            try loadDirectory(at: mountPoint)
        } catch {
            // macOS's Disk Arbitration/hdiutil stack cannot mount classic HFS Standard
            // volumes at all (common for real floppy images, which also usually lack a
            // partition table). Fall back to the userspace hfsutils backend, which reads
            // the raw image bytes directly and doesn't depend on kernel filesystem support.
            attachImageUsingHFSUtilsFallback(imageURL, hdiutilError: error)
        }
    }

    private func attachImageUsingHFSUtilsFallback(_ imageURL: URL, hdiutilError: Error) {
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
            try loadDirectory(at: URL(fileURLWithPath: "/"))
            self.statusMessage = "Opened via hfsutils (macOS could not mount this volume directly)"
            self.errorMessage = nil
        } catch {
            self.imageURL = nil
            self.currentHFSPath = ":"
            self.errorMessage = error.localizedDescription
            self.statusMessage = "Failed to mount image"
        }
    }

    private func attachImageUsingHdiutil(_ imageURL: URL) throws -> (mountPoint: URL?, device: String?) {
        // First try the normal attach that auto-detects filesystem and mounts.
        let options = ["attach", "-readwrite", "-noverify", "-nobrowse", "-noautoopen", "-plist", imageURL.path]
        do {
            let res = try runHdiutil(arguments: options)
            if res.mountPoint != nil { return res }
            // If no mount point but a device was returned, continue to try mounting partitions below.
            if let device = res.device {
                if let mp = try tryMountPartitions(of: device) {
                    return (mp, device)
                }
            }
        } catch {
            // fallthrough to try raw image class below
        }

        // Some raw disk images need the raw disk image class; try attaching that way.
        let rawOptions = ["attach", "-readwrite", "-noverify", "-nobrowse", "-noautoopen", "-imagekey", "diskimage-class=CRawDiskImage", "-plist", imageURL.path]
        do {
            let res = try runHdiutil(arguments: rawOptions)
            if res.mountPoint != nil { return res }
            if let device = res.device {
                if let mp = try tryMountPartitions(of: device) {
                    return (mp, device)
                }
            }
        } catch {
            // final fallback: try attach nomount then mount partitions explicitly
        }

        // Try attach nomount + mount HFS partitions explicitly as a final fallback.
        let nomountOptions = ["attach", "-nomount", "-readwrite", "-noverify", "-nobrowse", "-noautoopen", "-imagekey", "diskimage-class=CRawDiskImage", "-plist", imageURL.path]
        let nomountRes = try runHdiutil(arguments: nomountOptions)
        if let device = nomountRes.device {
            if let mp = try tryMountPartitions(of: device) {
                return (mp, device)
            }
            // If we couldn't mount partitions, detach the raw device and fail.
            try? runHdiutil(arguments: ["detach", device])
        }

        throw DiskImageError.attachmentFailed("hdiutil could not find a mountable HFS partition in the image.")
    }

    /// Try to find HFS partitions on the attached device using `diskutil` and mount the first mountable HFS partition.
    private func tryMountPartitions(of device: String) throws -> URL? {
        // Normalize device to device identifier (e.g., /dev/disk2 -> disk2)
        let deviceIdentifier = URL(fileURLWithPath: device).lastPathComponent

        // Run `diskutil list -plist` and parse partitions
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        proc.arguments = ["list", "-plist", deviceIdentifier]
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        try proc.run()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else {
            // If diskutil fails, give up on this method.
            return nil
        }

        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }

        // The structure has 'AllDisksAndPartitions' with entries that include 'DeviceIdentifier' and 'Partitions'
        guard let all = plist["AllDisksAndPartitions"] as? [[String: Any]] else { return nil }
        var targetEntry: [String: Any]? = nil
        for entry in all {
            if let id = entry["DeviceIdentifier"] as? String, id == deviceIdentifier {
                targetEntry = entry
                break
            }
        }
        guard let target = targetEntry else { return nil }

        // Search partitions for Apple_HFS content
        if let partitions = target["Partitions"] as? [[String: Any]] {
            for part in partitions {
                if let content = part["Content"] as? String, content.contains("Apple_HFS") || content.contains("Apple_HFSX") {
                    if let pdid = part["DeviceIdentifier"] as? String {
                        let partDevice = "/dev/\(pdid)"
                        // Try to mount this partition
                        let mountRes = try mountPartition(partDevice)
                        if mountRes != nil { return mountRes }
                    }
                }
            }
        }

        return nil
    }

    private func mountPartition(_ devicePath: String) throws -> URL? {
        // Attempt to mount the partition using diskutil mount
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        proc.arguments = ["mount", devicePath]
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        try proc.run()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else {
            return nil
        }

        // After mounting, query diskutil info -plist to get MountPoint
        let infoProc = Process()
        infoProc.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        infoProc.arguments = ["info", "-plist", devicePath]
        let infoOut = Pipe()
        infoProc.standardOutput = infoOut
        try infoProc.run()
        infoProc.waitUntilExit()

        guard infoProc.terminationStatus == 0 else { return nil }
        let infoData = infoOut.fileHandleForReading.readDataToEndOfFile()
        if let infoPlist = try PropertyListSerialization.propertyList(from: infoData, options: [], format: nil) as? [String: Any], let mp = infoPlist["MountPoint"] as? String {
            return URL(fileURLWithPath: mp)
        }

        return nil
    }

    private func runHdiutil(arguments: [String]) throws -> (mountPoint: URL?, device: String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

        guard process.terminationStatus == 0 else {
            let errorString = String(data: errorData, encoding: .utf8) ?? "Unknown hdiutil error"
            throw DiskImageError.attachmentFailed(errorString.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // Try parse plist output safely - sometimes hdiutil returns non-plist or empty output
        var plistAny: Any?
        if !outputData.isEmpty {
            plistAny = try? PropertyListSerialization.propertyList(from: outputData, options: [], format: nil)
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
            if let text = String(data: outputData, encoding: .utf8) {
                let regex = try? NSRegularExpression(pattern: "/dev/disk\\\\d+", options: [])
                if let matches = regex?.matches(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count)), let m = matches.first, let range = Range(m.range, in: text) {
                    device = String(text[range])
                }
            }
        }

        return (mountPointURL, device)
    }

    // Find attachments for an image path by querying hdiutil info -plist and parsing for devices referencing the image
    private func findAttachedDevices(for imagePath: String) -> [String] {
        var devices: [String] = []
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        proc.arguments = ["info", "-plist"]
        let out = Pipe()
        proc.standardOutput = out
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
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
            } else if let text = String(data: data, encoding: .utf8) {
                // fallback: find lines where image path appears and search nearby for /dev/diskN
                let lines = text.split(separator: "\n").map { String($0) }
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
        } catch {
            return []
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

    private func prepareForHFSUtils(imagePath: String) throws {
        let attached = findAttachedDevices(for: imagePath)
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
                            try runHdiutilDetach(device: dev)
                            print("Detached \(dev) for image \(imagePath)")
                        } catch {
                            print("Failed to detach \(dev): \(error)")
                            // continue trying others
                        }
                    }
                } else if resp == .alertSecondButtonReturn {
                    // Use temporary copy instead of detaching
                    try createTempCopyAndUse(imagePath: imagePath)
                    return
                } else {
                    // Cancel: throw to abort the hfsutils operation
                    throw NSError(domain: "HFSApp", code: 1, userInfo: [NSLocalizedDescriptionKey: "User cancelled detaching devices"]) as Error
                }
            } else {
                // Auto-detach behavior (existing behavior)
                for dev in attached {
                    do {
                        try runHdiutilDetach(device: dev)
                        print("Detached \(dev) for image \(imagePath)")
                    } catch {
                        print("Failed to detach \(dev): \(error)")
                        // continue trying others
                    }
                }
            }
        }

        // Wait until the file is no longer held open by any process. If it remains locked, fall back to operating on a temporary copy.
        if try !isFileUnlocked(path: imagePath, timeout: 5.0) {
            // Create a temporary copy and operate on it to avoid locks
            try createTempCopyAndUse(imagePath: imagePath)
        }
    }

    private func createTempCopyAndUse(imagePath: String) throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hfsapp-temp-\(UUID().uuidString).img")
        do {
            try fileManager.copyItem(atPath: imagePath, toPath: tmp.path)
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

    private func isFileUnlocked(path: String, timeout: TimeInterval) throws -> Bool {
        // Poll lsof to check whether any process holds the file open
        let interval: TimeInterval = 0.2
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let (out, err, code) = runCommand(["/usr/sbin/lsof", path])
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
            Thread.sleep(forTimeInterval: interval)
        }
        return false
    }

    func detachImageIfMounted() {
        guard let device = mountedDevice else { return }
        do {
            try runHdiutilDetach(device: device)
        } catch {
            // If detach fails, ignore here because a new mount may still work.
        }
        mountedDevice = nil
        mountPoint = nil
        currentDirectory = nil
        entries = []
        selectedEntry = nil
        statusMessage = "Image detached"
    }

    func ejectImage() {
        if let device = mountedDevice {
            do {
                try runHdiutilDetach(device: device)
                mountPoint = nil
                mountedDevice = nil
                currentDirectory = nil
                entries = []
                selectedEntry = nil
                statusMessage = "Image ejected"
                errorMessage = nil
            } catch {
                self.errorMessage = error.localizedDescription
                statusMessage = "Failed to eject image"
            }
            return
        }

        if usingHFSUtils {
            cleanupTempCopyIfAny()
            imageURL = nil
            entries = []
            selectedEntry = nil
            currentHFSPath = ":"
            statusMessage = "Image closed"
            errorMessage = nil
        }
    }

    private func runHdiutilDetach(device: String) throws {
        // Try a normal detach, then fall back to force detach and diskutil if necessary
        func runDetach(args: [String]) -> (String, Int32) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            p.arguments = args
            let errPipe = Pipe()
            p.standardError = errPipe
            do {
                try p.run()
                p.waitUntilExit()
                let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                return (err, p.terminationStatus)
            } catch {
                return ("\(error)", -1)
            }
        }

        // 1) normal detach
        let (normalErr, normalCode) = runDetach(args: ["detach", device])
        if normalCode == 0 { return }

        // 2) try force detach
        let (forceErr, forceCode) = runDetach(args: ["detach", "-force", device])
        if forceCode == 0 { return }

        // 3) try diskutil unmountDisk force <device>
        let diskutil = Process()
        diskutil.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        diskutil.arguments = ["unmountDisk", "force", device]
        let diskErrPipe = Pipe()
        diskutil.standardError = diskErrPipe
        do {
            try diskutil.run()
            diskutil.waitUntilExit()
            if diskutil.terminationStatus == 0 { return }
        } catch {
            // continue to throw below
        }

        // If all attempts failed, surface the last error message
        let lastErr = forceErr.isEmpty ? normalErr : forceErr
        throw DiskImageError.detachmentFailed(lastErr.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func loadDirectory(at url: URL) throws {
        // If the image is mounted normally, use FileManager
        if let mount = mountPoint {
            let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
            let directoryContents = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: resourceKeys, options: [.skipsHiddenFiles])

            let entries = try directoryContents.map { url -> FileEntry in
                let resourceValues = try url.resourceValues(forKeys: Set(resourceKeys))
                let isDirectory = resourceValues.isDirectory ?? false
                let fileSize = resourceValues.fileSize
                return FileEntry(url: url, isDirectory: isDirectory, size: fileSize)
            }

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
        let list = try hfsList(path: hfsPath, imagePath: image.path)
        self.entries = list
        self.currentDirectory = nil
        self.errorMessage = nil
    }

    func refresh() {
        if let currentDirectory {
            do {
                try loadDirectory(at: currentDirectory)
            } catch {
                self.errorMessage = DiskImageError.loadDirectoryFailed(currentDirectory, error).localizedDescription
            }
        } else if usingHFSUtils {
            do {
                try loadDirectory(at: URL(fileURLWithPath: "/"))
            } catch {
                self.errorMessage = DiskImageError.loadDirectoryFailed(URL(fileURLWithPath: "/"), error).localizedDescription
            }
        }
    }

    func navigate(into entry: FileEntry) {
        guard entry.isDirectory else { return }
        do {
            if isMounted, let url = entry.url as URL? {
                try loadDirectory(at: url)
            } else if usingHFSUtils, let image = imageURL {
                // update currentHFSPath and load via hfsutils
                if let current = currentHFSPath {
                    // append entry name to path
                    let newPath = current.hasSuffix(":" ) ? "\(current)\(entry.name)" : "\(current):\(entry.name)"
                    currentHFSPath = newPath
                } else {
                    currentHFSPath = ":\(entry.name)"
                }
                try loadDirectory(at: URL(fileURLWithPath: "/"))
            }
            selectedEntry = nil
        } catch {
            self.errorMessage = DiskImageError.loadDirectoryFailed(entry.url, error).localizedDescription
        }
    }

    func goUp() {
        if isMounted {
            guard let currentDirectory, let mountPoint else { return }
            guard currentDirectory.path != mountPoint.path else { return }
            let parent = currentDirectory.deletingLastPathComponent()
            if parent.path.hasPrefix(mountPoint.path) {
                do {
                    try loadDirectory(at: parent)
                    selectedEntry = nil
                } catch {
                    self.errorMessage = DiskImageError.loadDirectoryFailed(parent, error).localizedDescription
                }
            }
        } else if usingHFSUtils {
            // go up in HFS path
            if var path = currentHFSPath {
                if path == ":" { return }
                // remove last segment
                if let idx = path.range(of: ":", options: .backwards)?.lowerBound {
                    let trimmed = String(path[..<idx])
                    currentHFSPath = trimmed.isEmpty ? ":" : trimmed
                } else if let slashIdx = path.range(of: "/", options: .backwards)?.lowerBound {
                    currentHFSPath = String(path[..<slashIdx])
                } else {
                    currentHFSPath = ":"
                }
                do {
                    try loadDirectory(at: URL(fileURLWithPath: "/"))
                    selectedEntry = nil
                } catch {
                    self.errorMessage = DiskImageError.loadDirectoryFailed(URL(fileURLWithPath: "/"), error).localizedDescription
                }
            }
        }
    }

    func deleteSelected() {
        guard let selectedEntry else { return }
        deleteEntry(selectedEntry)
    }

    func deleteEntry(_ entry: FileEntry) {
        if isMounted {
            do {
                try fileManager.removeItem(at: entry.url)
                if selectedEntry?.url == entry.url {
                    selectedEntry = nil
                }
                refresh()
                statusMessage = "Deleted \(entry.name)"
            } catch {
                self.errorMessage = DiskImageError.deleteFailed(entry.url, error).localizedDescription
            }
            return
        }

        // hfsutils backend
        guard usingHFSUtils, let image = imageURL, let hdel = hdelPath else {
            self.errorMessage = "Delete not supported for this backend"
            return
        }

        // Build HFS path
        let hfsPath = pathForEntry(entry)
        let humount = humountPath ?? hmountPath!
        let cmd = "\(hmountPath!) \"\(image.path)\" && \(hdel) \"\(hfsPath)\" && \(humount)"
        let (out, err, code) = runCommand(["/bin/sh", "-c", cmd])
        if code == 0 {
            statusMessage = "Deleted \(entry.name)"
            refresh()
        } else {
            errorMessage = "hdel failed: \(err.isEmpty ? out : err)"
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
            importFiles(urls: urls, destination: target)
            return
        }
        if let source = internalClipboardURL {
            importFiles(urls: [source], destination: target)
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
        importFiles(urls: panel.urls, destination: target)
    }

    /// Run diagnostic commands against the provided disk image and write the combined output to a temp file. The file path is returned.
    func runDiagnostics(on imageURL: URL) -> URL? {
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
            let (out, err, code) = runCommand(cmd)
            combined += "Exit: \(code)\n"
            if !out.isEmpty { combined += "STDOUT:\n\(out)\n" }
            if !err.isEmpty { combined += "STDERR:\n\(err)\n" }
            combined += "---\n\n"

            // `attach` (including -nomount) leaves the device attached even when no
            // filesystem is mountable. Detach it again immediately so diagnostics doesn't
            // leak raw devices, and so the hfsutils probe below isn't blocked by the lock.
            if code == 0, cmd.contains("attach"), let device = extractDeviceEntry(from: out) {
                _ = runCommand(["/usr/bin/hdiutil", "detach", device])
            }
        }

        // Also clean up any devices left attached by earlier (e.g. pre-fix) diagnostics
        // runs or failed attach attempts, so the hfsutils probe below has exclusive access.
        for device in findAttachedDevices(for: imageURL.path) {
            _ = runCommand(["/usr/bin/hdiutil", "detach", device])
        }

        // If hfsutils installed, try a quick hfsutils probe (hmount+hls)
        if FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/hmount") || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/hmount") {
            let hmountPath = FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/hmount") ? "/opt/homebrew/bin/hmount" : "/usr/local/bin/hmount"
            combined += "$ \(hmountPath) 'image' && hls ':' && humount\n"
            let hlsPath = FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/hls") ? "/opt/homebrew/bin/hls" : "/usr/local/bin/hls"
            let humountPath = FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/humount") ? "/opt/homebrew/bin/humount" : "/usr/local/bin/humount"
            let (out, err, code) = runCommand(["/bin/sh", "-c", "\(hmountPath) \"\(imageURL.path)\" && \(hlsPath) ':' && \(humountPath)"])
            combined += "Exit: \(code)\n"
            if !out.isEmpty { combined += "STDOUT:\n\(out)\n" }
            if !err.isEmpty { combined += "STDERR:\n\(err)\n" }
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

    private func extractDeviceEntry(from plistOutput: String) -> String? {
        guard let data = plistOutput.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else { return nil }
        for entity in entities {
            if let dev = entity["dev-entry"] as? String { return dev }
        }
        return nil
    }

    private func runCommand(_ cmd: [String]) -> (String, String, Int32) {
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

    func exportSelected() {
        // if using hfsutils, ensure no hdiutil attached device blocks the file
        if usingHFSUtils, let image = imageURL {
            try? prepareForHFSUtils(imagePath: image.path)
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
                try copyItem(from: selectedEntry.url, to: destination)
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
            try exportHFSEntry(selectedEntry, to: destination)
            statusMessage = "Exported \(selectedEntry.name)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Copies an hfsutils-backed entry out to a real file at `destination`, using its actual
    /// HFS name/extension. Shared by the Export button and drag-out-to-Finder.
    private func exportHFSEntry(_ entry: FileEntry, to destination: URL) throws {
        guard let hcopy = hcopyPath, let hmount = hmountPath, let image = imageURL else {
            throw NSError(domain: "hfsutils", code: 0, userInfo: [NSLocalizedDescriptionKey: "hfsutils backend unavailable"])
        }
        let hfsPath = pathForEntry(entry)
        // Build command: hmount image && hcopy ":<hfsPath>" "<destination>" && humount
        let humount = humountPath ?? hmount
        let usePath = imagePathToUse(original: image.path)
        let cmd = "\(hmount) \"\(usePath)\" && \(hcopy) \"\(hfsPath)\" \"\(destination.path)\" && \(humount)"
        let (out, err, code) = runCommand(["/bin/sh", "-c", cmd])
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
    func materializedURLForDrag(_ entry: FileEntry) -> URL? {
        if isMounted {
            return entry.url
        }
        guard usingHFSUtils, !entry.isDirectory, let image = imageURL else { return nil }
        try? prepareForHFSUtils(imagePath: image.path)

        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hfsapp-drag-\(UUID().uuidString)", isDirectory: true)
        guard (try? fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)) != nil else { return nil }
        let destination = tempDir.appendingPathComponent(entry.name)

        do {
            try exportHFSEntry(entry, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    func importFiles(urls: [URL], destination: URL) {
        if isMounted {
            for source in urls {
                let targetURL = destination.appendingPathComponent(source.lastPathComponent)
                do {
                    try copyItem(from: source, to: targetURL)
                } catch {
                    self.errorMessage = DiskImageError.importFailed(source, error).localizedDescription
                    return
                }
            }
            refresh()
            return
        }

        // hfsutils backend: copy each file into image at currentHFSPath
        guard usingHFSUtils, let image = imageURL, let hcopy = hcopyPath, let hmount = hmountPath else {
            self.errorMessage = "Import not supported for this backend"
            return
        }

        // Detach any hdiutil attachments to the image so hfsutils can lock it
        do { try prepareForHFSUtils(imagePath: image.path) } catch {
            print("prepareForHFSUtils failed before import: \(error)")
        }

        let destPath = currentHFSPath ?? ":"
        for source in urls {
            // Build command: hmount image && hcopy "hostfile" ":<dest>" && humount
            let hfsDest = destPath.hasSuffix(":" ) ? "\(destPath)\(source.lastPathComponent)" : "\(destPath)/\(source.lastPathComponent)"
            let humount = humountPath ?? hmount
            let usePath = imagePathToUse(original: image.path)
            let cmd = "\(hmount) \"\(usePath)\" && \(hcopy) \"\(source.path)\" \"\(hfsDest)\" && \(humount)"
            let (out, err, code) = runCommand(["/bin/sh", "-c", cmd])
            if code != 0 {
                self.errorMessage = DiskImageError.importFailed(source, NSError(domain: "hfsutils", code: Int(code), userInfo: [NSLocalizedDescriptionKey: err.isEmpty ? out : err])).localizedDescription
                return
            }
        }
        refresh()
    }

    private func copyItem(from source: URL, to destination: URL) throws {
        if fileManager.fileExists(atPath: destination.path) {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError, userInfo: [NSLocalizedDescriptionKey: "Destination already exists."])
        }
        try fileManager.copyItem(at: source, to: destination)
    }

    // MARK: - hfsutils integration helpers

    private func hfsList(path: String, imagePath: String) throws -> [FileEntry] {
        guard let hmount = hmountPath, let hls = hlsPath else { return [] }
        // Ensure exclusive access: detach any hdiutil-attached devices for this image to avoid lock errors
        do { try prepareForHFSUtils(imagePath: imagePath) } catch {
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
        let (mountOut, mountErr, mountCode) = runCommand([hmount, usePath])
        guard mountCode == 0 else {
            throw NSError(domain: "hfsutils", code: Int(mountCode), userInfo: [NSLocalizedDescriptionKey: "hmount failed: \(mountErr.isEmpty ? mountOut : mountErr)"])
        }
        let (out, err, code) = runCommand([hls, query])
        guard code == 0 else {
            _ = runCommand([humount])
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
            let (dlOut, _, dlCode) = runCommand([hls, "-dl", hfsFullPath])
            let isDir = dlCode == 0 && dlOut.hasPrefix("d")

            let pseudo = URL(string: "hfs://localhost\(imagePath)?path=\(hfsFullPath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? hfsFullPath)")!
            let entry = FileEntry(url: pseudo, isDirectory: isDir, size: nil, hfsPath: hfsFullPath)
            results.append(entry)
        }
        _ = runCommand([humount])

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

    func handleDroppedFiles(providers: [NSItemProvider]) -> Bool {
        guard currentDirectory != nil || mountPoint != nil || usingHFSUtils else { return false }
        let collector = URLCollector()
        let group = DispatchGroup()

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    if let url = item as? URL {
                        Task { await collector.append(url) }
                    } else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                        Task { await collector.append(url) }
                    }
                    group.leave()
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
                        self.importFiles(urls: urls, destination: dest)
                    } else if self.usingHFSUtils {
                        self.importFiles(urls: urls, destination: URL(fileURLWithPath: "/"))
                    }
                }
            }
        }

        return true
    }
}
