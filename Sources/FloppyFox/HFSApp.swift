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

            // `CommandGroup(replacing:)` inserts into the File/Edit menus every Mac app already
            // gets for free; a `CommandMenu("File")`/`CommandMenu("Edit")` used to be used here
            // instead, which doesn't replace anything — it creates a brand-new top-level menu
            // with that title, so the menu bar showed two "File" menus and two "Edit" menus, with
            // shortcuts like ⌘X/⌘C/⌘V/⌘A/⌘Q each bound twice (once automatically, once by the
            // duplicate menu).
            //
            // `.newItem` is normally "New Window ⌘N" / "Open Recent" — replaced outright rather
            // than added after, since this app has exactly one shared `DiskImageManager` and a
            // second window would just show the same disk image state, not a genuinely new one.
            CommandGroup(replacing: .newItem) {
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
                .disabled(manager.selectedEntries.isEmpty)

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
            }
            // "Quit FloppyFox ⌘Q" is already provided automatically (CommandGroup(.appTermination),
            // in the app menu) — the old File menu additionally defined its own "Quit" bound to
            // the same ⌘Q, which is the same duplicate-shortcut problem as above.

            // Undo/Redo and Find/Spelling/Substitutions/Transformations/Speech are part of every
            // app's default Edit menu, but nothing in this app ever registers an `UndoManager` or
            // hosts an editable text view for them to act on — they'd just sit there permanently
            // grayed out, so they're dropped instead of leaving dead menu items around.
            CommandGroup(replacing: .undoRedo) {}
            CommandGroup(replacing: .textEditing) {}

            // `.pasteboard` is the standard Edit menu's Cut/Copy/Paste/Select All section.
            CommandGroup(replacing: .pasteboard) {
                Button("Cut") {
                    manager.cutSelected()
                }
                .keyboardShortcut("x", modifiers: [.command])
                .disabled(manager.selectedEntries.isEmpty || manager.isReadOnly)

                Button("Copy") {
                    manager.copySelected()
                }
                .keyboardShortcut("c", modifiers: [.command])
                .disabled(manager.selectedEntries.isEmpty)

                Button("Paste") {
                    manager.paste()
                }
                .keyboardShortcut("v", modifiers: [.command])
                .disabled((!manager.isMounted && !manager.usingHFSUtils) || manager.isReadOnly)

                Divider()

                Button("Select All") {
                    manager.selectedEntries = Set(manager.entries)
                }
                .keyboardShortcut("a", modifiers: [.command])
                .disabled(manager.entries.isEmpty)
            }
        }
    }
}
