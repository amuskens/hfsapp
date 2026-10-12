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
                .onOpenURL { url in
                    // Fires when a registered disk image type (see CFBundleDocumentTypes in
                    // Tools/build-app.sh) is opened via double-click, "Open With", or dropped
                    // onto the Dock icon.
                    Task { await manager.attachImage(imageURL: url) }
                }
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About FloppyFox") {
                    AppPresentation.showAboutPanel()
                }
            }

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
                            panel.allowedContentTypes = DiskImageManager.supportedImageTypes
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

            CommandGroup(replacing: .help) {
                Button("FloppyFox Help") {
                    AppPresentation.showReadme()
                }
                .keyboardShortcut("?", modifiers: [.command])
            }
        }
    }
}

@MainActor
private enum AppPresentation {
    private static let fallbackVersion = "0.1"
    private static let fallbackBuild = "1"
    private static let releaseChannel = "beta"

    static func showAboutPanel() {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? fallbackVersion
        let build = info?["CFBundleVersion"] as? String ?? fallbackBuild
        let credits = NSAttributedString(
            string: "(C) 2026 Anders Muskens\n\nCreated by Anders Muskens\n\nAI agent assistance: ChatGPT and Claude",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationName: "FloppyFox",
            .applicationIcon: aboutIcon,
            .applicationVersion: "\(version) \(releaseChannel)",
            .version: "Version \(version) \(releaseChannel) (build \(build))",
            .credits: credits
        ])
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private static var aboutIcon: NSImage {
        if let releaseIconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let releaseIcon = NSImage(contentsOf: releaseIconURL) {
            return releaseIcon
        }
        if let bundledIconURL = Bundle.floppyFoxResources.url(forResource: "FloppyFoxIcon", withExtension: "svg"),
           let bundledIcon = NSImage(contentsOf: bundledIconURL) {
            return bundledIcon
        }
        return NSApplication.shared.applicationIconImage
    }

    static func showReadme() {
        let helpURL = Bundle.floppyFoxResources.url(forResource: "FloppyFoxHelp", withExtension: "md")
        let readme = helpURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            ?? "FloppyFox Help\n\nThe bundled README could not be loaded."

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 590, height: 380))
        textView.string = readme
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .labelColor
        textView.textContainer?.widthTracksTextView = true

        let scrollView = NSScrollView(frame: textView.frame)
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "FloppyFox Help"
        alert.informativeText = "README • Version \(releaseVersion) \(releaseChannel)"
        alert.accessoryView = scrollView
        alert.addButton(withTitle: "Close")
        NSApplication.shared.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private static var releaseVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? fallbackVersion
    }
}
