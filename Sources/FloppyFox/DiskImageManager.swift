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
    case cut
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
    /// Finder metadata and an icon decoded from the classic resource fork. These are filled
    /// by the hfsutils backend, whose synthetic URLs cannot be resolved by NSWorkspace.
    let finderType: String?
    let finderCreator: String?
    let dataForkSize: Int?
    let resourceForkSize: Int?
    let isInvisible: Bool
    let isLocked: Bool
    let resourceIconPNG: Data?

    init(
        url: URL,
        isDirectory: Bool,
        size: Int?,
        hfsPath: String? = nil,
        finderType: String? = nil,
        finderCreator: String? = nil,
        dataForkSize: Int? = nil,
        resourceForkSize: Int? = nil,
        isInvisible: Bool = false,
        isLocked: Bool = false,
        resourceIconPNG: Data? = nil
    ) {
        self.url = url
        self.isDirectory = isDirectory
        self.size = size
        self.hfsPath = hfsPath
        self.finderType = finderType
        self.finderCreator = finderCreator
        self.dataForkSize = dataForkSize
        self.resourceForkSize = resourceForkSize
        self.isInvisible = isInvisible
        self.isLocked = isLocked
        self.resourceIconPNG = resourceIconPNG
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
            if let resourceIconPNG, let image = NSImage(data: resourceIconPNG) {
                return image
            }
            if finderType == "APPL", let image = NSImage(named: "ClassicMac") ?? Bundle.module.image(forResource: "ClassicMac") {
                return image
            }
            if ["dsk", "img", "hda", "vhd"].contains((name as NSString).pathExtension.lowercased()),
               let image = NSImage(named: "Floppy") ?? Bundle.module.image(forResource: "Floppy") {
                return image
            }
            if isDirectory {
                return workspace.icon(for: .folder)
            }
            if let image = NSImage(named: "ClassicDocument") ?? Bundle.module.image(forResource: "ClassicDocument") {
                image.isTemplate = false
                return image
            }
            return workspace.icon(for: .data)
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

// `@unchecked Sendable` so `self` can be captured into the detached copy tasks below (only
// ever touched there via `await self.isTransferCancelled(...)`, which re-enters the main
// actor) — every stored property remains MainActor-isolated and is otherwise never accessed
// off that actor.
@MainActor
final class DiskImageManager: ObservableObject, @unchecked Sendable {
    @Published var imageURL: URL?
    @Published var mountPoint: URL?
    @Published var mountedDevice: String?
    @Published var currentDirectory: URL?
    @Published var entries: [FileEntry] = []
    @Published var selectedEntries: Set<FileEntry> = []
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
    @Published var transferTitle: String?
    @Published var transferMessage: String?

    // For hfsutils-based backend when the image cannot be mounted
    @Published var currentHFSPath: String? = ":" // ':' denotes root for hfsutils

    private let fileManager = FileManager.default
    private var internalClipboardURLs: [URL] = []
    private var internalClipboardOperation: ClipboardOperation = .copy
    private var internalClipboardToken: String?
    private var clipboardExportTask: Task<Void, Never>?
    private var activeTransferID: UUID?
    private var cancelledTransferIDs: Set<UUID> = []
    private var pendingTransferMessage: String?
    private var transferDelayTask: Task<Void, Never>?
    private var busyDepth = 0

    private static let internalClipboardType = NSPasteboard.PasteboardType("com.floppyfox.hfs-clipboard")

    var isMounted: Bool {
        mountPoint != nil
    }

    /// Convenience for call sites that only care about "exactly one item selected" (Quick
    /// Look, the single-file Save As flow, clearing selection after navigation, the detail
    /// pane's single-item view) — nil unless the selection has exactly one entry. Setting it
    /// replaces the whole selection with just that one item (or clears it, for nil).
    var selectedEntry: FileEntry? {
        get { selectedEntries.count == 1 ? selectedEntries.first : nil }
        set { selectedEntries = newValue.map { [$0] } ?? [] }
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
    private var hrmdirPath: String? = nil
    private var hrenamePath: String? = nil
    private var humountPath: String? = nil

    // Once we've confirmed (for the currently-open image) that no hdiutil device is attached
    // and the file isn't locked, there's no need to re-run that hdiutil-info/lsof check before
    // every single hls/hcopy/hdel call — that redundant work was the main reason every click
    // felt sluggish. Reset whenever a new image is opened or the current one is closed.
    private var hfsUtilsPrepared = false

    // hfsutils tracks "the current volume" as global state in ~/.hcwd, shared across every
    // hmount/hls/hcopy/hdel/humount invocation regardless of which Swift Task made it — it is
    // NOT scoped to a single hmount...humount pair. Several UI actions (delete, paste, a
    // directory refresh) each kick off their own independent async Task, so without this,
    // two of them running at the same time (e.g. Cut firing a fire-and-forget delete Task,
    // then Paste starting before that delete finished) interleave their hmount/hcopy/humount
    // calls and corrupt each other's session — reproduced as: multi-file move only actually
    // moving the first file, with the rest failing to read from the (now wrongly-unmounted or
    // differently-positioned) volume. This tail-chained queue makes every top-level hfsutils
    // operation wait for the previous one to fully finish before it starts.
    private var hfsUtilsQueueTail: Task<Void, Never> = Task {}

    // IMPORTANT: never call this from *within* another `serializedHFSUtilsOperation` closure
    // that is itself still awaiting completion — since each call waits for the previously
    // queued one to finish first, a call nested inside an unfinished outer one would deadlock
    // (the outer waits on the inner to return; the inner waits on the outer to finish first).
    // Every hmount/hls/hcopy/hdel/humount call site in this file is wrapped at exactly one
    // "leaf" level (`hfsList`, `exportHFSEntry`, and the delete/import per-item blocks) —
    // higher-level callers (`materializeForPreview`, `exportOneFile`, the outer loops in
    // `deleteEntries`/`importFiles`) just call those leaf functions as plain sequential
    // `await`s, which queue safely one after another instead of nesting.
    private func serializedHFSUtilsOperation<T: Sendable>(_ work: @escaping () async throws -> T) async throws -> T {
        let previous = hfsUtilsQueueTail
        let task = Task<Result<T, Error>, Never> {
            _ = await previous.value
            do {
                return .success(try await work())
            } catch {
                return .failure(error)
            }
        }
        hfsUtilsQueueTail = Task {
            _ = await task.value
        }
        return try await task.value.get()
    }

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
        let map = ["hls", "hcopy", "hdel", "hmkdir", "hrmdir", "hrename", "humount"]
        for tool in map {
            let p = "\(prefix)/\(tool)"
            if fileManager.isExecutableFile(atPath: p) {
                switch tool {
                case "hls": hlsPath = p
                case "hcopy": hcopyPath = p
                case "hdel": hdelPath = p
                case "hmkdir": hmkdirPath = p
                case "hrmdir": hrmdirPath = p
                case "hrename": hrenamePath = p
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
        if hrmdirPath == nil { hrmdirPath = fileManager.isExecutableFile(atPath: "/opt/homebrew/bin/hrmdir") ? "/opt/homebrew/bin/hrmdir" : "/usr/local/bin/hrmdir" }
        if hrenamePath == nil { hrenamePath = fileManager.isExecutableFile(atPath: "/opt/homebrew/bin/hrename") ? "/opt/homebrew/bin/hrename" : "/usr/local/bin/hrename" }
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

    /// Starts a non-modal progress presentation after a short delay. Fast filesystem actions
    /// finish before the delay and never flash UI; recursive transfers remain visible.
    private func beginTransfer(title: String, message: String) -> UUID {
        let id = UUID()
        cancelledTransferIDs.remove(id)
        activeTransferID = id
        pendingTransferMessage = message
        transferDelayTask?.cancel()
        transferDelayTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, let self, self.activeTransferID == id else { return }
            self.transferTitle = title
            self.transferMessage = self.pendingTransferMessage
        }
        return id
    }

    private func updateTransfer(_ id: UUID, message: String) {
        guard activeTransferID == id, !cancelledTransferIDs.contains(id) else { return }
        pendingTransferMessage = message
        if transferTitle != nil {
            transferMessage = message
        }
    }

    private func endTransfer(_ id: UUID) {
        cancelledTransferIDs.remove(id)
        guard activeTransferID == id else { return }
        transferDelayTask?.cancel()
        transferDelayTask = nil
        activeTransferID = nil
        pendingTransferMessage = nil
        transferTitle = nil
        transferMessage = nil
    }

    func cancelActiveTransfer() {
        guard let id = activeTransferID else { return }
        cancelledTransferIDs.insert(id)
        transferMessage = "Cancelling…"
        clipboardExportTask?.cancel()
    }

    private func checkCancellation(_ id: UUID?) throws {
        if Task.isCancelled || id.map(cancelledTransferIDs.contains) == true {
            throw CancellationError()
        }
    }

    func openImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.supportedImageTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Open HFS Disk Image"
        panel.message = "Choose a .dsk, .img, .hda, or .vhd file containing an Apple HFS filesystem."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await attachImage(imageURL: url) }
    }

    func attachImage(imageURL: URL) async {
        await withBusy {
            await detachImageIfMounted()
            hfsUtilsPrepared = false

            var imageToAttach = imageURL
            var vhdReason: String?
            if imageURL.pathExtension.lowercased() == "vhd" {
                do {
                    let preparation = try await VHDImage.prepareForReading(imageURL)
                    imageToAttach = preparation.imageURL
                    if preparation.imageURL != imageURL {
                        tempImageCopyURL = preparation.imageURL
                        vhdReason = "Dynamic VHD images are expanded to a temporary raw disk and opened read-only. Changes cannot be written back to the VHD container."
                    }
                } catch {
                    self.imageURL = nil
                    self.errorMessage = error.localizedDescription
                    self.statusMessage = "Failed to open VHD image"
                    return
                }
            }

            let fileReadOnlyReason = await detectReadOnlyReason(for: imageURL.path)
            let reason = vhdReason ?? fileReadOnlyReason
            self.isReadOnly = reason != nil
            self.readOnlyReason = reason

            do {
                let result = try await attachImageUsingHdiutil(imageToAttach, readOnly: self.isReadOnly)
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
    private nonisolated func runProcess(
        _ executable: String,
        _ arguments: [String],
        environment additions: [String: String] = [:]
    ) async -> (String, String, Int32) {
        await Task.detached(priority: .userInitiated) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: executable)
            proc.arguments = arguments
            if !additions.isEmpty {
                proc.environment = ProcessInfo.processInfo.environment.merging(additions) { _, new in new }
            }
            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            do {
                try proc.run()
                proc.waitUntilExit()
                let out = Self.decodeProcessOutput(outPipe.fileHandleForReading.readDataToEndOfFile())
                let err = Self.decodeProcessOutput(errPipe.fileHandleForReading.readDataToEndOfFile())
                return (out, err, proc.terminationStatus)
            } catch {
                return ("", "\(error)", Int32(-1))
            }
        }.value
    }

    /// macOS tools emit UTF-8, while hfsutils emits classic Mac Roman filenames. A strict
    /// UTF-8 decode used to turn an entire directory listing into an empty string as soon as
    /// one filename contained a legacy high-bit character (for example After Dark's disk
    /// image). Prefer UTF-8 and fall back to Mac Roman so both tool families are preserved.
    nonisolated static func decodeProcessOutput(_ data: Data) -> String {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .macOSRoman)
            ?? ""
    }

    private nonisolated func runCommand(_ cmd: [String]) async -> (String, String, Int32) {
        await runProcess(cmd[0], Array(cmd.dropFirst()))
    }

    /// Foundation's `Process.arguments` always encodes strings as UTF-8, but hfsutils expects
    /// HFS path arguments as raw Mac Roman bytes. Run through a fixed shell shim that decodes
    /// ASCII octal escapes into the required byte sequences immediately before `exec`.
    /// Non-HFS arguments (host paths and flags) remain UTF-8.
    private nonisolated func runHFSCommand(
        _ cmd: [String],
        hfsArgumentIndices: Set<Int>
    ) async -> (String, String, Int32) {
        guard !cmd.isEmpty else { return ("", "Missing command", -1) }
        var environment: [String: String] = [:]
        for index in 1..<cmd.count {
            let encoding: String.Encoding = hfsArgumentIndices.contains(index) ? .macOSRoman : .utf8
            guard let bytes = cmd[index].data(using: encoding, allowLossyConversion: false) else {
                return ("", "Path cannot be represented using the classic Mac character set: \(cmd[index])", -1)
            }
            environment["FLOPPYFOX_HFS_ARG_\(index - 1)"] = bytes.map { String(format: "\\%03o", $0) }.joined()
        }
        let script = #"""
        program="$1"
        count="$2"
        shift 2
        index=0
        while [ "$index" -lt "$count" ]; do
            name="FLOPPYFOX_HFS_ARG_$index"
            encoded=$(/usr/bin/printenv "$name")
            decoded=$(printf '%b' "$encoded")
            set -- "$@" "$decoded"
            index=$((index + 1))
        done
        exec "$program" "$@"
        """#
        return await runProcess(
            "/bin/sh",
            ["-c", script, "floppyfox-hfs-command", cmd[0], String(cmd.count - 1)],
            environment: environment
        )
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
                }
            }
            // `-nomount` lists partition slices before the parent disk (for example disk4s1,
            // disk4s2, disk4s3, then disk4). Partition discovery and detach must receive the
            // whole disk; selecting the first entity leaves classic-HFS VHDs attached and
            // locked just before the hfsutils fallback tries to open them.
            device = Self.preferredWholeDiskDevice(
                from: entities.compactMap { $0["dev-entry"] as? String }
            )
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

    private func prepareForHFSUtils(imagePath: String) async throws {
        if hfsUtilsPrepared { return }

        let attached = await findAttachedDevices(for: imagePath)
        if !attached.isEmpty {
            // Confirmation is intentionally always enabled: encountering an attached raw
            // device is uncommon, and detaching it is significant enough to keep explicit.
            let alert = NSAlert()
            alert.messageText = "Detach device(s) for image?"
            alert.informativeText = "The image appears to be attached as raw device(s): \(attached.joined(separator: ", ")).\nDetaching them is required to allow exclusive access for HFS operations. Detaching is safe but will unmount the raw device. Proceed?"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Detach")
            alert.addButton(withTitle: "Use Temporary Copy")
            alert.addButton(withTitle: "Cancel")

            let resp = alert.runModal()
            if resp == .alertFirstButtonReturn {
                for dev in attached {
                    do {
                        try await runHdiutilDetach(device: dev)
                        print("Detached \(dev) for image \(imagePath)")
                    } catch {
                        print("Failed to detach \(dev): \(error)")
                    }
                }
            } else if resp == .alertSecondButtonReturn {
                try await createTempCopyAndUse(imagePath: imagePath)
                hfsUtilsPrepared = true
                return
            } else {
                throw NSError(domain: "HFSApp", code: 1, userInfo: [NSLocalizedDescriptionKey: "User cancelled detaching devices"]) as Error
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
            cleanupTempCopyIfAny()
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

    static var supportedImageTypes: [UTType] {
        ["dsk", "img", "hda", "vhd"].compactMap { UTType(filenameExtension: $0) }
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
                    // Every hfsutils row already carries its exact full HFS path. Using that
                    // makes navigation idempotent if two Open tasks overlap; rebuilding from
                    // mutable `currentHFSPath` could otherwise turn `:Games` into
                    // `:Games:Games` while the first directory listing was still awaiting.
                    let previousPath = currentHFSPath
                    let parentPath = previousPath ?? ":"
                    let destinationPath = entry.hfsPath ?? (parentPath.hasSuffix(":")
                        ? "\(parentPath)\(entry.name)"
                        : "\(parentPath):\(entry.name)")
                    currentHFSPath = destinationPath
                    do {
                        try await loadDirectory(at: URL(fileURLWithPath: "/"))
                    } catch {
                        // A failed listing should not strand subsequent Refresh/Up actions at
                        // a path that was never successfully opened. Do not overwrite a newer
                        // navigation that may have completed while this operation was awaiting.
                        if currentHFSPath == destinationPath {
                            currentHFSPath = previousPath
                        }
                        throw error
                    }
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

    func navigate(toMountedDirectory directory: URL) async {
        guard isMounted else { return }
        await withBusy {
            do {
                try await loadDirectory(at: directory)
                selectedEntry = nil
            } catch {
                self.errorMessage = DiskImageError.loadDirectoryFailed(directory, error).localizedDescription
            }
        }
    }

    func navigate(toHFSDirectory path: String) async {
        guard usingHFSUtils else { return }
        await withBusy {
            let previousPath = currentHFSPath
            currentHFSPath = path
            do {
                try await loadDirectory(at: URL(fileURLWithPath: "/"))
                selectedEntry = nil
            } catch {
                if currentHFSPath == path {
                    currentHFSPath = previousPath
                }
                self.errorMessage = DiskImageError.loadDirectoryFailed(URL(fileURLWithPath: "/"), error).localizedDescription
            }
        }
    }

    func deleteSelected() {
        guard !selectedEntries.isEmpty else { return }
        Task { await deleteEntries(selectedEntries) }
    }

    func deleteEntry(_ entry: FileEntry) async {
        await deleteEntries([entry])
    }

    /// Deletes every entry in `entries` (one file/folder at a time — hfsutils' `hdel` has no
    /// batch form), wrapped in a single busy indicator and a single final refresh/status
    /// message rather than one per item.
    func deleteEntries(_ entries: some Collection<FileEntry>) async {
        guard !entries.isEmpty else { return }
        guard !isReadOnly else {
            self.errorMessage = entries.count == 1
                ? "This image is read-only, so \(entries.first!.name) can't be deleted."
                : "This image is read-only, so these items can't be deleted."
            return
        }
        await withBusy {
            let progressID = beginTransfer(title: "Deleting Items", message: "Preparing to delete…")
            defer { endTransfer(progressID) }
            var deletedNames: [String] = []
            var lastError: String?

            for entry in entries {
                if (try? checkCancellation(progressID)) == nil { break }
                updateTransfer(progressID, message: "Deleting \(entry.name)…")
                if isMounted {
                    do {
                        try await Task.detached(priority: .userInitiated) {
                            try FileManager.default.removeItem(at: entry.url)
                        }.value
                        selectedEntries.remove(entry)
                        deletedNames.append(entry.name)
                    } catch {
                        lastError = DiskImageError.deleteFailed(entry.url, error).localizedDescription
                    }
                    continue
                }

                // hfsutils backend
                guard usingHFSUtils, let image = imageURL else {
                    lastError = "Delete not supported for this backend"
                    continue
                }
                do {
                    try await deleteHFSEntryRecursive(entry, imagePath: image.path, progressID: progressID)
                    selectedEntries.remove(entry)
                    deletedNames.append(entry.name)
                } catch is CancellationError {
                    statusMessage = "Delete cancelled"
                    break
                } catch {
                    lastError = error.localizedDescription
                }
            }

            if !deletedNames.isEmpty {
                statusMessage = deletedNames.count == 1 ? "Deleted \(deletedNames[0])" : "Deleted \(deletedNames.count) items"
                await refresh()
            }
            if let lastError {
                errorMessage = lastError
            }
        }
    }

    func copySelected() {
        guard !selectedEntries.isEmpty else { return }
        let selected = Array(selectedEntries)
        if isMounted {
            let urls = selected.map { $0.url }
            internalClipboardURLs = urls
            internalClipboardOperation = .copy
            publishClipboard(urls: urls)
            statusMessage = urls.count == 1 ? "Copied \(selected[0].name)" : "Copied \(urls.count) items"
            return
        }
        // For hfsutils backend, store HFS paths as pseudo-URLs using scheme hfs://
        guard usingHFSUtils, let image = imageURL else { return }
        internalClipboardURLs = selected.compactMap { entry in
            let hfsPath = pathForEntry(entry)
            return URL(string: "hfs://localhost\(image.path)?path=\(hfsPath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? hfsPath)")
        }
        internalClipboardOperation = .copy
        prepareHFSClipboard(entries: selected)
    }

    /// Marks the current selection to be moved on the next Paste, rather than deleting the
    /// originals right away. An earlier version of Cut called `copySelected()` immediately
    /// followed by `deleteSelected()` (which itself just fires an unawaited background delete
    /// Task) — since nothing tied that delete to the *following* Paste, a fast Cut-then-Paste
    /// would race the delete against Paste's own read of the same files, and depending on which
    /// finished first, Paste could find the originals already gone (or, before the hfsutils
    /// operation queue existed, find the volume's mount state corrupted by the two overlapping
    /// hmount/hcopy/hdel/humount sequences). Deferring the delete to `paste()` — after the copy
    /// to the new location has actually succeeded — removes the race entirely.
    func cutSelected() {
        guard !selectedEntries.isEmpty else { return }
        let selected = Array(selectedEntries)
        if isMounted {
            let urls = selected.map { $0.url }
            internalClipboardURLs = urls
            internalClipboardOperation = .cut
            publishClipboard(urls: urls)
            statusMessage = urls.count == 1 ? "Cut \(selected[0].name)" : "Cut \(urls.count) items"
            return
        }
        guard usingHFSUtils, let image = imageURL else { return }
        internalClipboardURLs = selected.compactMap { entry in
            let hfsPath = pathForEntry(entry)
            return URL(string: "hfs://localhost\(image.path)?path=\(hfsPath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? hfsPath)")
        }
        internalClipboardOperation = .cut
        prepareHFSClipboard(entries: selected)
    }

    func cutEntry(_ entry: FileEntry) {
        selectedEntries = [entry]
        cutSelected()
    }

    func copyEntry(_ entry: FileEntry) {
        if isMounted {
            internalClipboardURLs = [entry.url]
            internalClipboardOperation = .copy
            publishClipboard(urls: [entry.url])
            statusMessage = "Copied \(entry.name)"
            return
        }
        // For hfsutils backend, store HFS path as pseudo-URL using scheme hfs://
        guard usingHFSUtils else { return }
        let hfsPath = pathForEntry(entry)
        if let image = imageURL {
            let pseudo = URL(string: "hfs://localhost\(image.path)?path=\(hfsPath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? hfsPath)")
            internalClipboardURLs = pseudo.map { [$0] } ?? []
            internalClipboardOperation = .copy
            prepareHFSClipboard(entries: [entry])
        }
    }

    /// Publishes both a private ownership marker (for lossless in-app copy/move) and ordinary
    /// file URLs (for Finder and other macOS apps). If another app copies something later, the
    /// marker disappears and Paste correctly consumes that app's clipboard instead of stale
    /// internal state.
    private func publishClipboard(urls: [URL], token: String = UUID().uuidString) {
        clipboardExportTask?.cancel()
        internalClipboardToken = token
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let items: [NSPasteboardItem] = urls.enumerated().map { index, url in
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            if index == 0 {
                // Keep our private ownership marker on the first *file URL* item. Finder may
                // ignore a clipboard whose leading item contains only an unknown private type,
                // which particularly prevented copied folders from becoming pasteable.
                item.setString(token, forType: Self.internalClipboardType)
            }
            return item
        }
        pasteboard.writeObjects(items)
    }

    private func prepareHFSClipboard(entries: [FileEntry]) {
        clipboardExportTask?.cancel()
        let token = UUID().uuidString
        internalClipboardToken = token

        // Claim the pasteboard immediately, so an in-app Paste made while extraction is still
        // running uses the internal HFS paths rather than whatever Finder previously copied.
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let marker = NSPasteboardItem()
        marker.setString(token, forType: Self.internalClipboardType)
        pasteboard.writeObjects([marker])
        statusMessage = entries.count == 1 ? "Preparing \(entries[0].name) for copying…" : "Preparing \(entries.count) items for copying…"

        clipboardExportTask = Task { [weak self] in
            guard let self else { return }
            let progressID = self.beginTransfer(
                title: "Copying Files",
                message: entries.count == 1 ? "Preparing \(entries[0].name)…" : "Preparing \(entries.count) items…"
            )
            defer { self.endTransfer(progressID) }
            var urls: [URL] = []
            for entry in entries {
                guard (try? self.checkCancellation(progressID)) != nil else {
                    self.statusMessage = "Copy cancelled"
                    return
                }
                guard let url = await self.materializeForPreview(entry, progressID: progressID) else {
                    if (try? self.checkCancellation(progressID)) == nil { return }
                    self.errorMessage = "Could not copy \(entry.name) to the macOS clipboard."
                    return
                }
                urls.append(url)
            }
            guard !Task.isCancelled,
                  self.internalClipboardToken == token,
                  NSPasteboard.general.string(forType: Self.internalClipboardType) == token else { return }
            // Keep the same token while replacing the marker-only clipboard with real file
            // URLs Finder can paste. The temporary files remain alive for the app session.
            self.clipboardExportTask = nil
            self.publishClipboard(urls: urls, token: token)
            self.statusMessage = entries.count == 1 ? "Copied \(entries[0].name)" : "Copied \(entries.count) items"
        }
    }

    func paste() {
        guard let target = currentDirectory ?? mountPoint ?? (usingHFSUtils ? URL(fileURLWithPath: "/") : nil) else { return }
        let pasteboard = NSPasteboard.general
        let ownsPasteboard = internalClipboardToken != nil
            && pasteboard.string(forType: Self.internalClipboardType) == internalClipboardToken

        if ownsPasteboard, internalClipboardOperation == .cut, !internalClipboardURLs.isEmpty {
            let sources = internalClipboardURLs
            internalClipboardURLs = []
            internalClipboardOperation = .copy
            internalClipboardToken = nil
            Task { await moveFiles(urls: sources, destination: target) }
            return
        }

        if ownsPasteboard, !internalClipboardURLs.isEmpty {
            Task { await importFiles(urls: internalClipboardURLs, destination: target) }
            return
        }

        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !urls.isEmpty {
            Task { await importFiles(urls: urls, destination: target) }
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
        return Self.preferredWholeDiskDevice(
            from: entities.compactMap { $0["dev-entry"] as? String }
        )
    }

    nonisolated static func preferredWholeDiskDevice(from devices: [String]) -> String? {
        if let wholeDisk = devices.first(where: { device in
            device.range(of: #"^/dev/disk[0-9]+$"#, options: .regularExpression) != nil
        }) {
            return wholeDisk
        }
        return devices.first
    }

    func exportSelected() async {
        await withBusy {
            // if using hfsutils, ensure no hdiutil attached device blocks the file
            if usingHFSUtils, let image = imageURL {
                try? await prepareForHFSUtils(imagePath: image.path)
            }
            let entries = selectedEntries
            guard !entries.isEmpty else { return }

            if entries.count == 1, let entry = entries.first {
                // Single file: preserve the existing "Save As" flow, which lets the user
                // rename the file on the way out, not just pick a folder.
                let panel = NSSavePanel()
                panel.nameFieldStringValue = Self.hostName(fromClassicHFSName: entry.name)
                panel.canCreateDirectories = true
                panel.title = "Export File from Volume"
                panel.message = "Choose a destination to export the selected item."
                guard panel.runModal() == .OK, let destination = panel.url else { return }

                let progressID = beginTransfer(title: "Exporting Items", message: "Exporting \(entry.name)…")
                defer { endTransfer(progressID) }
                switch await exportOneFile(entry, to: destination, progressID: progressID) {
                case .success:
                    statusMessage = "Exported \(entry.name)"
                case .failure(is CancellationError):
                    statusMessage = "Export cancelled"
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                }
                return
            }

            // Multiple files: ask for a destination folder and copy each one in, keeping its
            // original name.
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.title = "Export \(entries.count) Items"
            panel.message = "Choose a destination folder to export the selected items into."
            guard panel.runModal() == .OK, let destinationFolder = panel.url else { return }

            let progressID = beginTransfer(title: "Exporting Items", message: "Preparing export…")
            defer { endTransfer(progressID) }
            var exportedCount = 0
            var lastError: Error?
            for entry in entries {
                guard (try? checkCancellation(progressID)) != nil else {
                    statusMessage = "Export cancelled"
                    break
                }
                updateTransfer(progressID, message: "Exporting \(entry.name)…")
                let destination = destinationFolder.appendingPathComponent(Self.hostName(fromClassicHFSName: entry.name))
                switch await exportOneFile(entry, to: destination, progressID: progressID) {
                case .success:
                    exportedCount += 1
                case .failure(let error):
                    lastError = error
                }
            }
            statusMessage = "Exported \(exportedCount) of \(entries.count) items"
            if let lastError, exportedCount < entries.count {
                self.errorMessage = lastError.localizedDescription
            }
        }
    }

    /// Copies a single entry out to `destination`, dispatching to the right backend. Shared by
    /// both the single- and multi-file paths through `exportSelected`.
    private func exportOneFile(_ entry: FileEntry, to destination: URL, progressID: UUID? = nil) async -> Result<Void, Error> {
        if isMounted {
            do {
                try await copyEntryCancelable(from: entry.url, to: destination, progressID: progressID)
                return .success(())
            } catch is CancellationError {
                return .failure(CancellationError())
            } catch {
                return .failure(DiskImageError.exportFailed(entry.url, error))
            }
        }
        guard usingHFSUtils else {
            return .failure(NSError(domain: "hfsutils", code: 0, userInfo: [NSLocalizedDescriptionKey: "Export not supported for this backend"]))
        }
        do {
            try await exportHFSEntryRecursive(entry, to: destination, progressID: progressID)
            return .success(())
        } catch {
            return .failure(error)
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
        // hfsutils's point of view. The whole sequence is serialized against every other
        // hfsutils leaf operation (see `serializedHFSUtilsOperation`) since hfsutils tracks
        // "the current volume" as global state shared across processes.
        try await serializedHFSUtilsOperation { [self] in
            let (mountOut, mountErr, mountCode) = await runCommand([hmount, usePath])
            guard mountCode == 0 else {
                throw NSError(domain: "hfsutils", code: Int(mountCode), userInfo: [NSLocalizedDescriptionKey: "hmount failed: \(mountErr.isEmpty ? mountOut : mountErr)"])
            }
            let literalPath = Self.escapedHFSGlobPath(hfsPath)
            let (out, err, code) = await runHFSCommand([hcopy, literalPath, destination.path], hfsArgumentIndices: [1])
            _ = await runCommand([humount])
            guard code == 0, fileManager.fileExists(atPath: destination.path) else {
                throw NSError(domain: "hfsutils", code: Int(code), userInfo: [NSLocalizedDescriptionKey: "hcopy failed: \(err.isEmpty ? out : err)"])
            }
        }
    }

    /// Copies an hfsutils-backed entry — file or folder — out to a real location at
    /// `destination`. `hcopy` only ever transfers a single file, so a folder is walked one level
    /// at a time: create the matching host directory, list what's inside it on the HFS side (via
    /// the already-serialized `hfsList`), and recurse into each child, calling straight back to
    /// `exportHFSEntry` for the actual leaf files.
    private func exportHFSEntryRecursive(
        _ entry: FileEntry,
        to destination: URL,
        progressID: UUID? = nil
    ) async throws {
        try checkCancellation(progressID)
        if let progressID {
            updateTransfer(progressID, message: "Copying \(entry.name)…")
        }
        guard !entry.isDirectory else {
            guard let image = imageURL else {
                throw NSError(domain: "hfsutils", code: 0, userInfo: [NSLocalizedDescriptionKey: "hfsutils backend unavailable"])
            }
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            let children = try await hfsList(path: entry.hfsPath ?? pathForEntry(entry), imagePath: image.path)
            for child in children {
                try checkCancellation(progressID)
                try await exportHFSEntryRecursive(
                    child,
                    to: destination.appendingPathComponent(Self.hostName(fromClassicHFSName: child.name)),
                    progressID: progressID
                )
            }
            return
        }
        try await exportHFSEntry(entry, to: destination)
    }

    /// Moves a single entry from `sourceHFSPath` to `destHFSPath` within the same image, using
    /// `hrename` — hfsutils' native rename/move command, which (verified empirically) moves both
    /// files and whole non-empty directories in one step when source and target are in different
    /// directories, so unlike Export/Import there's no need to bounce through a host temp file or
    /// to recurse into a directory's contents by hand.
    private func moveHFSEntryWithinVolume(from sourceHFSPath: String, to destHFSPath: String, imagePath: String) async throws {
        guard let hrename = hrenamePath, let hmount = hmountPath else {
            throw NSError(domain: "hfsutils", code: 0, userInfo: [NSLocalizedDescriptionKey: "hfsutils backend unavailable"])
        }
        let humount = humountPath ?? hmount
        let usePath = imagePathToUse(original: imagePath)
        try await serializedHFSUtilsOperation { [self] in
            let (mountOut, mountErr, mountCode) = await runCommand([hmount, usePath])
            guard mountCode == 0 else {
                throw NSError(domain: "hfsutils", code: Int(mountCode), userInfo: [NSLocalizedDescriptionKey: "hmount failed: \(mountErr.isEmpty ? mountOut : mountErr)"])
            }
            let literalSource = Self.escapedHFSGlobPath(sourceHFSPath)
            let (out, err, code) = await runHFSCommand([hrename, literalSource, destHFSPath], hfsArgumentIndices: [1, 2])
            _ = await runCommand([humount])
            guard code == 0 else {
                throw NSError(domain: "hfsutils", code: Int(code), userInfo: [NSLocalizedDescriptionKey: "hrename failed: \(err.isEmpty ? out : err)"])
            }
        }
    }

    /// Builds the `NSItemProvider` SwiftUI's `.onDrag` hands to Finder (or any other drop
    /// target) for dragging `entry` out of the app. Mounted volumes already expose real files at
    /// `entry.url`, so those just wrap that URL directly. The hfsutils backend's entries are
    /// synthetic hfs://localhost/<image-path>?path=<hfs-path> pseudo-URLs with no bytes on the
    /// host filesystem, so there's nothing to hand over up front — instead this registers a file
    /// representation with an *async* load handler, and only does the actual hmount+hcopy+humount
    /// round trip (or, for a folder, a whole recursive tree of them via `materializeForPreview`)
    /// once the drop target actually asks for the data. This matters for two reasons: `.onDrag`'s
    /// own closure must still return immediately (an empty, not-yet-loaded provider is fine, and
    /// is what's returned here), and — unlike the naive synchronous version this replaced — it
    /// doesn't have to block the main thread for the whole hmount/hcopy round trip (which,
    /// multiplied across every file in a dragged folder, could otherwise stall the UI or run long
    /// enough for AppKit to give up on the drag session before the data was ready).
    func makeDragItemProvider(for entry: FileEntry) -> NSItemProvider {
        if isMounted {
            return NSItemProvider(object: entry.url as NSURL)
        }
        guard usingHFSUtils else { return NSItemProvider() }

        let typeIdentifier: String
        if entry.isDirectory {
            typeIdentifier = UTType.folder.identifier
        } else {
            let ext = (entry.name as NSString).pathExtension
            typeIdentifier = (!ext.isEmpty ? UTType(filenameExtension: ext)?.identifier : nil) ?? UTType.data.identifier
        }

        let provider = NSItemProvider()
        provider.suggestedName = entry.name
        provider.registerFileRepresentation(forTypeIdentifier: typeIdentifier, fileOptions: [], visibility: .all) { completion in
            Task { @MainActor [weak self] in
                guard let self else {
                    completion(nil, false, NSError(domain: "hfsutils", code: 0, userInfo: [NSLocalizedDescriptionKey: "Copy was cancelled"])); return
                }
                let progressID = self.beginTransfer(title: "Copying Files", message: "Preparing \(entry.name)…")
                defer { self.endTransfer(progressID) }
                guard let url = await self.materializeForPreview(entry, progressID: progressID) else {
                    completion(nil, false, NSError(domain: "hfsutils", code: 0, userInfo: [NSLocalizedDescriptionKey: "Could not read \(entry.name) from the image"]))
                    return
                }
                completion(url, false, nil)
            }
            return nil
        }
        return provider
    }

    private func makeTempExtractionDestination(for entry: FileEntry, prefix: String) -> URL? {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        guard (try? fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)) != nil else { return nil }
        return tempDir.appendingPathComponent(Self.hostName(fromClassicHFSName: entry.name))
    }

    /// Materializes a file or folder for previewing, opening in its default application, or
    /// dragging out (double-click / "Open" / Quick Look / drag-to-Finder) — reuses
    /// `exportHFSEntryRecursive` so a folder is copied out (with all its contents) just like an
    /// Export would. Shared by `openEntry`, `QuickLookController`, and the drag-out item
    /// provider in `makeDragItemProvider`.
    func materializeForPreview(_ entry: FileEntry, progressID: UUID? = nil) async -> URL? {
        if isMounted {
            return entry.url
        }
        guard usingHFSUtils,
              let destination = makeTempExtractionDestination(for: entry, prefix: "hfsapp-preview") else { return nil }
        do {
            try await exportHFSEntryRecursive(entry, to: destination, progressID: progressID)
            return destination
        } catch is CancellationError {
            try? fileManager.removeItem(at: destination)
            statusMessage = "Copy cancelled"
            return nil
        } catch {
            print("Failed to materialize \(entry.hfsPath ?? entry.name): \(error.localizedDescription)")
            if progressID != nil {
                errorMessage = "Could not copy \(entry.name): \(error.localizedDescription)"
            }
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
            let progressID = beginTransfer(title: "Adding Items", message: "Preparing import…")
            defer { endTransfer(progressID) }
            if isMounted {
                var renamedItemCount = 0
                for source in urls {
                    guard (try? checkCancellation(progressID)) != nil else {
                        statusMessage = "Import cancelled"
                        return
                    }
                    updateTransfer(progressID, message: "Adding \(source.lastPathComponent)…")
                    do {
                        renamedItemCount += try await importHostItemCancelable(source, parent: destination, progressID: progressID)
                    } catch is CancellationError {
                        statusMessage = "Import cancelled"
                        return
                    } catch {
                        self.errorMessage = DiskImageError.importFailed(source, error).localizedDescription
                        return
                    }
                }
                statusMessage = urls.count == 1 ? "Added \(urls[0].lastPathComponent)" : "Added \(urls.count) items"
                if renamedItemCount > 0 {
                    statusMessage += " (renamed \(renamedItemCount) for classic HFS compatibility)"
                }
                await refresh()
                return
            }

            // hfsutils backend: copy each file/folder into image at currentHFSPath
            guard usingHFSUtils, let image = imageURL else {
                self.errorMessage = "Import not supported for this backend"
                return
            }

            // Detach any hdiutil attachments to the image so hfsutils can lock it
            do { try await prepareForHFSUtils(imagePath: image.path) } catch {
                print("prepareForHFSUtils failed before import: \(error)")
            }

            let destPath = currentHFSPath ?? ":"
            var renamedItemCount = 0
            for source in urls {
                guard (try? checkCancellation(progressID)) != nil else {
                    statusMessage = "Import cancelled"
                    return
                }
                updateTransfer(progressID, message: "Adding \(source.lastPathComponent)…")
                var hostSource = source
                var tempDirToCleanUp: URL?
                do {
                    // `hcopy` only transfers HFS<->UNIX, not HFS-to-HFS directly (verified:
                    // passing two colon-style paths fails with "error opening source file"). So
                    // a source that's itself one of our synthetic hfs://...?path=... pseudo-URLs
                    // (i.e. the user copied an item from *inside* this same image, via the
                    // internal clipboard) has to be bounced through a temp host file/folder
                    // first — otherwise `source.path` here would resolve to the pseudo-URL's
                    // embedded *image* path, not the entry's real HFS path, and this would try
                    // to hcopy the entire disk image file into itself.
                    if let sourceHFSPath = Self.hfsPath(fromPseudoURL: source) {
                        let isDirectory = await hfsIsDirectory(path: sourceHFSPath, imagePath: image.path)
                        let sourceEntry = FileEntry(url: source, isDirectory: isDirectory, size: nil, hfsPath: sourceHFSPath)
                        guard let materialized = await materializeForPreview(sourceEntry, progressID: progressID) else {
                            throw NSError(domain: "hfsutils", code: 0, userInfo: [NSLocalizedDescriptionKey: "Could not read \(sourceEntry.name) from the image"])
                        }
                        hostSource = materialized
                        tempDirToCleanUp = materialized.deletingLastPathComponent()
                    }

                    renamedItemCount += try await importHostItemRecursive(
                        hostSource,
                        hfsDestParent: destPath,
                        imagePath: image.path,
                        progressID: progressID
                    )
                    if let tempDirToCleanUp {
                        try? fileManager.removeItem(at: tempDirToCleanUp)
                    }
                } catch {
                    if let tempDirToCleanUp {
                        try? fileManager.removeItem(at: tempDirToCleanUp)
                    }
                    if error is CancellationError {
                        statusMessage = "Import cancelled"
                        return
                    }
                    self.errorMessage = DiskImageError.importFailed(source, error).localizedDescription
                    return
                }
            }
            statusMessage = urls.count == 1 ? "Added \(urls[0].lastPathComponent)" : "Added \(urls.count) items"
            if renamedItemCount > 0 {
                statusMessage += " (renamed \(renamedItemCount) for classic HFS compatibility)"
            }
            await refresh()
        }
    }

    func createFolder(named proposedName: String) async {
        guard !isReadOnly else {
            errorMessage = "This image is read-only, so a folder can't be created."
            return
        }
        let trimmedName = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        let name = Self.classicHFSName(from: trimmedName)

        await withBusy {
            do {
                if isMounted, let parent = currentDirectory ?? mountPoint {
                    let destination = parent.appendingPathComponent(name, isDirectory: true)
                    try await Task.detached(priority: .userInitiated) {
                        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                    }.value
                } else if usingHFSUtils, let image = imageURL {
                    do { try await prepareForHFSUtils(imagePath: image.path) } catch {
                        print("prepareForHFSUtils failed before creating folder: \(error)")
                    }
                    let parent = currentHFSPath ?? ":"
                    let destination = parent.hasSuffix(":") ? "\(parent)\(name)" : "\(parent):\(name)"
                    try await hfsMkdir(path: destination, imagePath: image.path)
                } else {
                    throw NSError(domain: "FloppyFox", code: 0, userInfo: [NSLocalizedDescriptionKey: "Folder creation is not supported for this image."])
                }

                statusMessage = name == trimmedName
                    ? "Created \(name)"
                    : "Created \(name) (renamed for classic HFS compatibility)"
                await refresh()
            } catch {
                errorMessage = "Could not create \(name): \(error.localizedDescription)"
            }
        }
    }

    /// Moves each source in `urls` (from a Cut) into `destination`, keeping its original name.
    /// For a normally-mounted volume this is a plain, atomic `FileManager.moveItem` — no
    /// separate delete step, so there's nothing to race against. For the hfsutils backend,
    /// where no single `hmove`-style command exists, each item is moved within one dedicated
    /// mount session via `moveHFSEntryWithinVolume`, which only deletes the original after the
    /// copy to the new location has actually succeeded.
    func moveFiles(urls: [URL], destination: URL) async {
        guard !urls.isEmpty else { return }
        guard !isReadOnly else {
            self.errorMessage = "This image is read-only, so files can't be moved."
            return
        }
        await withBusy {
            let progressID = beginTransfer(title: "Moving Items", message: "Preparing move…")
            defer { endTransfer(progressID) }
            var movedCount = 0
            var lastError: Error?

            if isMounted {
                for source in urls {
                    guard (try? checkCancellation(progressID)) != nil else { break }
                    updateTransfer(progressID, message: "Moving \(source.lastPathComponent)…")
                    let targetURL = destination.appendingPathComponent(source.lastPathComponent)
                    do {
                        try await Task.detached(priority: .userInitiated) {
                            if FileManager.default.fileExists(atPath: targetURL.path) {
                                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError, userInfo: [NSLocalizedDescriptionKey: "Destination already exists."])
                            }
                            try FileManager.default.moveItem(at: source, to: targetURL)
                        }.value
                        movedCount += 1
                    } catch {
                        lastError = DiskImageError.importFailed(source, error)
                    }
                }
            } else if usingHFSUtils, let image = imageURL, hrenamePath != nil, hmountPath != nil {
                do { try await prepareForHFSUtils(imagePath: image.path) } catch {
                    print("prepareForHFSUtils failed before move: \(error)")
                }
                let destPath = currentHFSPath ?? ":"
                for source in urls {
                    guard (try? checkCancellation(progressID)) != nil else { break }
                    guard let sourceHFSPath = Self.hfsPath(fromPseudoURL: source) else {
                        lastError = NSError(domain: "hfsutils", code: 0, userInfo: [NSLocalizedDescriptionKey: "Can only move items that are already inside this image"])
                        continue
                    }
                    let name = FileEntry(url: source, isDirectory: false, size: nil, hfsPath: sourceHFSPath).name
                    updateTransfer(progressID, message: "Moving \(name)…")
                    let hfsDest = destPath.hasSuffix(":") ? "\(destPath)\(name)" : "\(destPath):\(name)"
                    guard hfsDest != sourceHFSPath else { continue }
                    do {
                        try await moveHFSEntryWithinVolume(from: sourceHFSPath, to: hfsDest, imagePath: image.path)
                        movedCount += 1
                    } catch {
                        lastError = error
                    }
                }
            } else {
                self.errorMessage = "Move not supported for this backend"
                return
            }

            statusMessage = movedCount == urls.count
                ? (movedCount == 1 ? "Moved 1 item" : "Moved \(movedCount) items")
                : "Moved \(movedCount) of \(urls.count) items"
            if let lastError {
                self.errorMessage = lastError.localizedDescription
            }
            await refresh()
        }
    }

    /// Copies `source` to `destination` a chunk at a time, checking `shouldCancel` between
    /// chunks — unlike `FileManager.copyItem`, which carries out a whole file (or, worse, a
    /// whole directory tree) as one uninterruptible blocking call. That was the reason Cancel
    /// had no effect on a transfer already under way: for a single file there's no next loop
    /// iteration to catch a cancellation flag, so the copy always ran to completion and
    /// reported success no matter what the user clicked. The partially written destination is
    /// removed whenever the copy doesn't finish — cancellation, yes, but also a genuine I/O
    /// failure partway through (a full destination volume, a source read error, ...):
    /// leaving a truncated file behind in that case would look like a real, if oddly-sized,
    /// file rather than the failed transfer it actually is.
    nonisolated static func copyFileChunked(
        from source: URL,
        to destination: URL,
        chunkSize: Int = 4 * 1024 * 1024,
        shouldCancel: @Sendable () async -> Bool
    ) async throws {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [NSLocalizedDescriptionKey: "Could not create \(destination.lastPathComponent)."])
        }
        do {
            let inHandle = try FileHandle(forReadingFrom: source)
            let outHandle = try FileHandle(forWritingTo: destination)
            defer {
                try? inHandle.close()
                try? outHandle.close()
            }
            while true {
                if await shouldCancel() {
                    throw CancellationError()
                }
                let chunk = try inHandle.read(upToCount: chunkSize) ?? Data()
                if chunk.isEmpty { break }
                try outHandle.write(contentsOf: chunk)
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// Copies a mounted-volume entry (file or folder) out to `destination`, checking for
    /// cancellation before every item and periodically during a large file's own copy — the
    /// export-side counterpart to `importHostItemCancelable` below. Directories are walked by
    /// hand instead of handed to `FileManager.copyItem` so each child gets its own
    /// cancellation check rather than the whole tree running as one blocking call.
    private func copyEntryCancelable(from source: URL, to destination: URL, progressID: UUID?) async throws {
        try checkCancellation(progressID)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError, userInfo: [NSLocalizedDescriptionKey: "Destination already exists."])
        }
        let isDirectory = (try? source.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        if isDirectory {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
            for child in try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey]) {
                try checkCancellation(progressID)
                try await copyEntryCancelable(from: child, to: destination.appendingPathComponent(child.lastPathComponent), progressID: progressID)
            }
            return
        }
        try await Task.detached(priority: .userInitiated) { [self] in
            try await Self.copyFileChunked(from: source, to: destination) {
                await self.isTransferCancelled(progressID)
            }
        }.value
    }

    /// Copies a host tree one component at a time so mounted HFS volumes receive the same
    /// validated names as the hfsutils backend instead of relying on filesystem-driver
    /// truncation or lossy Unicode conversion — and, like `copyEntryCancelable` above, checks
    /// for cancellation before every item and periodically during a large file's own copy.
    private func importHostItemCancelable(_ source: URL, parent: URL, progressID: UUID?) async throws -> Int {
        try checkCancellation(progressID)
        let safeName = Self.classicHFSName(from: source.lastPathComponent)
        let destination = parent.appendingPathComponent(safeName)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError, userInfo: [NSLocalizedDescriptionKey: "Destination already exists."])
        }

        let isDirectory = try source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        var renamedCount = safeName == source.lastPathComponent ? 0 : 1
        if isDirectory {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
            for child in try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey]) {
                renamedCount += try await importHostItemCancelable(child, parent: destination, progressID: progressID)
            }
        } else {
            try await Task.detached(priority: .userInitiated) { [self] in
                try await Self.copyFileChunked(from: source, to: destination) {
                    await self.isTransferCancelled(progressID)
                }
            }.value
        }
        return renamedCount
    }

    private func isTransferCancelled(_ id: UUID?) -> Bool {
        (try? checkCancellation(id)) == nil
    }

    /// Extracts the colon-separated HFS path from one of our synthetic
    /// hfs://localhost/<image-path>?path=<hfs-path> pseudo-URLs (see `copyEntry`), or nil if
    /// `url` isn't one of ours.
    private nonisolated static func hfsPath(fromPseudoURL url: URL) -> String? {
        guard url.scheme == "hfs",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let path = comps.queryItems?.first(where: { $0.name == "path" })?.value else {
            return nil
        }
        return path
    }

    // MARK: - hfsutils integration helpers

    /// Deletes a single hfsutils-backed entry — file or folder. `hdel` refuses directories
    /// outright (verified empirically: it fails with "is a directory"), and there's no
    /// recursive/batch delete command, so a folder is deleted bottom-up instead: everything
    /// inside it first (recursing into any subfolders via the already-serialized `hfsList`),
    /// then the now-empty folder itself via `hrmdir` (which, also verified empirically, only
    /// ever accepts an already-empty directory).
    private func deleteHFSEntryRecursive(_ entry: FileEntry, imagePath: String, progressID: UUID? = nil) async throws {
        try checkCancellation(progressID)
        if let progressID {
            updateTransfer(progressID, message: "Deleting \(entry.name)…")
        }
        let path = entry.hfsPath ?? pathForEntry(entry)
        guard entry.isDirectory else {
            try await deleteHFSFile(path: path, imagePath: imagePath)
            return
        }
        let children = try await hfsList(path: path, imagePath: imagePath)
        for child in children {
            try checkCancellation(progressID)
            try await deleteHFSEntryRecursive(child, imagePath: imagePath, progressID: progressID)
        }
        try await removeHFSDirectory(path: path, imagePath: imagePath)
    }

    private func deleteHFSFile(path: String, imagePath: String) async throws {
        guard let hdel = hdelPath, let hmount = hmountPath else {
            throw NSError(domain: "hfsutils", code: 0, userInfo: [NSLocalizedDescriptionKey: "hfsutils backend unavailable"])
        }
        let humount = humountPath ?? hmount
        let usePath = imagePathToUse(original: imagePath)
        // hmount, hdel, and humount run as separate calls so humount always runs even if hdel
        // fails — otherwise a failed delete would leave the volume locked from hfsutils's point
        // of view until something else happened to humount it.
        try await serializedHFSUtilsOperation { [self] in
            let (mountOut, mountErr, mountCode) = await runCommand([hmount, usePath])
            guard mountCode == 0 else {
                throw NSError(domain: "hfsutils", code: Int(mountCode), userInfo: [NSLocalizedDescriptionKey: "hmount failed: \(mountErr.isEmpty ? mountOut : mountErr)"])
            }
            let (out, err, code) = await runHFSCommand([hdel, Self.escapedHFSGlobPath(path)], hfsArgumentIndices: [1])
            _ = await runCommand([humount])
            guard code == 0 else {
                throw NSError(domain: "hfsutils", code: Int(code), userInfo: [NSLocalizedDescriptionKey: "hdel failed: \(err.isEmpty ? out : err)"])
            }
        }
    }

    private func removeHFSDirectory(path: String, imagePath: String) async throws {
        guard let hrmdir = hrmdirPath, let hmount = hmountPath else {
            throw NSError(domain: "hfsutils", code: 0, userInfo: [NSLocalizedDescriptionKey: "hfsutils backend unavailable"])
        }
        let humount = humountPath ?? hmount
        let usePath = imagePathToUse(original: imagePath)
        try await serializedHFSUtilsOperation { [self] in
            let (mountOut, mountErr, mountCode) = await runCommand([hmount, usePath])
            guard mountCode == 0 else {
                throw NSError(domain: "hfsutils", code: Int(mountCode), userInfo: [NSLocalizedDescriptionKey: "hmount failed: \(mountErr.isEmpty ? mountOut : mountErr)"])
            }
            let (out, err, code) = await runHFSCommand([hrmdir, Self.escapedHFSGlobPath(path)], hfsArgumentIndices: [1])
            _ = await runCommand([humount])
            guard code == 0 else {
                throw NSError(domain: "hfsutils", code: Int(code), userInfo: [NSLocalizedDescriptionKey: "hrmdir failed: \(err.isEmpty ? out : err)"])
            }
        }
    }

    /// Checks whether `path` is a directory on the HFS volume — needed because our synthetic
    /// hfs://...?path=... pseudo-URLs (see `hfsPath(fromPseudoURL:)`) don't carry an
    /// `isDirectory` flag the way a real `FileEntry` does, but callers that only have the raw
    /// URL (e.g. `importFiles`, working from the system pasteboard or internal clipboard) need
    /// to know before deciding how to materialize or import it.
    private func hfsIsDirectory(path: String, imagePath: String) async -> Bool {
        guard let hmount = hmountPath, let hls = hlsPath else { return false }
        let humount = humountPath ?? hmount
        let usePath = imagePathToUse(original: imagePath)
        return (try? await serializedHFSUtilsOperation { [self] () -> Bool in
            let (_, _, mountCode) = await runCommand([hmount, usePath])
            guard mountCode == 0 else { return false }
            let (dlOut, _, dlCode) = await runHFSCommand([hls, "-dl", Self.escapedHFSGlobPath(path)], hfsArgumentIndices: [2])
            _ = await runCommand([humount])
            return dlCode == 0 && dlOut.hasPrefix("d")
        }) ?? false
    }

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

        if compatible.isEmpty { compatible = "Untitled" }

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
    nonisolated static func hostName(fromClassicHFSName hfsName: String) -> String {
        hfsName.replacingOccurrences(of: "/", with: ":")
    }

    /// hfsutils expands shell-style metacharacters itself, even though Process passes each path
    /// as a separate argument. Escape them when an existing catalog path must be addressed
    /// literally (for example, SuperPaint ships files actually named `*Stars*`).
    nonisolated static func escapedHFSGlobPath(_ path: String) -> String {
        var result = ""
        for character in path {
            if character == "\\" || character == "*" || character == "?" || character == "[" {
                result.append("\\")
            }
            result.append(character)
        }
        return result
    }

    /// Recursively imports a real host file or folder into the image under `hfsDestParent`.
    /// Returns the number of path components renamed for classic HFS compatibility.
    private func importHostItemRecursive(
        _ source: URL,
        hfsDestParent: String,
        imagePath: String,
        progressID: UUID? = nil
    ) async throws -> Int {
        try checkCancellation(progressID)
        if let progressID {
            updateTransfer(progressID, message: "Adding \(source.lastPathComponent)…")
        }
        let isDirectory = (try? source.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        let name = Self.classicHFSName(from: source.lastPathComponent)
        var renamedCount = name == source.lastPathComponent ? 0 : 1
        let hfsDest = hfsDestParent.hasSuffix(":") ? "\(hfsDestParent)\(name)" : "\(hfsDestParent):\(name)"
        if isDirectory {
            try await hfsMkdir(path: hfsDest, imagePath: imagePath)
            let children = try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            for child in children {
                try checkCancellation(progressID)
                renamedCount += try await importHostItemRecursive(
                    child,
                    hfsDestParent: hfsDest,
                    imagePath: imagePath,
                    progressID: progressID
                )
            }
        } else {
            try await importHFSFile(from: source.path, to: hfsDest, imagePath: imagePath)
        }
        return renamedCount
    }

    private func hfsMkdir(path: String, imagePath: String) async throws {
        guard let hmkdir = hmkdirPath, let hmount = hmountPath else {
            throw NSError(domain: "hfsutils", code: 0, userInfo: [NSLocalizedDescriptionKey: "hfsutils backend unavailable"])
        }
        let humount = humountPath ?? hmount
        let usePath = imagePathToUse(original: imagePath)
        try await serializedHFSUtilsOperation { [self] in
            let (mountOut, mountErr, mountCode) = await runCommand([hmount, usePath])
            guard mountCode == 0 else {
                throw NSError(domain: "hfsutils", code: Int(mountCode), userInfo: [NSLocalizedDescriptionKey: "hmount failed: \(mountErr.isEmpty ? mountOut : mountErr)"])
            }
            let (out, err, code) = await runHFSCommand([hmkdir, path], hfsArgumentIndices: [1])
            _ = await runCommand([humount])
            guard code == 0 else {
                throw NSError(domain: "hfsutils", code: Int(code), userInfo: [NSLocalizedDescriptionKey: "hmkdir failed: \(err.isEmpty ? out : err)"])
            }
        }
    }

    private func importHFSFile(from hostPath: String, to hfsDest: String, imagePath: String) async throws {
        guard let hcopy = hcopyPath, let hmount = hmountPath else {
            throw NSError(domain: "hfsutils", code: 0, userInfo: [NSLocalizedDescriptionKey: "hfsutils backend unavailable"])
        }
        let humount = humountPath ?? hmount
        let usePath = imagePathToUse(original: imagePath)
        try await serializedHFSUtilsOperation { [self] in
            let (mountOut, mountErr, mountCode) = await runCommand([hmount, usePath])
            guard mountCode == 0 else {
                throw NSError(domain: "hfsutils", code: Int(mountCode), userInfo: [NSLocalizedDescriptionKey: "hmount failed: \(mountErr.isEmpty ? mountOut : mountErr)"])
            }
            let (out, err, code) = await runHFSCommand([hcopy, hostPath, hfsDest], hfsArgumentIndices: [2])
            _ = await runCommand([humount])
            guard code == 0 else {
                throw NSError(domain: "hfsutils", code: Int(code), userInfo: [NSLocalizedDescriptionKey: "hcopy failed: \(err.isEmpty ? out : err)"])
            }
        }
    }

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

        // The whole hmount+hls+humount sequence is serialized against every other hfsutils
        // leaf operation (see `serializedHFSUtilsOperation`) since hfsutils tracks "the current
        // volume" as global state (~/.hcwd) shared across every process invocation.
        return try await serializedHFSUtilsOperation { [self] in
            // Run hmount, hls, and humount as separate processes (rather than one shell
            // one-liner) so we only capture hls's own stdout. hmount persists the current
            // volume across process invocations via ~/.hcwd, and hmount's own banner text
            // ("Volume name is...") would otherwise get parsed as bogus file entries if
            // captured together with hls's output.
            let (mountOut, mountErr, mountCode) = await runCommand([hmount, usePath])
            guard mountCode == 0 else {
                throw NSError(domain: "hfsutils", code: Int(mountCode), userInfo: [NSLocalizedDescriptionKey: "hmount failed: \(mountErr.isEmpty ? mountOut : mountErr)"])
            }
            // Include invisible entries and escape control characters. Classic Mac folders
            // commonly contain an invisible custom-icon file literally named "Icon\r".
            // Verbatim output makes that carriage return look like a line ending, truncating
            // the name and aborting recursive folder exports.
            let (out, err, code) = await runHFSCommand([hls, "-a1Q", Self.escapedHFSGlobPath(query)], hfsArgumentIndices: [2])
            print("DEBUG hfsList: usePath=\(usePath) query=\(query) mountOut=\(mountOut) hlsOut=\(out) hlsErr=\(err) hlsCode=\(code)")
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
            let lines = out.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            for line in lines {
                guard let name = Self.decodeHLSQuotedName(line), !name.isEmpty else { continue }

                let hfsFullPath: String
                if query == ":" {
                    hfsFullPath = ":\(name)"
                } else if query.hasSuffix(":" ) {
                    hfsFullPath = "\(query)\(name)"
                } else {
                    hfsFullPath = "\(query):\(name)"
                }

                // Plain `hls` gives us no way to tell files from folders, so ask about this
                // specific entry individually (`-d` lists the entry itself instead of
                // descending into it, `-l` adds the leading 'd'/'f' type marker) while the
                // volume is still mounted. Passed as separate process arguments (no shell), so
                // spaces/quotes in the name can't cause any escaping issues here.
                let literalFullPath = Self.escapedHFSGlobPath(hfsFullPath)
                let (dlOut, _, dlCode) = await runHFSCommand([hls, "-dl", literalFullPath], hfsArgumentIndices: [2])
                let isDir = dlCode == 0 && dlOut.hasPrefix("d")

                // Long listings begin with, for example, `f  APPL/FNDR ...`. Resource forks
                // are expensive to materialize, so only inspect applications: that captures
                // the most useful classic icons without turning every directory refresh into
                // a full export of every document on the disk.
                let attributes = Self.finderAttributes(fromHLSLongListing: dlOut)
                let finderType = attributes?.type
                var resourceIconPNG: Data?
                if finderType == "APPL", let hcopy = hcopyPath {
                    let temporary = FileManager.default.temporaryDirectory
                        .appendingPathComponent("floppyfox-icon-\(UUID().uuidString).bin")
                    let (_, _, copyCode) = await runHFSCommand([hcopy, "-m", literalFullPath, temporary.path], hfsArgumentIndices: [2])
                    if copyCode == 0, let macBinary = try? Data(contentsOf: temporary) {
                        resourceIconPNG = ClassicMacResourceIcon.iconPNG(fromMacBinary: macBinary)
                    }
                    try? FileManager.default.removeItem(at: temporary)
                }

                let pseudo = URL(string: "hfs://localhost\(imagePath)?path=\(hfsFullPath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? hfsFullPath)")!
                let entry = FileEntry(
                    url: pseudo,
                    isDirectory: isDir,
                    size: attributes.map { $0.dataForkSize + $0.resourceForkSize },
                    hfsPath: hfsFullPath,
                    finderType: finderType,
                    finderCreator: attributes?.creator,
                    dataForkSize: attributes?.dataForkSize,
                    resourceForkSize: attributes?.resourceForkSize,
                    isInvisible: attributes?.isInvisible ?? false,
                    isLocked: attributes?.isLocked ?? false,
                    resourceIconPNG: resourceIconPNG
                )
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
    }

    nonisolated static func decodeHLSQuotedName(_ line: String) -> String? {
        guard line.first == "\"", line.last == "\"", line.count >= 2 else { return nil }
        let contents = line.dropFirst().dropLast()
        var result = ""
        var index = contents.startIndex
        while index < contents.endIndex {
            let character = contents[index]
            guard character == "\\" else {
                result.append(character)
                index = contents.index(after: index)
                continue
            }

            index = contents.index(after: index)
            guard index < contents.endIndex else { return nil }
            let escaped = contents[index]
            switch escaped {
            case "n": result.append("\n"); index = contents.index(after: index)
            case "b": result.append("\u{8}"); index = contents.index(after: index)
            case "r": result.append("\r"); index = contents.index(after: index)
            case "t": result.append("\t"); index = contents.index(after: index)
            case "f": result.append("\u{c}"); index = contents.index(after: index)
            case "\\", "\"", " ": result.append(escaped); index = contents.index(after: index)
            case "0"..."7":
                var digits = ""
                for _ in 0..<3 where index < contents.endIndex {
                    let digit = contents[index]
                    guard ("0"..."7").contains(digit) else { break }
                    digits.append(digit)
                    index = contents.index(after: index)
                }
                guard let byte = UInt8(digits, radix: 8),
                      let decoded = String(data: Data([byte]), encoding: .macOSRoman) else { return nil }
                result.append(decoded)
            default:
                result.append(escaped)
                index = contents.index(after: index)
            }
        }
        return result
    }

    nonisolated static func finderAttributes(fromHLSLongListing listing: String) -> (
        type: String,
        creator: String,
        dataForkSize: Int,
        resourceForkSize: Int,
        isInvisible: Bool,
        isLocked: Bool
    )? {
        // hfsutils formats files as `%c%c %4s/%4s data-size resource-size ...`.
        // Fixed-width type/creator codes may themselves contain spaces, so preserve them
        // verbatim instead of splitting the whole line on whitespace.
        let pattern = #"^([fF])([i ])\s(.{4})/(.{4})\s+(\d+)\s+(\d+)\s"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: listing, range: NSRange(listing.startIndex..., in: listing)),
              let kindRange = Range(match.range(at: 1), in: listing),
              let invisibleRange = Range(match.range(at: 2), in: listing),
              let typeRange = Range(match.range(at: 3), in: listing),
              let creatorRange = Range(match.range(at: 4), in: listing),
              let dataRange = Range(match.range(at: 5), in: listing),
              let resourceRange = Range(match.range(at: 6), in: listing),
              let dataSize = Int(listing[dataRange]),
              let resourceSize = Int(listing[resourceRange]) else { return nil }
        return (
            String(listing[typeRange]),
            String(listing[creatorRange]),
            dataSize,
            resourceSize,
            listing[invisibleRange] == "i",
            listing[kindRange] == "F"
        )
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
