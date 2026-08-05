import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var manager = DiskImageManager()
    @State private var isDropTarget = false
    @State private var isDropTargetForOpen = false

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
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.96, green: 0.94, blue: 1.0),
                    Color(red: 0.98, green: 1.0, blue: 0.97)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
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
        .onReceive(NotificationCenter.default.publisher(for: .didCreateDiagnosticsFile)) { note in
            if let url = note.object as? URL {
                NSWorkspace.shared.open(url)
            }
        }
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

            Button("Copy") {
                manager.copySelected()
            }
            .disabled(manager.selectedEntry == nil)

            Button("Paste") {
                manager.paste()
            }
            .disabled((!manager.isMounted && !manager.usingHFSUtils) || manager.isReadOnly)

            Button("Export") {
                Task { await manager.exportSelected() }
            }
            .disabled(manager.selectedEntry == nil)

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

            Button("Diagnostics") {
                // Run diagnostics on current image if loaded, otherwise let user choose
                if let image = manager.imageURL {
                    Task { _ = await manager.runDiagnostics(on: image) }
                } else {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [UTType(filenameExtension: "dsk"), UTType(filenameExtension: "img")].compactMap { $0 }
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = false
                    panel.title = "Choose image for diagnostics"
                    if panel.runModal() == .OK, let url = panel.url {
                        Task { _ = await manager.runDiagnostics(on: url) }
                    }
                }
            }

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

            List(selection: $manager.selectedEntry) {
                ForEach(manager.entries) { entry in
                    row(for: entry)
                        .tag(entry)
                        .contextMenu {
                            Button("Open") {
                                Task { await manager.navigate(into: entry) }
                            }
                            .disabled(!entry.isDirectory)

                            Button("Copy") {
                                manager.copyEntry(entry)
                            }

                            Button("Delete", role: .destructive) {
                                Task { await manager.deleteEntry(entry) }
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
        // silently fails to highlight/select it.
        .simultaneousGesture(TapGesture(count: 1).onEnded {
            manager.selectedEntry = entry
        })
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            Task { await manager.navigate(into: entry) }
        })
        .onDrag {
            guard let url = manager.materializedURLForDrag(entry) else {
                return NSItemProvider()
            }
            return NSItemProvider(object: url as NSURL)
        }
    }

    private var detailPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Selected item")
                .font(.title3.bold())
                .padding(.top)

            if let entry = manager.selectedEntry {
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
                    manager.deleteSelected()
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
            ZStack {
                Circle()
                    .fill(Color(red: 0.95, green: 0.88, blue: 1.0))
                    .frame(width: 130, height: 130)
                Image(systemName: "externaldrive.connected.to.line.below")
                    .font(.system(size: 52))
                    .foregroundColor(.accentColor)
            }
            Text("Open an HFS disk image")
                .font(.title)
                .bold()
            Text(isDropTargetForOpen ? "Drop to open" : "Choose a .dsk or .img image file formatted with Apple HFS, then browse and manage its contents.")
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
}

private extension FileEntry {
    var sizeText: String {
        guard let size else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}
