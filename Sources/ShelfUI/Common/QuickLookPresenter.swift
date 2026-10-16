import AppKit
import QuickLookUI
import ShelfCore

/// Space on a card: Quick Look of the item (v1.1).
///
/// The item is written to a private temporary file first (decrypted), which is
/// deleted when the preview closes. Files that still exist are previewed in place.
///
/// The preview never takes key status: the shelf keeps the keyboard, so the
/// arrows move through cards with the preview following, Space and Escape
/// close it, and Return pastes.
@MainActor
public final class QuickLookPresenter: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private var url: URL?
    private var temporaryURL: URL?
    private let makeFile: (ClipItem) async -> URL?
    /// Bumped per request, so a slow file write for an earlier card cannot
    /// replace the preview of the card the user has arrowed to since.
    private var generation = 0

    public init(makeFile: @escaping (ClipItem) async -> URL?) {
        self.makeFile = makeFile
    }

    /// True from the moment a preview is asked for, before its file is written.
    public private(set) var isOpen = false

    /// Shows the item, or replaces what an open preview shows.
    public func show(_ item: ClipItem, above level: NSWindow.Level) {
        isOpen = true
        generation += 1
        let request = generation
        Task { await load(item, above: level, request: request) }
    }

    public func close() {
        isOpen = false
        generation += 1
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.dataSource === self {
            panel.orderOut(nil)
        }
        cleanUp()
    }

    private func load(_ item: ClipItem, above level: NSWindow.Level, request: Int) async {
        let newURL: URL?
        var newTemporaryURL: URL?
        if item.kind == .file, let path = item.filePaths.first, FileManager.default.fileExists(atPath: path) {
            newURL = URL(fileURLWithPath: path)
        } else {
            newTemporaryURL = await makeFile(item)
            newURL = newTemporaryURL
        }
        guard request == generation else {
            Self.remove(newTemporaryURL)
            return
        }
        cleanUp()
        url = newURL
        temporaryURL = newTemporaryURL
        guard let panel = QLPreviewPanel.shared() else { return }
        if url == nil, !panel.isVisible {
            isOpen = false
            return
        }
        panel.dataSource = self
        panel.delegate = self
        panel.level = NSWindow.Level(rawValue: level.rawValue + 1)
        // Also with no file: an open preview must not keep showing the previous card.
        panel.reloadData()
        panel.orderFrontRegardless()
    }

    public nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { url == nil ? 0 : 1 }
    }

    public nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { url as NSURL? }
    }

    /// The preview's own close button.
    public nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            isOpen = false
            generation += 1
            cleanUp()
        }
    }

    private func cleanUp() {
        Self.remove(temporaryURL)
        temporaryURL = nil
        url = nil
    }

    private static func remove(_ temporaryURL: URL?) {
        if let temporaryURL {
            try? FileManager.default.removeItem(at: temporaryURL.deletingLastPathComponent())
        }
    }
}
