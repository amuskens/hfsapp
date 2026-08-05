import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct FloppyFoxApp: App {
    @StateObject private var manager = DiskImageManager()

    init() {
        // Ensure the process is a regular GUI app so it gets a Dock icon and menu bar when
        // launched directly (for example via `swift run` or running the built executable).
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(manager)
                .onAppear {
                    // Activate the app so it shows in the Dock and receives key events
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
        }
        .commands {
            // App menu placeholder (About/Quit provided automatically by SwiftUI on app bundles,
            // but include replacements when running from command line)
            CommandGroup(replacing: .appInfo) {}

            CommandMenu("File") {
                Button("Open Image") {
                    manager.openImage()
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button("Add Files") {
                    manager.addFiles()
                }
                .disabled((!manager.isMounted && !manager.usingHFSUtils) || manager.isReadOnly)

                Button("Export Selected") {
                    Task { await manager.exportSelected() }
                }
                .disabled(manager.selectedEntry == nil)

                Divider()

                Button("Diagnostics…") {
                    Task {
                        if let image = manager.imageURL {
                            _ = await manager.runDiagnostics(on: image)
                        } else {
                            let panel = NSOpenPanel()
                            panel.allowedContentTypes = [UTType(filenameExtension: "dsk"), UTType(filenameExtension: "img"), UTType(filenameExtension: "hda")].compactMap { $0 }
                            panel.canChooseFiles = true
                            panel.canChooseDirectories = false
                            panel.allowsMultipleSelection = false
                            panel.title = "Choose image for diagnostics"
                            if panel.runModal() == .OK, let url = panel.url {
                                _ = await manager.runDiagnostics(on: url)
                            }
                        }
                    }
                }

                Button("Eject") {
                    Task { await manager.ejectImage() }
                }
                .disabled(!manager.isMounted && !manager.usingHFSUtils)

                Divider()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: [.command])
            }

            CommandMenu("Edit") {
                Button("Cut") {
                    manager.copySelected()
                    manager.deleteSelected()
                }
                .keyboardShortcut("x", modifiers: [.command])
                .disabled(manager.selectedEntry == nil || manager.isReadOnly)

                Button("Copy") {
                    manager.copySelected()
                }
                .keyboardShortcut("c", modifiers: [.command])
                .disabled(manager.selectedEntry == nil)

                Button("Paste") {
                    manager.paste()
                }
                .keyboardShortcut("v", modifiers: [.command])
                .disabled((!manager.isMounted && !manager.usingHFSUtils) || manager.isReadOnly)
            }
        }
    }
}
