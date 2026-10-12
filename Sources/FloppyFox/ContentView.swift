import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    private struct FolderPathItem: Identifiable {
        enum Destination {
            case mounted(URL)
            case hfs(String)
        }

        let label: String
        let destination: Destination
        var id: String {
            switch destination {
            case .mounted(let url): "mounted:\(url.path)"
            case .hfs(let path): "hfs:\(path)"
            }
        }
    }

    private enum BrowserViewStyle: String, CaseIterable, Identifiable {
        case list = "List"
        case grid = "Icons"

        var id: Self { self }
        var systemImage: String { self == .list ? "list.bullet" : "square.grid.2x2" }
    }

    @EnvironmentObject var manager: DiskImageManager
    @State private var isDropTarget = false
    @State private var isDropTargetForOpen = false
    @State private var deleteConfirmationEntries: Set<FileEntry> = []
    @State private var quickLook = QuickLookController()
    // Tracks the last plain (unmodified) click, as the starting point for Shift-click range
    // selection — matches Finder's click-to-extend-selection behavior.
    @State private var selectionAnchor: FileEntry?
    @State private var browserViewStyle: BrowserViewStyle = .list
    @State private var inspectorAttributesExpanded = true
    @State private var isNewFolderPromptPresented = false
    @State private var newFolderName = "untitled folder"

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor).opacity(0.98))
                        .shadow(color: .black.opacity(0.08), radius: 10, x: 0, y: 4)
                )
                .padding(.horizontal)
                .padding(.top)

            Divider()

            if manager.isMounted || manager.usingHFSUtils {
                mountedContent
            } else {
                placeholderView
            }
        }
        .frame(minWidth: 820, minHeight: 520)
        .background(appBackground)
        .overlay {
            if let title = manager.transferTitle, let message = manager.transferMessage {
                VStack(spacing: 12) {
                    Text(title)
                        .font(.headline)
                    ProgressView()
                        .progressViewStyle(.linear)
                        .frame(width: 280)
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: 300)
                    Button("Cancel", role: .cancel) {
                        manager.cancelActiveTransfer()
                    }
                    .keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.primary.opacity(0.12))
                }
                .shadow(color: .black.opacity(0.2), radius: 18, y: 8)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(.easeInOut(duration: 0.16), value: manager.transferMessage != nil)
        .alert("Error", isPresented: .constant(manager.errorMessage != nil), presenting: manager.errorMessage) { message in
            Button("OK", role: .cancel) {
                manager.errorMessage = nil
            }
        } message: { message in
            Text(message)
        }
        .alert("Opened Read-Only", isPresented: .constant(manager.warningMessage != nil), presenting: manager.warningMessage) { message in
            Button("OK", role: .cancel) {
                manager.warningMessage = nil
            }
        } message: { message in
            Text(message)
        }
        .alert("New Folder", isPresented: $isNewFolderPromptPresented) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") {
                let name = newFolderName
                Task { await manager.createFolder(named: name) }
            }
            .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a name for the new folder.")
        }
        .alert(
            "Delete \(deleteConfirmationEntries.count == 1 ? "item" : "items")?",
            isPresented: Binding(
                get: { !deleteConfirmationEntries.isEmpty },
                set: { if !$0 { deleteConfirmationEntries = [] } }
            )
        ) {
            Button(role: .destructive) {
                let entries = deleteConfirmationEntries
                deleteConfirmationEntries = []
                Task { await manager.deleteEntries(entries) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
            Button("Cancel", role: .cancel) {
                deleteConfirmationEntries = []
            }
        } message: {
            if deleteConfirmationEntries.count == 1, let name = deleteConfirmationEntries.first?.name {
                Text("Are you sure you want to delete \"") + Text(name).bold() + Text("\"? This action cannot be undone.")
            } else {
                Text("Are you sure you want to delete these \(deleteConfirmationEntries.count) items? This action cannot be undone.")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .didCreateDiagnosticsFile)) { note in
            if let url = note.object as? URL {
                NSWorkspace.shared.open(url)
            }
        }
        .onAppear {
            quickLook.attach(to: manager)
        }
        .onDisappear {
            quickLook.detach()
        }
        .onChange(of: manager.selectedEntry) { newValue in
            quickLook.selectionChanged(to: newValue)
        }
    }

    /// Uses AppKit's semantic window color as the base so the whole window follows the
    /// macOS appearance. The translucent tint keeps the visual warmth of the original
    /// design without turning into a bright rectangle in Dark Mode.
    private var appBackground: some View {
        Color(nsColor: .windowBackgroundColor)
            .overlay {
                LinearGradient(
                    colors: [
                        Color.accentColor.opacity(0.08),
                        Color.green.opacity(0.035)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            .ignoresSafeArea()
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                manager.openImage()
            } label: {
                Label("Open Image", systemImage: "externaldrive.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut("o", modifiers: [.command])

            // Copy/Paste buttons hidden per user preference

            Spacer()

            if manager.isBusy {
                ProgressView()
                    .controlSize(.small)
            }

            Button {
                Task { await manager.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(!manager.isMounted && !manager.usingHFSUtils)

            Button {
                Task { await manager.ejectImage() }
            } label: {
                Label("Eject", systemImage: "eject.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .tint(.orange)
            .disabled(!manager.isMounted && !manager.usingHFSUtils)
        }
    }

    private var mountedContent: some View {
        HSplitView {
            fileBrowser
                .frame(minWidth: 420, maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor).opacity(0.96))
                        .shadow(color: .black.opacity(0.13), radius: 16, x: 0, y: 7)
                        .shadow(color: Color.accentColor.opacity(0.07), radius: 4, x: 0, y: 1)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.primary.opacity(0.09), lineWidth: 1)
                }
                .padding(12)
                .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTarget) { providers in
                    guard !manager.isReadOnly else { return false }
                    return manager.handleDroppedFiles(providers: providers)
                }

            detailPane
                // HSplitView supplies the draggable divider. These bounds keep the inspector
                // useful while allowing the user to choose how much room it receives.
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 440)
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor).opacity(0.94))
                        .shadow(color: .black.opacity(0.09), radius: 12, x: 0, y: 5)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                }
                .padding(12)
        }
    }

    private var fileBrowser: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                ZStack {
                    Text(manager.imageURL?.lastPathComponent ?? manager.mountPoint?.lastPathComponent ?? "Mounted Volume")
                        .font(.title.bold())
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                    HStack {
                        Spacer()
                        if manager.isReadOnly {
                            Text("Read-Only")
                                .font(.caption.bold())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.orange.opacity(0.2)))
                                .foregroundColor(.orange)
                        }
                    }
                }
                if let directory = manager.currentDirectory {
                    Text(directory.path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
                } else if manager.usingHFSUtils, let hfsPath = manager.currentHFSPath {
                    Text(hfsPath)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)

            HStack {
                Button {
                    presentNewFolderPrompt()
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.bordered)
                .tint(.accentColor)
                .disabled(manager.isReadOnly)

                Button {
                    Task { await manager.goUp() }
                } label: {
                    Label("Up", systemImage: "arrow.up")
                }
                .buttonStyle(.bordered)
                .disabled(!manager.canGoBack)

                Menu {
                    ForEach(folderPathItems) { item in
                        Button {
                            navigate(to: item.destination)
                        } label: {
                            Label(item.label, systemImage: "folder")
                        }
                    }
                } label: {
                    Label(currentFolderName, systemImage: "folder")
                }
                .menuStyle(.button)
                .help("Go to a folder in the current path")

                Spacer()

                Picker("View as", selection: $browserViewStyle) {
                    ForEach(BrowserViewStyle.allCases) { style in
                        Label(style.rawValue, systemImage: style.systemImage)
                            .tag(style)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()

            }
            .padding(.horizontal)
            .padding(.bottom, 8)

            if browserViewStyle == .list {
                listView
            } else {
                iconView
            }
        }
    }

    private var listView: some View {
        List(selection: $manager.selectedEntries) {
            ForEach(manager.entries) { entry in
                row(for: entry)
                    .tag(entry)
                    .contextMenu { entryContextMenu(for: entry) }
            }
        }
        .listStyle(.inset)
        .contextMenu { browserContextMenu }
    }

    private var iconView: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 14)], spacing: 18) {
                ForEach(manager.entries) { entry in
                    VStack(spacing: 6) {
                        if let icon = entry.icon {
                            Image(nsImage: icon)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 48, height: 48)
                        }
                        Text(entry.name)
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .frame(maxWidth: 88)
                    }
                    .frame(maxWidth: .infinity, minHeight: 76)
                    .padding(6)
                    .background {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(manager.selectedEntries.contains(entry) ? Color.accentColor.opacity(0.2) : .clear)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(manager.selectedEntries.contains(entry) ? Color.accentColor.opacity(0.7) : .clear)
                    }
                    .contentShape(Rectangle())
                    .simultaneousGesture(TapGesture(count: 1).onEnded {
                        handleSingleClick(on: entry)
                    })
                    .simultaneousGesture(TapGesture(count: 2).onEnded {
                        Task { await manager.openEntry(entry) }
                    })
                    .onDrag { manager.makeDragItemProvider(for: entry) }
                    .contextMenu { entryContextMenu(for: entry) }
                }
            }
            .padding(16)
        }
        .contextMenu { browserContextMenu }
    }

    @ViewBuilder
    private var browserContextMenu: some View {
        Button("New Folder") {
            presentNewFolderPrompt()
        }
        .disabled(manager.isReadOnly)
        Divider()
        Button("Cut") {
            manager.cutSelected()
        }
        .disabled(manager.selectedEntries.isEmpty || manager.isReadOnly)
        Button("Copy") {
            manager.copySelected()
        }
        .disabled(manager.selectedEntries.isEmpty)
        Button("Paste") {
            manager.paste()
        }
        .disabled(manager.isReadOnly)
    }

    @ViewBuilder
    private func entryContextMenu(for entry: FileEntry) -> some View {
        let isPartOfSelection = manager.selectedEntries.count > 1 && manager.selectedEntries.contains(entry)
        Button("Open") {
            Task { await manager.openEntry(entry) }
        }
        Divider()
        Button(isPartOfSelection ? "Cut \(manager.selectedEntries.count) Items" : "Cut") {
            if isPartOfSelection {
                manager.cutSelected()
            } else {
                manager.cutEntry(entry)
            }
        }
        .disabled(manager.isReadOnly)
        Button(isPartOfSelection ? "Copy \(manager.selectedEntries.count) Items" : "Copy") {
            if isPartOfSelection {
                manager.copySelected()
            } else {
                manager.copyEntry(entry)
            }
        }
        Button("Paste") {
            manager.paste()
        }
        .disabled(manager.isReadOnly)
        Divider()
        Button("New Folder") {
            presentNewFolderPrompt()
        }
        .disabled(manager.isReadOnly)
        Button(role: .destructive) {
            deleteConfirmationEntries = isPartOfSelection ? manager.selectedEntries : [entry]
        } label: {
            Label(isPartOfSelection ? "Delete \(manager.selectedEntries.count) Items" : "Delete", systemImage: "trash")
        }
        .disabled(entry.url == manager.currentDirectory || manager.isReadOnly)
    }

    private func row(for entry: FileEntry) -> some View {
        HStack(spacing: 10) {
            if let icon = entry.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 18, height: 18)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.body)
                if !entry.isDirectory {
                    Text(entry.sizeText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
        }
        .contentShape(Rectangle())
        // `.simultaneousGesture` (rather than `.onTapGesture`/`.gesture`) so these don't
        // consume the click List needs for its own handling — attaching a plain tap gesture
        // here made selection unreliable. The explicit single-tap handler below is needed
        // because `.onDrag` on a macOS List row intercepts the mouse-down before List's own
        // click-to-select logic sees it, so without this, clicking a row (with drag enabled)
        // silently fails to highlight/select it. Since we're overriding List's own click
        // handling anyway, Cmd/Shift-click multi-select has to be reimplemented here too.
        .simultaneousGesture(TapGesture(count: 1).onEnded {
            handleSingleClick(on: entry)
        })
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            Task { await manager.openEntry(entry) }
        })
        .onDrag {
            manager.makeDragItemProvider(for: entry)
        }
    }

    /// Cmd-click toggles the entry in/out of the selection; Shift-click extends a contiguous
    /// range from the last plain click; a plain click replaces the selection with just this
    /// entry — the same three behaviors Finder's list view supports.
    private func handleSingleClick(on entry: FileEntry) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if manager.selectedEntries.contains(entry) {
                manager.selectedEntries.remove(entry)
            } else {
                manager.selectedEntries.insert(entry)
            }
            selectionAnchor = entry
        } else if flags.contains(.shift), let anchor = selectionAnchor,
                  let anchorIndex = manager.entries.firstIndex(of: anchor),
                  let targetIndex = manager.entries.firstIndex(of: entry) {
            let range = anchorIndex < targetIndex ? anchorIndex...targetIndex : targetIndex...anchorIndex
            manager.selectedEntries = Set(manager.entries[range])
        } else {
            manager.selectedEntries = [entry]
            selectionAnchor = entry
        }
    }

    private var detailPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(manager.selectedEntries.count > 1 ? "Selected items" : "Selected item")
                .font(.title3.bold())
                .padding(.top)

            if manager.selectedEntries.count > 1 {
                let entries = manager.selectedEntries
                Text("\(entries.count) items selected")
                    .font(.headline)
                let totalSize = entries.compactMap { $0.size }.reduce(0, +)
                inspectorRow("Total size", value: ByteCountFormatter.string(fromByteCount: Int64(totalSize), countStyle: .file))
                Spacer()
                Button {
                    deleteConfirmationEntries = entries
                } label: {
                    Label("Delete Selected", systemImage: "trash")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(manager.isReadOnly)
            } else if let entry = manager.selectedEntry {
                Text(entry.name)
                    .font(.headline)
                Text(entry.url.path)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(3)
                Text(entry.isDirectory ? "Folder" : "File")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                if !entry.isDirectory {
                    Divider()
                    DisclosureGroup("Attributes", isExpanded: $inspectorAttributesExpanded) {
                        VStack(spacing: 8) {
                            if let size = entry.size {
                                inspectorRow("Size", value: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                            }
                            if let dataSize = entry.dataForkSize {
                                inspectorRow("Data fork", value: ByteCountFormatter.string(fromByteCount: Int64(dataSize), countStyle: .file))
                            }
                            if let resourceSize = entry.resourceForkSize {
                                inspectorRow("Resource fork", value: ByteCountFormatter.string(fromByteCount: Int64(resourceSize), countStyle: .file))
                            }
                            if let type = entry.finderType {
                                inspectorRow("Type", value: type)
                            }
                            if let creator = entry.finderCreator {
                                inspectorRow("Creator", value: creator)
                            }
                            inspectorRow("Locked", value: entry.isLocked ? "Yes" : "No")
                            inspectorRow("Invisible", value: entry.isInvisible ? "Yes" : "No")
                        }
                        .padding(.top, 8)
                    }
                    .font(.headline)
                }
                Spacer()
                Button {
                    deleteConfirmationEntries = [entry]
                } label: {
                    Label("Delete This Item", systemImage: "trash")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(manager.isReadOnly)
            } else {
                Text("Select a file or folder to see details.")
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func inspectorRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: 150, alignment: .trailing)
        }
        .font(.subheadline)
    }

    private var currentFolderName: String {
        if let currentDirectory = manager.currentDirectory {
            return currentDirectory.lastPathComponent
        }
        guard let path = manager.currentHFSPath, path != ":" else {
            return manager.imageURL?.deletingPathExtension().lastPathComponent ?? "Volume"
        }
        return path.split(separator: ":").last.map(String.init) ?? "Volume"
    }

    private var folderPathItems: [FolderPathItem] {
        if let current = manager.currentDirectory, let root = manager.mountPoint {
            var items: [FolderPathItem] = []
            var cursor = current
            while cursor.path.hasPrefix(root.path) {
                let label = cursor == root ? root.lastPathComponent : cursor.lastPathComponent
                items.append(FolderPathItem(label: label, destination: .mounted(cursor)))
                if cursor == root { break }
                let parent = cursor.deletingLastPathComponent()
                guard parent != cursor else { break }
                cursor = parent
            }
            return items
        }

        guard manager.usingHFSUtils else { return [] }
        let volumeName = manager.imageURL?.deletingPathExtension().lastPathComponent ?? "Volume"
        let components = (manager.currentHFSPath ?? ":").split(separator: ":").map(String.init)
        var items: [FolderPathItem] = []
        for count in stride(from: components.count, through: 1, by: -1) {
            let path = ":" + components.prefix(count).joined(separator: ":")
            items.append(FolderPathItem(label: components[count - 1], destination: .hfs(path)))
        }
        items.append(FolderPathItem(label: volumeName, destination: .hfs(":")))
        return items
    }

    private func navigate(to destination: FolderPathItem.Destination) {
        switch destination {
        case .mounted(let url):
            Task { await manager.navigate(toMountedDirectory: url) }
        case .hfs(let path):
            Task { await manager.navigate(toHFSDirectory: path) }
        }
    }

    private func presentNewFolderPrompt() {
        newFolderName = "untitled folder"
        isNewFolderPromptPresented = true
    }

    private var placeholderView: some View {
        VStack(spacing: 16) {
            classicMacGraphic
            Text("Open an HFS disk image")
                .font(.title)
                .bold()
            Text(isDropTargetForOpen ? "Drop to open" : "Choose a .dsk, .img, .hda, or .vhd image containing Apple HFS, then browse and manage its contents.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .frame(maxWidth: 520)
            Button("Open Image") {
                manager.openImage()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isDropTargetForOpen ? Color.accentColor.opacity(0.1) : Color.clear)
                .padding(20)
        )
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargetForOpen) { providers in
            manager.handleDroppedImageToOpen(providers: providers)
        }
    }

    private var classicMacGraphic: some View {
        HStack(alignment: .bottom, spacing: -12) {
            classicMacIcon(named: "Floppy", size: 76, rotation: -8)
                .offset(y: 8)
            classicMacIcon(named: "ClassicMac", size: 128)
                .zIndex(1)
            classicMacIcon(named: "HappyMac", size: 76, rotation: 8)
                .offset(y: 8)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background {
            Capsule(style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.72))
                .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
        }
        .accessibilityHidden(true)
    }

    private func classicMacIcon(named name: String, size: CGFloat, rotation: Double = 0) -> some View {
        Image(name, bundle: .floppyFoxResources)
            .interpolation(.high)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .rotationEffect(.degrees(rotation))
    }
}

private extension FileEntry {
    var sizeText: String {
        guard let size else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}
