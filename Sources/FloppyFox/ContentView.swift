import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var manager = DiskImageManager()
    @State private var isDropTarget = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding()
                .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            if manager.isMounted || manager.usingHFSUtils {
                mountedContent
            } else {
                placeholderView
            }
        }
        .frame(minWidth: 820, minHeight: 520)
        .alert("Error", isPresented: .constant(manager.errorMessage != nil), presenting: manager.errorMessage) { message in
            Button("OK", role: .cancel) {
                manager.errorMessage = nil
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
            .disabled(!manager.isMounted && !manager.usingHFSUtils)

            Button("Copy") {
                manager.copySelected()
            }
            .disabled(manager.selectedEntry == nil)

            Button("Paste") {
                manager.paste()
            }
            .disabled(!manager.isMounted && !manager.usingHFSUtils)

            Button("Export") {
                manager.exportSelected()
            }
            .disabled(manager.selectedEntry == nil)

            Spacer()

            Button("Refresh") {
                manager.refresh()
            }
            .disabled(!manager.isMounted && !manager.usingHFSUtils)

            Toggle("Confirm detach", isOn: $manager.confirmBeforeDetach)
                .toggleStyle(.switch)
                .frame(width: 200)

            Button("Diagnostics") {
                // Run diagnostics on current image if loaded, otherwise let user choose
                if let image = manager.imageURL {
                    if let _ = manager.runDiagnostics(on: image) {
                        // notification opens the file
                    }
                } else {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [UTType(filenameExtension: "dsk"), UTType(filenameExtension: "img")].compactMap { $0 }
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = false
                    panel.title = "Choose image for diagnostics"
                    if panel.runModal() == .OK, let url = panel.url {
                        if let _ = manager.runDiagnostics(on: url) {
                            // notification opens the file
                        }
                    }
                }
            }

            Button("Eject") {
                manager.ejectImage()
            }
            .disabled(!manager.isMounted && !manager.usingHFSUtils)
        }
    }

    private var mountedContent: some View {
        HStack(spacing: 0) {
            fileBrowser
                .frame(minWidth: 340)
                .background(Color(nsColor: .textBackgroundColor))
                .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTarget) { providers in
                    manager.handleDroppedFiles(providers: providers)
                }

            Divider()

            detailPane
                .frame(minWidth: 280)
        }
    }

    private var fileBrowser: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(manager.mountPoint?.lastPathComponent ?? manager.imageURL?.lastPathComponent ?? "Mounted Volume")
                    .font(.title2.bold())
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
                    manager.goUp()
                }
                .disabled(!manager.canGoBack)

                Spacer()

                Text(isDropTarget ? "Drop files here to add them to the volume" : "Drag files here from Finder to copy them into the mounted volume")
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
                                manager.navigate(into: entry)
                            }
                            .disabled(!entry.isDirectory)

                            Button("Copy") {
                                manager.copyEntry(entry)
                            }

                            Button("Delete", role: .destructive) {
                                manager.deleteEntry(entry)
                            }
                            .disabled(entry.url == manager.currentDirectory)
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
        .onTapGesture(count: 2) {
            manager.navigate(into: entry)
        }
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
            Image(systemName: "externaldrive.connected.to.line.below")
                .font(.system(size: 56))
                .foregroundColor(.accentColor)
            Text("Open an HFS disk image")
                .font(.title)
                .bold()
            Text("Choose a .dsk or .img image file formatted with Apple HFS, then browse and manage its contents.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .frame(maxWidth: 520)
            Button("Open Image") {
                manager.openImage()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension FileEntry {
    var sizeText: String {
        guard let size else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}
