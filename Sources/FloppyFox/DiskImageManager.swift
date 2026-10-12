import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum ClipboardOperation {
    case copy
    case cut
}

/// One row of the browser: a catalog item plus its decoded classic icon, if it has one.
struct FileEntry: Identifiable, Hashable, Sendable {
    let item: VolumeItem
    /// PNG of the item's own `ICN#` icon (applications only — see `DiskImageManager.reload`).
    let resourceIconPNG: Data?

    init(item: VolumeItem, resourceIconPNG: Data? = nil) {
        self.item = item
        self.resourceIconPNG = resourceIconPNG
    }

    // Identity is the catalog node ID: stable across refreshes and renames, which keeps List
    // selection intact when the listing is rebuilt.
    var id: UInt32 { item.id }
    var name: String { item.name }
    var isDirectory: Bool { item.isFolder }
    var size: Int? { item.isFolder ? nil : Int(item.dataLength) + Int(item.resourceLength) }
    var dataForkSize: Int? { item.isFolder ? nil : Int(item.dataLength) }
    var resourceForkSize: Int? { item.isFolder ? nil : Int(item.resourceLength) }
    var finderType: String? { item.isFolder ? nil : Self.fourCC(item.fileType) }
    var finderCreator: String? { item.isFolder ? nil : Self.fourCC(item.creator) }
    var isInvisible: Bool { item.isInvisible }
    var isLocked: Bool { item.isLocked }

    private static func fourCC(_ bytes: [UInt8]) -> String {
        String(data: Data(bytes), encoding: .macOSRoman) ?? "????"
    }

    var icon: NSImage? {
        if let resourceIconPNG, let image = NSImage(data: resourceIconPNG) {
            return image
        }
        if finderType == "APPL", let image = Bundle.floppyFoxResources.image(forResource: "ClassicMac") {
            return image
        }
        if ["dsk", "img", "hda", "vhd"].contains((name as NSString).pathExtension.lowercased()),
           let image = Bundle.floppyFoxResources.image(forResource: "Floppy") {
            return image
        }
        if isDirectory {
            return NSWorkspace.shared.icon(for: .folder)
        }
        if let image = Bundle.floppyFoxResources.image(forResource: "ClassicDocument") {
            image.isTemplate = false
            return image
        }
        return NSWorkspace.shared.icon(for: .data)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(item.id)
    }

