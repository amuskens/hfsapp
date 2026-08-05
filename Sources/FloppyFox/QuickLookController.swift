import AppKit
import QuickLookUI

/// Bridges macOS's native Quick Look panel — the same panel Finder shows for spacebar preview —
/// into the file browser. `QLPreviewPanel` is an AppKit singleton driven by an Objective-C data
/// source, so rather than fighting SwiftUI/AppKit over first-responder status (which would also
/// interrupt the file list's own arrow-key navigation while the Quick Look-triggering view held
/// focus), this listens for the spacebar via a local event monitor: it doesn't require being
/// first responder, only intercepts the one key it cares about, and lets everything else
/// (including a focused button's own spacebar-activation) pass through untouched.
@MainActor
final class QuickLookController: NSObject {
    private weak var manager: DiskImageManager?
    private var eventMonitor: Any?
    private var previewURL: URL?

    func attach(to manager: DiskImageManager) {
        self.manager = manager
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.charactersIgnoringModifiers == " ",
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else {
                return event
            }
            // NSEvent isn't Sendable, so it can't be passed through `MainActor.assumeIsolated`'s
            // closure boundary — everything that needs `event` itself happens above/below this,
            // and only a plain Bool (whether the spacebar was consumed) crosses back out.
            let consumed = MainActor.assumeIsolated {
                self.handleSpacebar()
            }
            return consumed ? nil : event
        }
    }

    func detach() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        eventMonitor = nil
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared() {
            panel.orderOut(nil)
        }
    }

    /// Call when the selected row changes, so an already-open preview follows the selection —
    /// matching Finder, which updates its Quick Look panel as you arrow through a file list.
    func selectionChanged(to entry: FileEntry?) {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible else { return }
        guard let entry, !entry.isDirectory else {
            panel.orderOut(nil)
            return
        }
        Task { await show(entry, panel: panel, makeKey: false) }
    }

    /// Opens (or closes, if already open) the preview for `entry` — used by the "Quick Look"
    /// button, a mouse-driven equivalent of the spacebar shortcut.
    func toggle(for entry: FileEntry?) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.orderOut(nil)
            return
        }
        guard let entry, !entry.isDirectory else { return }
        Task { await show(entry, panel: panel, makeKey: true) }
    }

    /// Returns whether the spacebar was consumed for Quick Look (vs. left to pass through to
    /// whatever would otherwise handle it, e.g. a focused button activating itself).
    private func handleSpacebar() -> Bool {
        // A focused button, toggle, etc. uses spacebar to activate itself — only treat it as
        // Quick Look when focus is elsewhere (e.g. the file list, or nothing in particular).
        if let responder = NSApp.keyWindow?.firstResponder, responder is NSControl {
            return false
        }
        guard manager?.selectedEntry != nil else { return false }
        toggle(for: manager?.selectedEntry)
        return true
    }

    private func show(_ entry: FileEntry, panel: QLPreviewPanel, makeKey: Bool) async {
        // hfsutils-backed entries aren't real files on disk, so materialize a temp copy first
        // (same mechanism as drag-out and double-click-open) — Quick Look needs a real URL.
        guard let url = await manager?.materializeForPreview(entry) else { return }
        previewURL = url
        panel.dataSource = self
        if makeKey {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.reloadData()
        }
    }
}

extension QuickLookController: @MainActor QLPreviewPanelDataSource {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURL != nil ? 1 : 0
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewURL as NSURL?
    }
}
