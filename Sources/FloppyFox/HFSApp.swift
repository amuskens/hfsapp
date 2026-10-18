import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct FloppyFoxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var manager = DiskImageManager()

    init() {
        // Ensure the process is a regular GUI app so it gets a Dock icon and menu bar when
        // launched directly (for example via `swift run` or running the built executable).
        NSApplication.shared.setActivationPolicy(.regular)
        if let icon = FileArtwork.image(named: "AppIcon") {
            NSApplication.shared.applicationIconImage = icon
        }
    }

    var body: some Scene {
        // A single window: there is one shared DiskImageManager, so a second window would only
        // mirror the first (and opening a document must not spawn one).
        Window("FloppyFox", id: "main") {
            ContentView()
                .environmentObject(manager)
                .onAppear {
                    appDelegate.manager = manager
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
                .disabled(!manager.isOpen || manager.isReadOnly)

                Button("Export Selected") {
                    Task { await manager.exportSelected() }
                }
                .disabled(manager.selectedEntries.isEmpty)

                Divider()

                Button("Eject") {
                    Task { await manager.ejectImage() }
                }
                .disabled(!manager.isOpen)
            }
            // "Quit FloppyFox ⌘Q" is already provided automatically (CommandGroup(.appTermination),
            // in the app menu) — the old File menu additionally defined its own "Quit" bound to
            // the same ⌘Q, which is the same duplicate-shortcut problem as above.

            // Find/Spelling/Substitutions/Transformations/Speech have nothing to act on here, so
            // they're dropped. Undo/Redo stay: the folder-name field's editor uses them.
            CommandGroup(replacing: .textEditing) {}

            // `.pasteboard` is the standard Edit menu's Cut/Copy/Paste/Select All section.
            CommandGroup(replacing: .pasteboard) {
                // While a text field is being edited these act on its text, as everywhere else
                // on the Mac, instead of on the files.
                Button("Cut") {
                    if !TextEditing.send(#selector(NSText.cut(_:))) { manager.cutSelected() }
                }
                .keyboardShortcut("x", modifiers: [.command])

                Button("Copy") {
                    if !TextEditing.send(#selector(NSText.copy(_:))) { manager.copySelected() }
                }
                .keyboardShortcut("c", modifiers: [.command])

                Button("Paste") {
                    if !TextEditing.send(#selector(NSText.paste(_:))) { manager.paste() }
                }
                .keyboardShortcut("v", modifiers: [.command])

                Divider()

                Button("Select All") {
                    if !TextEditing.send(#selector(NSText.selectAll(_:))) { manager.selectedEntries = Set(manager.entries) }
                }
                .keyboardShortcut("a", modifiers: [.command])
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

/// Routes an Edit menu command to the text field being edited, if there is one.
@MainActor
private enum TextEditing {
    static func send(_ action: Selector) -> Bool {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSText else { return false }
        return NSApp.sendAction(action, to: editor, from: nil)
    }
}

@MainActor
private enum AppPresentation {
    private static let fallbackVersion = "0.1"
    private static let fallbackBuild = "1"

    /// "beta", "TestFlight", … from the bundle's `FloppyFoxReleaseChannel` key; empty (and
    /// not shown) for a normal release. Set by Tools/build-app.sh's RELEASE_CHANNEL.
    private static var releaseChannel: String {
        (Bundle.main.infoDictionary?["FloppyFoxReleaseChannel"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    private static func withChannel(_ text: String) -> String {
        releaseChannel.isEmpty ? text : "\(text) \(releaseChannel)"
    }

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
            .applicationVersion: withChannel(version),
            .version: "\(withChannel("Version \(version)")) (build \(build))",
            .credits: credits
        ])
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private static var aboutIcon: NSImage {
        if let releaseIconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let releaseIcon = NSImage(contentsOf: releaseIconURL) {
            return releaseIcon
        }
        if let bundledIcon = FileArtwork.image(named: "AppIcon") {
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
        alert.informativeText = "README • \(withChannel("Version \(releaseVersion)"))"
        alert.accessoryView = scrollView
        alert.addButton(withTitle: "Close")
        NSApplication.shared.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private static var releaseVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? fallbackVersion
    }
}

/// Writes pending changes and clears the app's temporary files when it quits.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var manager: DiskImageManager?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let manager else {
            TemporaryStorage.shared.removeLaunchDirectory()
            return .terminateNow
        }
        Task {
            await manager.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
