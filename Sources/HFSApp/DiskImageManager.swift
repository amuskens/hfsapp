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
    let id = UUID()
    let url: URL
    let isDirectory: Bool
    let size: Int?

    var name: String {
        url.lastPathComponent
    }

    var icon: NSImage? {
        let workspace = NSWorkspace.shared
        return workspace.icon(forFile: url.path)
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

    private let fileManager = FileManager.default
    private var internalClipboardURL: URL?
    private var internalClipboardOperation: ClipboardOperation = .copy

    var isMounted: Bool {
        mountPoint != nil
    }

    var canGoBack: Bool {
        guard let currentDirectory, let mountPoint else { return false }
        return currentDirectory.path != mountPoint.path
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

        guard
            let plist = try PropertyListSerialization.propertyList(from: outputData, options: [], format: nil) as? [String: Any],
            let entities = plist["system-entities"] as? [[String: Any]]
        else {
            throw DiskImageError.attachmentFailed("Unexpected hdiutil plist output.")
        }

        var mountPointURL: URL?
        var device: String?

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

        return (mountPointURL, device)
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
        guard let device = mountedDevice else { return }
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
    }

    private func runHdiutilDetach(device: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["detach", device]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorString = String(data: errorData, encoding: .utf8) ?? "Unknown detach error"
            throw DiskImageError.detachmentFailed(errorString.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    func loadDirectory(at url: URL) throws {
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
        self.errorMessage = nil
    }

    func refresh() {
        guard let currentDirectory else { return }
        do {
            try loadDirectory(at: currentDirectory)
        } catch {
            self.errorMessage = DiskImageError.loadDirectoryFailed(currentDirectory, error).localizedDescription
        }
    }

    func navigate(into entry: FileEntry) {
        guard entry.isDirectory else { return }
        do {
            try loadDirectory(at: entry.url)
            selectedEntry = nil
        } catch {
            self.errorMessage = DiskImageError.loadDirectoryFailed(entry.url, error).localizedDescription
        }
    }

    func goUp() {
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
    }

    func deleteSelected() {
        guard let selectedEntry else { return }
        deleteEntry(selectedEntry)
    }

    func deleteEntry(_ entry: FileEntry) {
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
    }

    func copySelected() {
        guard let selectedEntry else { return }
        copyEntry(selectedEntry)
    }

    func copyEntry(_ entry: FileEntry) {
        internalClipboardURL = entry.url
        internalClipboardOperation = .copy
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([entry.url as NSURL])
        statusMessage = "Copied \(entry.name)"
    }

    func paste() {
        guard let target = currentDirectory ?? mountPoint else { return }
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
        guard let target = currentDirectory ?? mountPoint else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.title = "Add Files to Volume"
        panel.message = "Choose files or folders to copy into the mounted HFS volume."

        guard panel.runModal() == .OK else { return }
        importFiles(urls: panel.urls, destination: target)
    }

    func exportSelected() {
        guard let selectedEntry else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = selectedEntry.name
        panel.canCreateDirectories = true
        panel.title = "Export File from Volume"
        panel.message = "Choose a destination to export the selected item."

        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try copyItem(from: selectedEntry.url, to: destination)
            statusMessage = "Exported \(selectedEntry.name)"
        } catch {
            self.errorMessage = DiskImageError.exportFailed(selectedEntry.url, error).localizedDescription
        }
    }

    func importFiles(urls: [URL], destination: URL) {
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
    }

    private func copyItem(from source: URL, to destination: URL) throws {
        if fileManager.fileExists(atPath: destination.path) {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError, userInfo: [NSLocalizedDescriptionKey: "Destination already exists."])
        }
        try fileManager.copyItem(at: source, to: destination)
    }

    func handleDroppedFiles(providers: [NSItemProvider]) -> Bool {
        guard let target = currentDirectory ?? mountPoint else { return false }
        let targetCopy = target
        let collector = URLCollector()
        let group = DispatchGroup()

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    if let url = item as? URL {
                        Task {
                            await collector.append(url)
                            group.leave()
                        }
                    } else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                        Task {
                            await collector.append(url)
                            group.leave()
                        }
                    } else {
                        group.leave()
                    }
                }
            }
        }

        group.notify(queue: .main) {
            Task {
                let urls = await collector.allURLs()
                if !urls.isEmpty {
                    self.importFiles(urls: urls, destination: targetCopy)
                }
            }
        }

        return true
    }
}
