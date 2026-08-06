import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var manager: DiskImageManager
    @State private var isDropTarget = false
    @State private var isDropTargetForOpen = false
    @State private var deleteConfirmationEntries: Set<FileEntry> = []
    @State private var quickLook = QuickLookController()
    // Tracks the last plain (unmodified) click, as the starting point for Shift-click range
    // selection — matches Finder's click-to-extend-selection behavior.
    @State private var selectionAnchor: FileEntry?

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
        .alert(
            "Delete \(deleteConfirmationEntries.count == 1 ? "item" : "items")?",
            isPresented: Binding(
                get: { !deleteConfirmationEntries.isEmpty },
                set: { if !$0 { deleteConfirmationEntries = [] } }
            )
        ) {
            Button("Delete", role: .destructive) {
                let entries = deleteConfirmationEntries
                deleteConfirmationEntries = []
                Task { await manager.deleteEntries(entries) }
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
            Button("Open Image") {
                manager.openImage()
            }
            .keyboardShortcut("o", modifiers: [.command])

            Button("Add Files") {
                manager.addFiles()
            }
            .disabled((!manager.isMounted && !manager.usingHFSUtils) || manager.isReadOnly)

            // Copy/Paste buttons hidden per user preference

            Button("Export") {
                Task { await manager.exportSelected() }
            }
            .disabled(manager.selectedEntries.isEmpty)

            Button("Quick Look") {
                quickLook.toggle(for: manager.selectedEntry)
            }
            .disabled(manager.selectedEntry == nil || manager.selectedEntry?.isDirectory == true)

            Spacer()

            if manager.isBusy {
                ProgressView()
                    .controlSize(.small)
            }

            Button("Refresh") {
                Task { await manager.refresh() }
            }
            .disabled(!manager.isMounted && !manager.usingHFSUtils)

            Toggle("Confirm detach", isOn: $manager.confirmBeforeDetach)
                .toggleStyle(.switch)
                .frame(width: 200)

            Button("Eject") {
                Task { await manager.ejectImage() }
            }
            .disabled(!manager.isMounted && !manager.usingHFSUtils)
        }
    }

    private var mountedContent: some View {
        HStack(spacing: 0) {
            fileBrowser
                .frame(minWidth: 340)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor).opacity(0.96))
                        .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 4)
                )
                .padding(12)
                .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTarget) { providers in
                    guard !manager.isReadOnly else { return false }
                    return manager.handleDroppedFiles(providers: providers)
                }

            Divider()

            detailPane
                .frame(minWidth: 280)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor).opacity(0.94))
                        .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 4)
                )
                .padding(12)
        }
    }

    private var fileBrowser: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(manager.mountPoint?.lastPathComponent ?? manager.imageURL?.lastPathComponent ?? "Mounted Volume")
                        .font(.title2.bold())
                    if manager.isReadOnly {
                        Text("Read-Only")
                            .font(.caption.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.orange.opacity(0.2)))
                            .foregroundColor(.orange)
                    }
                }
                Text(manager.statusMessage)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                if let directory = manager.currentDirectory {
                    Text(directory.path)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                } else if manager.usingHFSUtils, let hfsPath = manager.currentHFSPath {
                    Text(hfsPath)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .padding([.horizontal, .top])

            HStack {
                Button("Up") {
                    Task { await manager.goUp() }
                }
                .disabled(!manager.canGoBack)

                Spacer()

                Text(manager.isReadOnly ? "This image is read-only" : (isDropTarget ? "Drop files here to add them to the volume" : "Drag files here from Finder to copy floppy treasures into the mounted volume"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)

            List(selection: $manager.selectedEntries) {
                ForEach(manager.entries) { entry in
                    // If the right-clicked row is part of a larger multi-selection, Copy/Delete
                    // act on the whole selection (matching Finder); otherwise just this row.
                    let isPartOfSelection = manager.selectedEntries.count > 1 && manager.selectedEntries.contains(entry)

                    row(for: entry)
                        .tag(entry)
                        .contextMenu {
                            Button("Open") {
                                Task { await manager.openEntry(entry) }
                            }

                            Button(isPartOfSelection ? "Copy \(manager.selectedEntries.count) Items" : "Copy") {
                                if isPartOfSelection {
                                    manager.copySelected()
                                } else {
                                    manager.copyEntry(entry)
                                }
                            }

                            Button(isPartOfSelection ? "Delete \(manager.selectedEntries.count) Items" : "Delete", role: .destructive) {
                                deleteConfirmationEntries = isPartOfSelection ? manager.selectedEntries : [entry]
                            }
                            .disabled(entry.url == manager.currentDirectory || manager.isReadOnly)
                        }
                }
            }
            .listStyle(.inset)
        }
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
                if totalSize > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(totalSize), countStyle: .file))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Delete Selected") {
                    deleteConfirmationEntries = entries
                }
                .buttonStyle(.borderedProminent)
                .foregroundColor(.red)
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
                if let size = entry.size, !entry.isDirectory {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                        .font(.subheadline)
                }
                Spacer()
                Button("Delete This Item") {
                    deleteConfirmationEntries = [entry]
                }
                .buttonStyle(.borderedProminent)
                .foregroundColor(.red)
                .disabled(manager.isReadOnly)
            } else {
                Text("Select a file or folder to see details.")
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
        .padding()
    }

    private var placeholderView: some View {
        VStack(spacing: 16) {
            classicMacGraphic
            Text("Open an HFS disk image")
                .font(.title)
                .bold()
            Text(isDropTargetForOpen ? "Drop to open" : "Choose a .dsk, .img, or .hda image file formatted with Apple HFS, then browse and manage its contents.")
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
        Image(name, bundle: .module)
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
