import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    private struct FolderPathItem: Identifiable {
        let label: String
        let folderID: UInt32
        var id: UInt32 { folderID }
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

    /// Space between the window edge and the cards, and between the two cards.
    private let margin: CGFloat = 20

    var body: some View {
        Group {
            if manager.isOpen {
                mountedContent
            } else {
                placeholderView
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .background(appBackground)
        .navigationTitle(manager.isOpen ? (manager.volumeName ?? "FloppyFox") : "FloppyFox")
        .navigationSubtitle(manager.isOpen ? (manager.imageURL?.lastPathComponent ?? "") : "")
        .toolbar { toolbarContent }
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
            if manager.canOpenForWritingAnyway {
                Button("Open for Writing Anyway") {
                    manager.warningMessage = nil
                    Task { await manager.reopenAllowingWrites() }
                }
            }
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

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                manager.openImage()
            } label: {
                Label("Open Image", systemImage: "externaldrive.badge.plus")
            }
            .help("Open a disk image (⌘O)")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if manager.isBusy {
                ProgressView()
                    .controlSize(.small)
            }

            Button {
                Task { await manager.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Reread the disk image")
            .disabled(!manager.isOpen)

            Button {
                Task { await manager.ejectImage() }
            } label: {
                Label("Eject", systemImage: "eject")
            }
            .help("Close the disk image")
            .disabled(!manager.isOpen)
        }
    }

    private var mountedContent: some View {
        HSplitView {
            fileBrowser
                .card(fill: Color(nsColor: .textBackgroundColor))
                .padding([.leading, .vertical], margin)
                .padding(.trailing, margin / 2)
                .frame(minWidth: 460, maxWidth: .infinity)
                .layoutPriority(1)
                .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTarget) { providers in
                    guard !manager.isReadOnly else { return false }
                    return manager.handleDroppedFiles(providers: providers)
                }

            detailPane
                .card(fill: Color(nsColor: .controlBackgroundColor))
                .padding([.trailing, .vertical], margin)
                .padding(.leading, margin / 2)
                // HSplitView supplies the draggable divider. These bounds keep the inspector
                // useful while leaving most of the window to the file list.
                .frame(minWidth: 280, idealWidth: 300, maxWidth: 380)
        }
    }

    private var fileBrowser: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "externaldrive")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(manager.volumeName ?? manager.imageURL?.lastPathComponent ?? "Volume")
                            .font(.title2.weight(.semibold))
                            .lineLimit(1)
                        if manager.isReadOnly {
                            Text("Read-Only")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.orange.opacity(0.18)))
                                .foregroundColor(.orange)
                        }
                    }
                    HStack(spacing: 6) {
                        Text(currentHFSPath)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.head)
                        if let free = manager.freeSpaceDescription {
                            Text("·")
                            Text(free)
                                .font(.caption)
                                .fixedSize()
                        }
                    }
                    .foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 16)

            HStack(spacing: 8) {
                Button {
                    Task { await manager.goUp() }
                } label: {
                    Image(systemName: "chevron.up")
                        .frame(width: 14)
                }
                .help("Enclosing folder")
                .accessibilityLabel("Up")
                .disabled(!manager.canGoBack)

                Menu {
                    ForEach(folderPathItems) { item in
                        Button {
                            Task { await manager.navigate(toFolder: item.folderID) }
                        } label: {
                            Label(item.label, systemImage: "folder")
                        }
                    }
                } label: {
                    Label(currentFolderName, systemImage: "folder")
                }
                .menuStyle(.button)
                .fixedSize()
                .help("Go to a folder in the current path")

                Spacer(minLength: 12)

                Button {
                    presentNewFolderPrompt()
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                .fixedSize()
                .disabled(manager.isReadOnly)

                Picker("View as", selection: $browserViewStyle) {
                    ForEach(BrowserViewStyle.allCases) { style in
                        Image(systemName: style.systemImage)
                            .accessibilityLabel(style.rawValue)
                            .tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("View as list or icons")
            }
            .controlSize(.regular)
            .padding(.horizontal, 20)
            .padding(.bottom, 14)

            Divider()

            Group {
                if browserViewStyle == .list {
                    listView
                } else {
                    iconView
                }
            }
            .overlay {
                if manager.entries.isEmpty {
                    Text("This folder is empty")
                        .foregroundColor(.secondary)
                }
            }
        }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .allowsHitTesting(false)
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
        .scrollContentBackground(.hidden)
        .contextMenu { browserContextMenu }
    }

    private var iconView: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 16)], spacing: 20) {
                ForEach(manager.entries) { entry in
                    VStack(spacing: 6) {
                        if let icon = entry.icon {
                            Image(nsImage: icon)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 48, height: 48)
                                .accessibilityHidden(true) // the name says what it is
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
            .padding(20)
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
        .disabled(manager.isReadOnly)
    }

    private func row(for entry: FileEntry) -> some View {
        HStack(spacing: 12) {
            if let icon = entry.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true) // the name says what it is
            }
            Text(entry.name)
                .font(.body)
                .lineLimit(1)
            Spacer(minLength: 12)
            Text(entry.isDirectory ? "Folder" : entry.sizeText)
                .font(.callout)
                .foregroundColor(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
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
        VStack(alignment: .leading, spacing: 14) {
            if manager.selectedEntries.count > 1 {
                let entries = manager.selectedEntries
                inspectorHeader(icon: Image(systemName: "doc.on.doc"),
                                title: "\(entries.count) items selected",
                                subtitle: nil)
                Divider()
                let totalSize = entries.compactMap { $0.size }.reduce(0, +)
                inspectorRow("Total size", value: ByteCountFormatter.string(fromByteCount: Int64(totalSize), countStyle: .file))
                Spacer()
                Button(role: .destructive) {
                    deleteConfirmationEntries = entries
                } label: {
                    Label("Delete Selected", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(manager.isReadOnly)
            } else if let entry = manager.selectedEntry {
                inspectorHeader(icon: entry.icon.map { Image(nsImage: $0) } ?? Image(systemName: "doc"),
                                title: entry.name,
                                subtitle: entry.isDirectory ? "Folder" : entry.sizeText)
                Text(hfsPath(of: entry))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
                if !entry.isDirectory {
                    Divider()
                    DisclosureGroup("Attributes", isExpanded: $inspectorAttributesExpanded) {
                        VStack(spacing: 10) {
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
                            inspectorRow("Created", value: entry.item.createDate.formatted(date: .abbreviated, time: .shortened))
                            inspectorRow("Modified", value: entry.item.modifyDate.formatted(date: .abbreviated, time: .shortened))
                        }
                        .padding(.top, 10)
                    }
                    .font(.headline)
                }
                Spacer()
                Button(role: .destructive) {
                    deleteConfirmationEntries = [entry]
                } label: {
                    Label("Delete", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(manager.isReadOnly)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    Text("No Selection")
                        .font(.headline)
                    Text("Select a file or folder to see its details.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func inspectorHeader(icon: Image, title: String, subtitle: String?) -> some View {
        HStack(spacing: 14) {
            icon
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: 48, height: 48)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .lineLimit(2)
                    .textSelection(.enabled)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
        }
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
        manager.folderPath.last?.name ?? manager.volumeName ?? "Volume"
    }

    /// The classic colon-separated path, e.g. `Macintosh HD:System Folder:Extensions`.
    private var currentHFSPath: String {
        ([manager.volumeName ?? "Volume"] + manager.folderPath.map(\.name)).joined(separator: ":")
    }

    private func hfsPath(of entry: FileEntry) -> String {
        currentHFSPath + ":" + entry.name
    }

    private var folderPathItems: [FolderPathItem] {
        var items = manager.folderPath.reversed().map { FolderPathItem(label: $0.name, folderID: $0.id) }
        items.append(FolderPathItem(label: manager.volumeName ?? "Volume", folderID: HFSCatalogID.rootFolder))
        return items
    }

    private func presentNewFolderPrompt() {
        newFolderName = "untitled folder"
        isNewFolderPromptPresented = true
    }

    private var placeholderView: some View {
        VStack(spacing: 0) {
            classicMacGraphic
                .padding(.bottom, 28)
            Text(isDropTargetForOpen ? "Drop to Open" : "Open an HFS Disk Image")
                .font(.title.weight(.semibold))
                .padding(.bottom, 10)
            Text("Drag a disk image here, or choose one to browse and edit its files.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .frame(maxWidth: 420)
                .padding(.bottom, 24)
            Button {
                manager.openImage()
            } label: {
                Text("Open Image…")
                    .padding(.horizontal, 12)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.bottom, 16)
            Text(".dsk  ·  .img  ·  .image  ·  .dc42  ·  .hda  ·  .vhd")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(isDropTargetForOpen ? Color.accentColor.opacity(0.08) : Color.clear)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(isDropTargetForOpen ? Color.accentColor : Color.secondary.opacity(0.28),
                              style: StrokeStyle(lineWidth: isDropTargetForOpen ? 2 : 1.5, dash: [7, 6]))
        }
        .padding(margin)
        .animation(.easeInOut(duration: 0.15), value: isDropTargetForOpen)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargetForOpen) { providers in
            manager.handleDroppedImageToOpen(providers: providers)
        }
    }

    private var classicMacGraphic: some View {
        HStack(alignment: .bottom, spacing: -14) {
            classicMacIcon(named: "Floppy", size: 84, rotation: -8)
                .offset(y: -4)
            classicMacIcon(named: "ClassicMac", size: 136)
                .zIndex(1)
            classicMacIcon(named: "HappyMac", size: 84, rotation: 8)
                .offset(y: -4)
        }
        .padding(28)
        .background {
            Circle()
                .fill(Color.accentColor.opacity(0.08))
                .frame(width: 230, height: 230)
        }
        .accessibilityHidden(true)
    }

    /// The icons are loose PNGs in the resource bundle; `Image(_:bundle:)` only searches asset
    /// catalogs and would draw nothing.
    private func classicMacIcon(named name: String, size: CGFloat, rotation: Double = 0) -> some View {
        Image(nsImage: Bundle.floppyFoxResources.image(forResource: name) ?? NSImage())
            .interpolation(.high)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
            .rotationEffect(.degrees(rotation))
    }
}

private extension View {
    /// A rounded panel with a hairline border and a soft shadow; content is clipped to it.
    func card(fill: Color) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return self
            .background(fill)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
            .compositingGroup()
            .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
    }
}

private extension FileEntry {
    var sizeText: String {
        guard let size else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}