    static func == (lhs: FileEntry, rhs: FileEntry) -> Bool {
        lhs.item.id == rhs.item.id
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

/// Owns the open disk image and everything the window shows about it.
///
/// All disk access goes through the in-process engines (`HFSVolume`, `HFSPlusVolume`) — no
/// kernel mounts and no external tools — so the app works inside the App Sandbox. Volumes are
/// actors, which also serializes every operation against the image.
@MainActor
final class DiskImageManager: ObservableObject {
    @Published private(set) var imageURL: URL?
    @Published private(set) var volumeName: String?
    @Published private(set) var currentFolderID: UInt32 = HFSCatalogID.rootFolder
    /// Folders from just below the volume root down to the current folder.
    @Published private(set) var folderPath: [VolumeItem] = []
    @Published var entries: [FileEntry] = []
    @Published var selectedEntries: Set<FileEntry> = []
    @Published var errorMessage: String?
    @Published var statusMessage: String = "No image loaded"
    // True while an operation is in flight, so the UI can show a lightweight progress
    // indicator instead of looking frozen.
    @Published var isBusy: Bool = false
    // Set when the open image can't be written (file permissions, a locked volume, another
    // program using it, or a container format that is read-only). Writes check this.
    @Published private(set) var isReadOnly: Bool = false
    @Published private(set) var readOnlyReason: String?
    /// True when the image opened read-only only because its volume wasn't cleanly ejected
    /// (see `reopenAllowingWrites`).
    @Published private(set) var canOpenForWritingAnyway = false
    @Published private(set) var formatName: String?
    // One-shot informational warning (distinct from `errorMessage`, which represents a failed
    // action) — e.g. why an image was opened read-only.
    @Published var warningMessage: String?
    @Published var transferTitle: String?
    @Published var transferMessage: String?
    @Published private(set) var freeSpaceDescription: String?

    /// The system pasteboard in the app; tests substitute a private one.
    var pasteboard: NSPasteboard = .general
    /// Told each progress message as a transfer moves on to a new item (whether or not the
    /// progress panel is showing yet).
    var transferProgressObserver: ((String) -> Void)?

    private let fileManager = FileManager.default
    private let storage: TemporaryStorage
    private var volume: (any DiskVolume)?
    private var vhdExpandedCopy: URL?

    // Bumped every time an image is opened or closed. Operations capture it before awaiting
    // and discard their results if it changed meanwhile — so a slow listing finishing after
    // Eject can't resurrect the old image's browser, and the internal clipboard can't be
    // resolved against a different image than the one it was filled from.
    private var sessionID = UUID()

    private struct InternalClipboard {
        let session: UUID
        let itemIDs: [UInt32]
        let operation: ClipboardOperation
        let token: String
    }
    private var internalClipboard: InternalClipboard?
    private var clipboardExportTask: Task<Void, Never>?
    private var clipboardExportDirectory: URL?
    private static let internalClipboardType = NSPasteboard.PasteboardType("com.floppyfox.hfs-clipboard")

    private var activeTransfer: (id: UUID, flag: CancellationFlag)?
    private var pendingTransferMessage: String?
    private var transferDelayTask: Task<Void, Never>?
    private var busyDepth = 0

    init(storage: TemporaryStorage = .shared) {
        self.storage = storage
    }

    var isOpen: Bool { volume != nil }

    var canGoBack: Bool { isOpen && currentFolderID != HFSCatalogID.rootFolder }

    /// Convenience for call sites that only care about "exactly one item selected" (Quick
    /// Look, Save As, the inspector). Setting it replaces the whole selection.
    var selectedEntry: FileEntry? {
        get { selectedEntries.count == 1 ? selectedEntries.first : nil }
        set { selectedEntries = newValue.map { [$0] } ?? [] }
    }

    static var supportedImageTypes: [UTType] {
        ["dsk", "img", "hda", "vhd", "image", "dc42"].compactMap { UTType(filenameExtension: $0) }
    }

    // MARK: - Serializing writes

    private var writeQueueTail: Task<Void, Never>?

    /// Runs write operations (import, delete, copy, move, new folder) one after another. A
    /// failed save rolls back every pending change on the volume, so two operations must never
    /// share an uncommitted batch — e.g. an import into a folder whose creation is undone.
    private func serializedWrite(_ body: @escaping @MainActor () async -> Void) async {
        let previous = writeQueueTail
        let task = Task { @MainActor in
            await previous?.value
            await body()
        }
        writeQueueTail = task
        await task.value
    }

    // MARK: - Busy state and transfer progress

    /// Marks `isBusy` for the duration of `work`. Reentrant (depth-counted), so nested calls
    /// don't make the indicator flicker off before the outermost operation finishes.
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

    /// Starts a non-modal progress presentation after a short delay: fast operations finish
    /// before it and never flash UI; long transfers stay visible and cancellable.
    private func beginTransfer(title: String, message: String) -> (id: UUID, flag: CancellationFlag) {
        let transfer = (id: UUID(), flag: CancellationFlag())
        activeTransfer = transfer
        pendingTransferMessage = message
        transferDelayTask?.cancel()
        transferDelayTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, let self, self.activeTransfer?.id == transfer.id else { return }
            self.transferTitle = title
            self.transferMessage = self.pendingTransferMessage
        }
        return transfer
    }

    private func updateTransfer(_ id: UUID, message: String) {
        guard activeTransfer?.id == id, activeTransfer?.flag.isCancelled == false else { return }
        pendingTransferMessage = message
        transferProgressObserver?(message)
        if transferTitle != nil {
            transferMessage = message
        }
    }

    private func endTransfer(_ id: UUID) {
        guard activeTransfer?.id == id else { return }
        transferDelayTask?.cancel()
        transferDelayTask = nil
        activeTransfer = nil
        pendingTransferMessage = nil
        transferTitle = nil
        transferMessage = nil
    }

    func cancelActiveTransfer() {
        guard let transfer = activeTransfer else { return }
        transfer.flag.cancel()
        transferMessage = "Cancelling…"
        clipboardExportTask?.cancel()
    }

    // MARK: - Opening and closing

    func openImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.supportedImageTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Open HFS Disk Image"
        panel.message = "Choose a .dsk, .img, .hda, or .vhd file containing an Apple HFS volume."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await attachImage(imageURL: url) }
    }

    func attachImage(imageURL url: URL) async {
        await attachImage(imageURL: url, allowUncleanVolume: false)
    }

    /// Reopens the current image for writing even though its volume wasn't cleanly ejected —
    /// for an image the user knows nothing else is using (e.g. an emulator crashed).
    func reopenAllowingWrites() async {
        guard let url = imageURL, canOpenForWritingAnyway else { return }
        await attachImage(imageURL: url, allowUncleanVolume: true)
    }

    private func attachImage(imageURL url: URL, allowUncleanVolume: Bool) async {
        await withBusy {
            await closeImage(status: "Image closed")
            let session = sessionID
            do {
                var reasons: [String] = []
                var source = url
                if url.pathExtension.lowercased() == "vhd" {
                    let preparation = try await VHDImage.prepareForReading(url)
                    if preparation.imageURL != url {
                        vhdExpandedCopy = preparation.imageURL
                        source = preparation.imageURL
                        reasons.append("Dynamic VHD images are expanded to a temporary copy and opened read-only. Changes can't be written back to the VHD container.")
                    }
                }
                let locations = try await Task.detached(priority: .userInitiated) { [source] in
                    try DiskImageLayout.volumes(in: source)
                }.value
                guard let location = locations.first else { throw HFSError.notHFS }
                if let reason = location.readOnlyReason { reasons.append(reason) }
                if !fileManager.isWritableFile(atPath: url.path) {
                    reasons.append("This image's file permissions don't allow writing, so it was opened read-only.")
                } else if !(await Self.processesHoldingOpen(url.path)).isEmpty {
                    reasons.append("This image is currently open in another program (e.g. an emulator like Mini vMac), so it was opened read-only to avoid conflicting changes.")
                }
                let readOnly = !reasons.isEmpty
                let volume = try await Task.detached(priority: .userInitiated) { [source] in
                    try DiskImageLayout.openVolume(source, at: location, readOnly: readOnly, allowUncleanVolume: allowUncleanVolume)
                }.value
                if let cause = volume.readOnlyCause, let message = Self.message(for: cause) {
                    reasons.append(message)
                }
                guard session == sessionID else {
                    await volume.close()
                    return
                }

                self.volume = volume
                self.imageURL = url
                self.volumeName = await volume.volumeName
                self.formatName = volume.formatName
                self.isReadOnly = volume.isReadOnly
                self.readOnlyReason = reasons.first
                self.canOpenForWritingAnyway = reasons.count == 1 && volume.readOnlyCause == .notCleanlyUnmounted
                self.currentFolderID = HFSCatalogID.rootFolder
                try await reload()
                var status = isReadOnly ? "Opened \(volumeName ?? url.lastPathComponent) (read-only)" : "Opened \(volumeName ?? url.lastPathComponent)"
                if locations.count > 1 {
                    status += " — the first of \(locations.count) HFS partitions"
                }
                statusMessage = status
                errorMessage = nil
                if let reason = reasons.first {
                    warningMessage = reason
                }
            } catch {
                await closeImage(status: "Failed to open image")
                errorMessage = "Could not open \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    func ejectImage() async {
        guard isOpen else { return }
        await withBusy {
            await closeImage(status: "Image ejected")
        }
    }

    /// Writes out anything pending and returns to the no-image state. Everything that refers to
    /// the old image goes with it: previews, the expanded VHD copy, and the internal clipboard.
    private func closeImage(status: String) async {
        // Stop whatever is in flight first. Bumping the session makes its loops stop at the
        // next step, and closing the volume makes any call it still makes fail — so nothing
        // can write to the image after this returns.
        activeTransfer?.flag.cancel()
        sessionID = UUID()
        if let volume {
            do {
                try await volume.flush()
            } catch {
                errorMessage = "Some changes could not be saved and were discarded: \(error.localizedDescription)"
            }
            await volume.close()
        }
        volume = nil
        imageURL = nil
        volumeName = nil
        currentFolderID = HFSCatalogID.rootFolder
        folderPath = []
        entries = []
        selectedEntries = []
        isReadOnly = false
        readOnlyReason = nil
        canOpenForWritingAnyway = false
        formatName = nil
        freeSpaceDescription = nil
        if let vhdExpandedCopy {
            try? fileManager.removeItem(at: vhdExpandedCopy)
            self.vhdExpandedCopy = nil
        }
        storage.removeAll("preview")
        clipboardExportTask?.cancel()
        clipboardExportTask = nil
        internalClipboard = nil
        statusMessage = status
    }

    // MARK: - Browsing

    /// Re-lists the current folder (and the path above it) from the volume.
    private func reload() async throws {
        guard let volume else { return }
        let session = sessionID
        let folderID = currentFolderID
        let items = try await volume.contents(ofFolder: folderID)
        var rows: [FileEntry] = []
        for item in items {
            rows.append(FileEntry(item: item, resourceIconPNG: await Self.applicationIcon(of: item, on: volume)))
        }
        let path = try await volume.path(of: folderID)
        let free = await volume.freeBytes
        guard session == sessionID, folderID == currentFolderID else { return }
        entries = rows.sorted { first, second in
            if first.isDirectory == second.isDirectory {
                return first.name.lowercased() < second.name.lowercased()
            }
            return first.isDirectory && !second.isDirectory
        }
        folderPath = path
        freeSpaceDescription = ByteCountFormatter.string(fromByteCount: Int64(free), countStyle: .file) + " free"
        // Keep the selection on items that are still here, with their refreshed details.
        let selectedIDs = Set(selectedEntries.map(\.id))
        selectedEntries = Set(rows.filter { selectedIDs.contains($0.id) })
    }

    /// Applications usually carry their own icon in the resource fork; decoding it is cheap
    /// in-process. Very large forks are skipped to keep listings fast.
    private static func applicationIcon(of item: VolumeItem, on volume: any DiskVolume) async -> Data? {
        guard !item.isFolder, item.fileType == Array("APPL".utf8), item.resourceLength > 0, item.resourceLength <= 4 << 20 else { return nil }
        guard let fork = try? await volume.readForkBytes(item.id, fork: .resource) else { return nil }
        return ClassicMacResourceIcon.iconPNG(fromResourceFork: Data(fork))
    }

    func refresh() async {
        guard isOpen else { return }
        await withBusy {
            do {
                try await reload()
                errorMessage = nil
            } catch {
                errorMessage = "Could not read the folder: \(error.localizedDescription)"
            }
        }
    }

    func navigate(into entry: FileEntry) async {
        guard entry.isDirectory else { return }
        await navigate(toFolder: entry.id)
    }

    func goUp() async {
        guard canGoBack, let current = folderPath.last else { return }
        await navigate(toFolder: current.parentID)
    }

    func navigate(toFolder folderID: UInt32) async {
        guard isOpen else { return }
        await withBusy {
            let previous = currentFolderID
            currentFolderID = folderID
            do {
                try await reload()
                selectedEntries = []
            } catch {
                // Don't strand later actions at a folder that never listed.
                if currentFolderID == folderID { currentFolderID = previous }
                errorMessage = "Could not open the folder: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Creating and deleting

    func createFolder(named proposedName: String) async {
        guard let volume else { return }
        guard !isReadOnly else {
            errorMessage = "This image is read-only, so a folder can't be created."
            return
        }
        let trimmed = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let nameString = volume.validName(from: trimmed)
        await serializedWrite { [self] in await withBusy {
            do {
                try await volume.createFolder(named: nameString, in: currentFolderID)
                try await volume.flush()
                try await reload()
                statusMessage = nameString == trimmed ? "Created \(nameString)" : "Created \(nameString) (renamed for classic HFS compatibility)"
            } catch {
                errorMessage = "Could not create \(nameString): \(error.localizedDescription)"
            }
        } }
    }

    func deleteSelected() {
        guard !selectedEntries.isEmpty else { return }
        Task { await deleteEntries(selectedEntries) }
    }

    func deleteEntry(_ entry: FileEntry) async {
        await deleteEntries([entry])
    }

    /// Deletes files and whole folders (their contents first), with one progress display and
    /// one flush for the whole batch.
    func deleteEntries(_ entries: some Collection<FileEntry>) async {
        guard !entries.isEmpty, let volume else { return }
        guard !isReadOnly else {
            errorMessage = entries.count == 1
                ? "This image is read-only, so \(entries.first!.name) can't be deleted."
                : "This image is read-only, so these items can't be deleted."
            return
        }
        await serializedWrite { [self] in await withBusy {
            let transfer = beginTransfer(title: "Deleting Items", message: "Preparing to delete…")
            defer { endTransfer(transfer.id) }
            var deleted = 0
            var failure: String?
            for entry in entries {
                do {
                    try transfer.flag.check()
                    updateTransfer(transfer.id, message: "Deleting \(entry.name)…")
                    try await deleteRecursively(entry.id, on: volume, flag: transfer.flag)
                    deleted += 1
                } catch is CancellationError {
                    statusMessage = "Delete cancelled"
                    break
                } catch {
                    failure = "Could not delete \(entry.name): \(error.localizedDescription)"
                }
            }
            await finishWrite(on: volume)
            if deleted > 0 {
                statusMessage = deleted == 1 ? "Deleted \(entries.first!.name)" : "Deleted \(deleted) items"
            }
            if let failure { errorMessage = failure }
        } }
    }

    private func deleteRecursively(_ id: UInt32, on volume: any DiskVolume, flag: CancellationFlag, depth: Int = 0) async throws {
        try flag.check()
        guard depth < Self.maximumFolderDepth else { throw HFSError.corrupt("folders are nested too deeply") }
        let item = try await volume.item(id)
        if item.isFolder {
            for child in try await volume.contents(ofFolder: id) {
                try await deleteRecursively(child.id, on: volume, flag: flag, depth: depth + 1)
            }
        }
        try await volume.delete(id)
    }

    /// Recursive walks stop here; a damaged catalog can't make them run forever.
    private static let maximumFolderDepth = 512

    /// Flushes pending changes and refreshes the listing. A refresh error is not reported on
    /// top of the operation's own result.
    private func finishWrite(on volume: any DiskVolume) async {
        do {
            try await volume.flush()
        } catch {
            errorMessage = "The changes could not be saved, so they were discarded: \(error.localizedDescription)"
        }
        try? await reload()
    }

    // MARK: - Importing from the Mac

    func addFiles() {
        guard isOpen else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.title = "Add Files to Volume"
        panel.message = "Choose files or folders to copy into the HFS volume."
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await importFiles(urls: urls) }
    }

    /// Copies host files and folders into the current folder, both forks and Finder info
    /// included. `.bin` files that are MacBinary are unpacked. Each top-level item is flushed
    /// to the image as soon as it is complete, so a cancelled import keeps what finished.
    func importFiles(urls: [URL]) async {
        guard let volume else { return }
        guard !isReadOnly else {
            errorMessage = "This image is read-only, so files can't be added to it."
            return
        }
        await serializedWrite { [self] in await withBusy {
            let transfer = beginTransfer(title: "Adding Items", message: "Preparing import…")
            defer { endTransfer(transfer.id) }
            let destination = currentFolderID
            let session = sessionID
            var tally = ImportTally()
            var cancelled = false
            var failure: String?
            for url in urls {
                do {
                    try transfer.flag.check()
                    guard session == sessionID else { throw CancellationError() }
                    try await importHostItem(url, into: destination, on: volume, transfer: transfer, tally: &tally)
                    try await volume.flush()
                } catch is CancellationError {
                    cancelled = true
                    break
                } catch {
                    failure = "Could not import \(url.lastPathComponent): \(error.localizedDescription)"
                    break
                }
            }
            // The image was closed meanwhile: nothing more to do or report.
            guard session == sessionID else { return }
            // Whatever finished before the stop is real content: flush and show it. The final
            // status/error is set after the refresh, which would otherwise clear it.
            await finishWrite(on: volume)
            if cancelled {
                statusMessage = "Import cancelled"
            } else if let failure {
                errorMessage = failure
            } else {
                statusMessage = urls.count == 1 ? "Added \(urls[0].lastPathComponent)" : "Added \(urls.count) items"
                if tally.renamed > 0 {
                    statusMessage += " (renamed \(tally.renamed) to fit the disk's naming rules)"
                }
                if tally.skippedLinks > 0 {
                    statusMessage += tally.skippedLinks == 1 ? " — skipped 1 symbolic link" : " — skipped \(tally.skippedLinks) symbolic links"
                }
            }
        } }
    }

    /// Counts reported after an import.
    private struct ImportTally {
        var renamed = 0
        var skippedLinks = 0
    }

    private func importHostItem(_ url: URL, into folderID: UInt32, on volume: any DiskVolume, transfer: (id: UUID, flag: CancellationFlag), tally: inout ImportTally, depth: Int = 0) async throws {
        try transfer.flag.check()
        guard depth < Self.maximumFolderDepth else { throw HFSError.invalidMove("Folders are nested too deeply to copy.") }
        updateTransfer(transfer.id, message: "Adding \(url.lastPathComponent)…")
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .creationDateKey, .contentModificationDateKey])
        // Classic Mac OS has no symbolic links, and following them could copy something far
        // outside the chosen folder (or loop). They're skipped and counted.
        if values.isSymbolicLink == true {
            tally.skippedLinks += 1
            return
        }
        let hostName = url.lastPathComponent

        if values.isDirectory == true {
            let name = volume.validName(from: hostName)
            if name != hostName { tally.renamed += 1 }
            let folder = try await volume.createFolder(named: name, in: folderID)
            let children = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
            for child in children {
                try await importHostItem(child, into: folder, on: volume, transfer: transfer, tally: &tally, depth: depth + 1)
            }
            return
        }

        // MacBinary (.bin) downloads hold a complete classic file: unpack it, Finder flags
        // and dates included.
        if url.pathExtension.lowercased() == "bin",
           let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 256 << 20,
           let macBinary = MacBinaryFile.decode(Array(try Data(contentsOf: url))) {
            var info = [UInt8](repeating: 0, count: 16)
            info.put16(macBinary.finderFlags, at: 8)
            let metadata = NewFileMetadata(
                fileType: macBinary.fileType, creator: macBinary.creator, finderInfo: info,
                createDate: macBinary.createDate == 0 ? nil : HFSDate.date(macBinary.createDate),
                modifyDate: macBinary.modifyDate == 0 ? nil : HFSDate.date(macBinary.modifyDate)
            )
            try await volume.createFile(named: volume.validName(from: macBinary.name.string), in: folderID, metadata: metadata,
                                        dataFork: HFSForkSource(bytes: macBinary.dataFork), resourceFork: HFSForkSource(bytes: macBinary.resourceFork))
            return
        }

        let name = volume.validName(from: hostName)
        if name != hostName { tally.renamed += 1 }
        let metadata = try HostFiles.metadata(of: url)
        let resource = try HostFiles.readResourceFork(of: url)
        let reader = try HostFileReader(url: url)
        let flag = transfer.flag
        let data = HFSForkSource(length: metadata.dataForkLength) { offset, count in
            try flag.check()
            return try reader.read(at: offset, count: count)
        }
        let (type, creator) = Self.typeAndCreator(for: url, finderInfo: metadata.finderInfo)
        let fileMetadata = NewFileMetadata(fileType: type, creator: creator, finderInfo: metadata.finderInfo,
                                           extendedFinderInfo: metadata.extendedFinderInfo,
                                           createDate: values.creationDate, modifyDate: values.contentModificationDate)
        try await volume.createFile(named: name, in: folderID, metadata: fileMetadata, dataFork: data, resourceFork: HFSForkSource(bytes: resource))
    }

    /// Type and creator from the host file's Finder info when it has them, otherwise a
    /// best guess from the extension so classic Mac OS knows what opens the file.
    nonisolated static func typeAndCreator(for url: URL, finderInfo: [UInt8]?) -> (type: [UInt8], creator: [UInt8]) {
        if let finderInfo, finderInfo.count >= 8, finderInfo[0..<8].contains(where: { $0 != 0 }) {
            return (Array(finderInfo[0..<4]), Array(finderInfo[4..<8]))
        }
        let guesses: [String: (String, String)] = [
            "txt": ("TEXT", "ttxt"), "text": ("TEXT", "ttxt"), "md": ("TEXT", "ttxt"), "readme": ("TEXT", "ttxt"),
            "pict": ("PICT", "ttxt"), "pct": ("PICT", "ttxt"),
            "gif": ("GIFf", "ogle"), "jpg": ("JPEG", "ogle"), "jpeg": ("JPEG", "ogle"), "png": ("PNGf", "ogle"),
            "sit": ("SIT!", "SITx"), "sea": ("APPL", "aust"), "hqx": ("TEXT", "BnHq"), "cpt": ("PACT", "CPCT"),
            "zip": ("ZIP ", "ZIP "), "pdf": ("PDF ", "CARO"), "html": ("TEXT", "MOSS"), "htm": ("TEXT", "MOSS"),
            "dsk": ("dImg", "dCpy"), "img": ("dImg", "dCpy"), "image": ("dImg", "dCpy"),
        ]
        let (type, creator) = guesses[url.pathExtension.lowercased()] ?? ("????", "????")
        return (Array(type.utf8), Array(creator.utf8))
    }

    // MARK: - Exporting to the Mac

    func exportSelected() async {
        let entries = selectedEntries
        guard !entries.isEmpty else { return }

        if entries.count == 1, let entry = entries.first {
            // Single item: a Save As flow, which lets the user rename it on the way out.
            let panel = NSSavePanel()
            panel.nameFieldStringValue = Self.hostName(fromClassicHFSName: entry.name)
            panel.canCreateDirectories = true
            panel.title = "Export File from Volume"
            panel.message = "Choose a destination to export the selected item."
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            await export(entry, to: destination)
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Export \(entries.count) Items"
        panel.message = "Choose a destination folder to export the selected items into."
        guard panel.runModal() == .OK, let destinationFolder = panel.url else { return }
        await export(entries, intoFolder: destinationFolder)
    }

    /// Exports one entry to exactly `destination`, replacing whatever is there: the Save panel
    /// has already asked the user to confirm "Replace".
    func export(_ entry: FileEntry, to destination: URL) async {
        guard let volume else { return }
        await withBusy {
            let transfer = beginTransfer(title: "Exporting Items", message: "Exporting \(entry.name)…")
            defer { endTransfer(transfer.id) }
            do {
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try await exportItem(entry.item, to: destination, from: volume, transfer: transfer)
                statusMessage = "Exported \(entry.name)"
            } catch is CancellationError {
                try? fileManager.removeItem(at: destination)
                statusMessage = "Export cancelled"
            } catch {
                errorMessage = "Could not export \(entry.name): \(error.localizedDescription)"
            }
        }
    }

    /// Exports each entry into `destinationFolder` under its own (host-safe) name.
    func export(_ entries: some Collection<FileEntry>, intoFolder destinationFolder: URL) async {
        guard let volume else { return }
        await withBusy {
            let transfer = beginTransfer(title: "Exporting Items", message: "Preparing export…")
            defer { endTransfer(transfer.id) }
            var exported = 0
            var lastError: Error?
            for entry in entries {
                let destination = destinationFolder.appendingPathComponent(Self.hostName(fromClassicHFSName: entry.name))
                do {
                    try transfer.flag.check()
                    guard !fileManager.fileExists(atPath: destination.path) else {
                        throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destination.path])
                    }
                    try await exportItem(entry.item, to: destination, from: volume, transfer: transfer)
                    exported += 1
                } catch is CancellationError {
                    try? fileManager.removeItem(at: destination)
                    statusMessage = "Export cancelled"
                    return
                } catch {
                    lastError = error
                }
            }
            statusMessage = "Exported \(exported) of \(entries.count) items"
            if let lastError, exported < entries.count {
                errorMessage = lastError.localizedDescription
            }
        }
    }

    /// Writes a file (data fork, resource fork, Finder info, dates) or a whole folder tree to
    /// `destination`. A partially written file is removed if the copy doesn't finish.
    private func exportItem(_ item: VolumeItem, to destination: URL, from volume: any DiskVolume, transfer: (id: UUID, flag: CancellationFlag), depth: Int = 0) async throws {
        try transfer.flag.check()
        guard depth < Self.maximumFolderDepth else { throw HFSError.corrupt("folders are nested too deeply") }
        updateTransfer(transfer.id, message: "Copying \(item.name)…")
        if item.isFolder {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
            for child in try await volume.contents(ofFolder: item.id) {
                try await exportItem(child, to: destination.appendingPathComponent(Self.hostName(fromClassicHFSName: child.name)), from: volume, transfer: transfer, depth: depth + 1)
            }
            var values = URLResourceValues()
            values.creationDate = item.createDate
            values.contentModificationDate = item.modifyDate
            var mutable = destination
            try? mutable.setResourceValues(values)
            return
        }
        do {
            let writer = try HostFileWriter(url: destination)
            let flag = transfer.flag
            try await volume.readFork(item.id, fork: .data) { chunk in
                try flag.check()
                try writer.write(chunk)
            }
            try writer.close()
            let resource = try await volume.readForkBytes(item.id, fork: .resource)
            let info = try await volume.finderInfo(item.id)
            try HostFiles.writeMetadata(to: destination, resourceFork: resource, finderInfo: info.finderInfo, extendedFinderInfo: info.extended, created: item.createDate, modified: item.modifyDate)
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    /// Exports an entry to a private temporary location, for Quick Look, Open, and drags to
    /// other apps. Edits made there don't flow back into the image; use Add Files for that.
    func materializeForPreview(_ entry: FileEntry, purpose: String = "preview") async -> URL? {
        guard let volume else { return nil }
        do {
            let directory = try storage.makeDirectory(purpose)
            let destination = directory.appendingPathComponent(Self.hostName(fromClassicHFSName: entry.name))
            let transfer = activeTransfer ?? (id: UUID(), flag: CancellationFlag())
            try await exportItem(entry.item, to: destination, from: volume, transfer: transfer)
            return destination
        } catch is CancellationError {
            statusMessage = "Copy cancelled"
            return nil
        } catch {
            errorMessage = "Could not copy \(entry.name): \(error.localizedDescription)"
            return nil
        }
    }

    /// Double-click / "Open": folders open in the browser; files open in their default app,
    /// from a temporary copy.
    func openEntry(_ entry: FileEntry) async {
        if entry.isDirectory {
            await navigate(into: entry)
            return
        }
        await withBusy {
            guard let url = await materializeForPreview(entry, purpose: "open") else { return }
            if !NSWorkspace.shared.open(url) {
                errorMessage = "No application could open \(entry.name)."
            }
        }
    }

    /// The provider handed to Finder (or any drop target) when dragging an entry out. The file
    /// is only exported once the drop target actually asks for it.
    func makeDragItemProvider(for entry: FileEntry) -> NSItemProvider {
        guard isOpen else { return NSItemProvider() }
        let typeIdentifier: String
        if entry.isDirectory {
            typeIdentifier = UTType.folder.identifier
        } else {
            let ext = (entry.name as NSString).pathExtension
            typeIdentifier = (!ext.isEmpty ? UTType(filenameExtension: ext)?.identifier : nil) ?? UTType.data.identifier
        }
        let provider = NSItemProvider()
        provider.suggestedName = Self.hostName(fromClassicHFSName: entry.name)
        provider.registerFileRepresentation(forTypeIdentifier: typeIdentifier, fileOptions: [], visibility: .all) { completion in
            Task { @MainActor [weak self] in
                guard let self else {
                    completion(nil, false, CocoaError(.userCancelled)); return
                }
                let transfer = self.beginTransfer(title: "Copying Files", message: "Preparing \(entry.name)…")
                defer { self.endTransfer(transfer.id) }
                guard let url = await self.materializeForPreview(entry, purpose: "drag") else {
                    completion(nil, false, CocoaError(.fileReadUnknown))
                    return
                }
                completion(url, false, nil)
            }
            return nil
        }
        return provider
    }

    // MARK: - Clipboard

    func copySelected() {
        guard !selectedEntries.isEmpty else { return }
        fillClipboard(Array(selectedEntries), operation: .copy)
    }

    /// Marks the selection to be *moved* on the next Paste. Nothing changes until then: the
    /// move happens in one step at paste time, so there is no copy/delete race to lose data in.
    func cutSelected() {
        guard !selectedEntries.isEmpty else { return }
        fillClipboard(Array(selectedEntries), operation: .cut)
    }

    func cutEntry(_ entry: FileEntry) {
        selectedEntries = [entry]
        cutSelected()
    }

    func copyEntry(_ entry: FileEntry) {
        fillClipboard([entry], operation: .copy)
    }

    /// Records the items for in-app Paste, claims the pasteboard immediately with a private
    /// marker, then exports the items in the background and publishes them as ordinary file
    /// URLs so they can also be pasted in Finder. If another app copies something meanwhile,
    /// the marker disappears and Paste uses that instead.
    private func fillClipboard(_ entries: [FileEntry], operation: ClipboardOperation) {
        clipboardExportTask?.cancel()
        if let previous = clipboardExportDirectory {
            storage.remove(previous)
            clipboardExportDirectory = nil
        }
        let token = UUID().uuidString
        internalClipboard = InternalClipboard(session: sessionID, itemIDs: entries.map(\.id), operation: operation, token: token)

        pasteboard.clearContents()
        let marker = NSPasteboardItem()
        marker.setString(token, forType: Self.internalClipboardType)
        pasteboard.writeObjects([marker])
        let verb = operation == .cut ? "Cut" : "Copied"
        statusMessage = entries.count == 1 ? "\(verb) \(entries[0].name)" : "\(verb) \(entries.count) items"

        clipboardExportTask = Task { [weak self] in
            guard let self, let directory = try? self.storage.makeDirectory("clipboard") else { return }
            self.clipboardExportDirectory = directory
            var urls: [URL] = []
            for entry in entries {
                guard !Task.isCancelled, let volume = self.volume else { return }
                let destination = directory.appendingPathComponent(Self.hostName(fromClassicHFSName: entry.name))
                do {
                    try await self.exportItem(entry.item, to: destination, from: volume, transfer: (UUID(), CancellationFlag()))
                    urls.append(destination)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled, self.internalClipboard?.token == token,
                  self.pasteboard.string(forType: Self.internalClipboardType) == token else { return }
            self.pasteboard.clearContents()
            let items: [NSPasteboardItem] = urls.enumerated().map { index, url in
                let item = NSPasteboardItem()
                item.setString(url.absoluteString, forType: .fileURL)
                // The ownership marker rides on the first *file URL* item: Finder may ignore a
                // clipboard whose leading item has only an unknown private type.
                if index == 0 { item.setString(token, forType: Self.internalClipboardType) }
                return item
            }
            self.pasteboard.writeObjects(items)
        }
    }

    func paste() {
        Task { await performPaste() }
    }

    /// Paste, awaitable (the menu command fires it off in a Task).
    func performPaste() async {
        guard isOpen else { return }
        if let clipboard = internalClipboard, clipboard.session == sessionID,
           pasteboard.string(forType: Self.internalClipboardType) == clipboard.token {
            if clipboard.operation == .cut {
                internalClipboard = nil
                await moveItems(clipboard.itemIDs, to: currentFolderID)
            } else {
                await copyItems(clipboard.itemIDs, to: currentFolderID)
            }
            return
        }
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !urls.isEmpty {
            await importFiles(urls: urls)
        }
    }

    /// Duplicates items inside the image, keeping both forks and all Finder info. Pasting into
    /// the folder an item is already in makes "Name copy", as the Finder does.
    func copyItems(_ ids: [UInt32], to folderID: UInt32) async {
        guard let volume else { return }
        guard !isReadOnly else {
            errorMessage = "This image is read-only, so files can't be added to it."
            return
        }
        await serializedWrite { [self] in await withBusy {
            let transfer = beginTransfer(title: "Copying Items", message: "Preparing copy…")
            defer { endTransfer(transfer.id) }
            var copied = 0
            var failure: String?
            for id in ids {
                do {
                    try transfer.flag.check()
                    try await copyRecursively(id, to: folderID, on: volume, transfer: transfer)
                    try await volume.flush()
                    copied += 1
                } catch is CancellationError {
                    statusMessage = "Copy cancelled"
                    break
                } catch {
                    failure = error.localizedDescription
                }
            }
            await finishWrite(on: volume)
            if copied > 0 { statusMessage = copied == 1 ? "Copied 1 item" : "Copied \(copied) items" }
            if let failure { errorMessage = failure }
        } }
    }

    private func copyRecursively(_ id: UInt32, to folderID: UInt32, on volume: any DiskVolume, transfer: (id: UUID, flag: CancellationFlag), depth: Int = 0) async throws {
        try transfer.flag.check()
        guard depth < Self.maximumFolderDepth else { throw HFSError.invalidMove("Folders are nested too deeply to copy.") }
        let item = try await volume.item(id)
        updateTransfer(transfer.id, message: "Copying \(item.name)…")
        let name = try await availableName(for: item.name, in: folderID, on: volume)
        if item.isFolder {
            // Re-checked at every level, against the volume as it is now: copying a folder into
            // itself (or below itself) would never finish — including when a Cut and Paste
            // moved the destination while this copy was running.
            let destinationPath = try await volume.path(of: folderID)
            if folderID == id || destinationPath.contains(where: { $0.id == id }) {
                throw HFSError.invalidMove("A folder can't be copied into itself.")
            }
            let children = try await volume.contents(ofFolder: id)
            let folder = try await volume.createFolder(named: name, in: folderID)
            for child in children {
                try await copyRecursively(child.id, to: folder, on: volume, transfer: transfer, depth: depth + 1)
            }
        } else {
            try await volume.copyFile(id, to: folderID, name: name)
        }
    }

    /// `name` if it's free in the folder, otherwise "name copy", "name copy 2", …, with the
    /// original part shortened as needed to fit the volume's name length limit.
    private func availableName(for name: String, in folderID: UInt32, on volume: any DiskVolume) async throws -> String {
        if await volume.child(named: name, inFolder: folderID) == nil { return name }
        for attempt in 1...999 {
            let suffix = attempt == 1 ? " copy" : " copy \(attempt)"
            var base = name
            while !base.isEmpty, volume.validName(from: base + suffix) != base + suffix { base.removeLast() }
            let candidate = base + suffix
            if await volume.child(named: candidate, inFolder: folderID) == nil { return candidate }
        }
        throw HFSError.alreadyExists(name)
    }

    /// Moves items into `folderID` within the image (Cut, then Paste).
    func moveItems(_ ids: [UInt32], to folderID: UInt32) async {
        guard let volume else { return }
        guard !isReadOnly else {
            errorMessage = "This image is read-only, so files can't be moved."
            return
        }
        await serializedWrite { [self] in await withBusy {
            var moved = 0
            var failure: String?
            for id in ids {
                do {
                    let item = try await volume.item(id)
                    if item.parentID != folderID {
                        try await volume.move(id, to: folderID)
                    }
                    moved += 1
                } catch {
                    failure = error.localizedDescription
                }
            }
            await finishWrite(on: volume)
            statusMessage = moved == ids.count
                ? (moved == 1 ? "Moved 1 item" : "Moved \(moved) items")
                : "Moved \(moved) of \(ids.count) items"
            if let failure { errorMessage = failure }
        } }
    }

    // MARK: - Drag and drop

    func handleDroppedFiles(providers: [NSItemProvider]) -> Bool {
        guard isOpen else { return false }
        let collector = URLCollector()
        let group = DispatchGroup()

        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                // Extract the URL (a Sendable value) here: `item` itself isn't Sendable.
                var droppedURL: URL?
                if let url = item as? URL {
                    droppedURL = url
                } else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    droppedURL = url
                }
                // Leave only after the append lands, or `notify` can fire with an empty list.
                Task {
                    if let droppedURL {
                        await collector.append(droppedURL)
                    }
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) {
            Task { @MainActor in
                let urls = await collector.allURLs()
                if !urls.isEmpty {
                    await self.importFiles(urls: urls)
                }
            }
        }
        return true
    }

    /// Opens the first dropped file as a disk image (the empty window accepts images).
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

    /// Writes pending changes; called when the app quits.
    func prepareForTermination() async {
        if let volume { try? await volume.flush() }
        storage.removeLaunchDirectory()
    }

    /// What the user is told when a volume opens read-only for a reason of its own.
    private static func message(for cause: ReadOnlyCause) -> String? {
        switch cause {
        case .requested:
            return nil // the specific reason (permissions, container format) is added separately
        case .locked:
            return "This volume is locked, so it was opened read-only."
        case .notCleanlyUnmounted:
            return "This volume wasn't ejected properly, or another computer or emulator is using it right now, so it was opened read-only. If nothing else is using it, you can open it for writing anyway; Mac OS will check the disk the next time it mounts it."
        case .journaled:
            return "This is a journaled Mac OS Extended volume (from Mac OS X), which FloppyFox can open read-only."
        case .inUse:
            return "Another program is writing to this image, so it was opened read-only."
        }
    }

    // MARK: - Names

    /// Returns a classic-HFS-safe filename. HFS names are limited to 31 Mac Roman bytes and
    /// use `:` as the path separator. Characters outside Mac Roman are transliterated when
    /// possible; anything still unsupported receives a deterministic ASCII Unicode escape so
    /// it cannot become an invalid or silently lossy catalog name.
    nonisolated static func classicHFSName(from hostName: String) -> String {
        let normalized = hostName.precomposedStringWithCanonicalMapping
        var compatible = ""

        for character in normalized {
            let original = String(character)
            if original == ":" {
                compatible.append("-")
                continue
            }
            if original.data(using: .macOSRoman, allowLossyConversion: false) != nil {
                compatible.append(original)
                continue
            }

            let folded = original.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            if folded.data(using: .macOSRoman, allowLossyConversion: false) != nil {
                compatible.append(folded)
            } else {
                for scalar in original.unicodeScalars {
                    compatible.append("~\(String(scalar.value, radix: 16, uppercase: true))")
                }
            }
        }

        // "." and ".." are illegal HFS names (fsck_hfs rejects them).
        if compatible.isEmpty || compatible == "." || compatible == ".." { compatible = "Untitled" }

        var result = ""
        for character in compatible {
            let candidate = result + String(character)
            guard let bytes = candidate.data(using: .macOSRoman, allowLossyConversion: false), bytes.count <= 31 else { break }
            result = candidate
        }
        return result.isEmpty ? "Untitled" : result
    }

    /// Classic HFS permits `/` inside a catalog name, while host URLs interpret it as a path
    /// separator. macOS traditionally presents that classic character as `:` on modern
    /// filesystems, where it is a valid single filename component.
    ///
    /// Classic Mac OS also allows names like `..` and `.`, which are path traversal here:
    /// exporting a folder named `..` would write its contents into the *parent* of the folder
    /// the user chose. Those, and the empty name, get a visible substitute.
    nonisolated static func hostName(fromClassicHFSName hfsName: String) -> String {
        let name = hfsName.replacingOccurrences(of: "/", with: ":")
        switch name {
        case "": return "Untitled"
        case ".", "..": return name.replacingOccurrences(of: ".", with: "\u{2024}") // ONE DOT LEADER
        default: return name
        }
    }

    // MARK: - Other programs

    /// PIDs of *other* processes that have `path` open, per `lsof -t` (bare PIDs on stdout).
    /// Best effort: inside the App Sandbox lsof can't inspect other processes and this
    /// returns no PIDs.
    ///
    /// Only stdout is meaningful. lsof exits 1 whenever nothing has the file open, and also
    /// prints warnings to stderr about unrelated filesystems — e.g. an unreachable Time Capsule
    /// SMB mount — which must not be read as "the file is in use".
    nonisolated static func processesHoldingOpen(_ path: String) async -> [Int32] {
        guard FileManager.default.isExecutableFile(atPath: "/usr/sbin/lsof") else { return [] }
        let (out, _, _) = await runProcess("/usr/sbin/lsof", ["-t", "--", path])
        return parseLsofPIDs(out, excluding: ProcessInfo.processInfo.processIdentifier)
    }

    nonisolated static func parseLsofPIDs(_ output: String, excluding ownPID: Int32) -> [Int32] {
        output.split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0 != ownPID }
    }

    nonisolated static func runProcess(_ executable: String, _ arguments: [String]) async -> (String, String, Int32) {
        await Task.detached(priority: .userInitiated) {
            runProcessBlocking(executable, arguments)
        }.value
    }

    private nonisolated static func runProcessBlocking(_ executable: String, _ arguments: [String]) -> (String, String, Int32) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do {
            try proc.run()
        } catch {
            return ("", "\(error)", Int32(-1))
        }
        // Both pipes must be drained *while* the child runs: a pipe holds only 64 KB, and a
        // child that fills it blocks on write and never exits. stderr is drained on a second
        // thread so neither pipe can stall the other.
        let errData = DrainedData()
        let errDrained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            errData.set(errPipe.fileHandleForReading.readDataToEndOfFile())
            errDrained.signal()
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        errDrained.wait()
        proc.waitUntilExit()
        return (decodeProcessOutput(outData), decodeProcessOutput(errData.get()), proc.terminationStatus)
    }

    /// Prefer UTF-8 and fall back to Mac Roman, so output naming classic files survives.
    nonisolated static func decodeProcessOutput(_ data: Data) -> String {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .macOSRoman)
            ?? ""
    }
}

/// Hands a pipe's contents from the thread that drained it back to `runProcess`.
private final class DrainedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func set(_ value: Data) {
        lock.lock()
        data = value
        lock.unlock()
    }

    func get() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}
