import AppKit
import ShelfCore

/// Puts a stored item back on the pasteboard and, when allowed, pastes it into
/// the app the user was working in.
///
/// The sequence:
/// 1. The caller records the frontmost app before the shelf opened. The shelf
///    panel is non-activating, so that app is still frontmost.
/// 2. Save the current pasteboard contents in memory.
/// 3. Write the item's types. Plain-text mode writes plain text only.
/// 4. Close the shelf (the caller's `closeShelf`), so the keystroke reaches the target.
/// 5. Post Cmd+V, unless paste mode is "to clipboard", Accessibility is missing,
///    or the target is on the manual-paste list.
/// 6. After 150 ms, restore the saved contents if "restore previous clipboard" is on.
/// 7. Move the item to the front of the history.
@MainActor
public final class Paster {
    public enum Request: Sendable, Equatable {
        /// Enter: paste into the active app.
        case paste
        /// Cmd+Enter: paste as plain text.
        case pastePlain
        /// Shift+Enter: copy to the clipboard only.
        case copy
        /// "Paste as Uppercase" and friends: plain text with a case change.
        case transformed(TextTransform)
    }

    public enum Outcome: Equatable, Sendable {
        case pasted
        /// On the clipboard, the user presses Cmd+V. The reason picks the toast.
        case copied(CopyReason)
        case failed
    }

    public enum CopyReason: Equatable, Sendable {
        case requested
        case pasteModeIsClipboard
        case accessibilityMissing
        case manualPasteApp(String)
    }

    private let store: Store
    private let preferences: Preferences
    private let pasteboard: NSPasteboard
    private let keystrokes: any KeystrokeSending
    private let accessibility: any AccessibilityChecking
    /// How long the target app gets to read the pasteboard before the old contents return.
    public var restoreDelay: Duration = .milliseconds(150)

    public init(
        store: Store,
        preferences: Preferences,
        pasteboard: NSPasteboard = .general,
        keystrokes: any KeystrokeSending = CGEventKeystrokeSender(),
        accessibility: any AccessibilityChecking = SystemAccessibility()
    ) {
        self.store = store
        self.preferences = preferences
        self.pasteboard = pasteboard
        self.keystrokes = keystrokes
        self.accessibility = accessibility
    }

    /// The paste mode in effect: without Accessibility it is always "to clipboard".
    public var effectivePasteMode: PasteMode {
        accessibility.isTrusted ? preferences.pasteMode : .toClipboard
    }

    @discardableResult
    public func perform(
        _ request: Request,
        item: ClipItem,
        targetBundleID: String?,
        closeShelf: () -> Void = {}
    ) async -> Outcome {
        let transform: TextTransform? = if case .transformed(let transform) = request { transform } else { nil }
        let wantsPlain = request == .pastePlain || transform != nil || (request == .paste && preferences.alwaysPastePlainText)

        let representations: [ClipRepresentation]
        do {
            representations = try await payload(for: item)
        } catch {
            Log.paste.error("Could not load an item: \(String(describing: type(of: error)), privacy: .public)")
            closeShelf()
            return .failed
        }

        let reason = copyOnlyReason(for: request, targetBundleID: targetBundleID)
        let saved = reason == nil && preferences.restorePreviousClipboard ? PasteboardWriter.saveContents(of: pasteboard) : nil

        let wrote: Bool
        if item.missingFiles {
            // The file is gone; its path is still useful.
            wrote = PasteboardWriter.writePlainText(item.filePaths.joined(separator: "\n"), to: pasteboard)
        } else if wantsPlain, let text = PasteboardWriter.plainText(for: item, representations: representations) {
            wrote = PasteboardWriter.writePlainText(transform?.apply(text) ?? text, to: pasteboard)
        } else {
            wrote = PasteboardWriter.write(representations, to: pasteboard)
        }
        closeShelf()
        guard wrote else { return .failed }
        return await finish(ids: [item.id], reason: reason, saved: saved)
    }

    /// Several cards at once (Shift with the arrows, then Return). Files become
    /// one pasteboard item per file, so Finder receives them as separate files;
    /// everything else is joined as plain text, one card per line, in strip order.
    /// Cards with no textual form (images, audio) are left out.
    @discardableResult
    public func perform(
        _ request: Request,
        items: [ClipItem],
        targetBundleID: String?,
        closeShelf: () -> Void = {}
    ) async -> Outcome {
        guard items.count > 1 else {
            if let only = items.first {
                return await perform(request, item: only, targetBundleID: targetBundleID, closeShelf: closeShelf)
            }
            closeShelf()
            return .failed
        }
        var payloads: [(item: ClipItem, representations: [ClipRepresentation])] = []
        for item in items {
            if let representations = try? await payload(for: item) {
                payloads.append((item, representations))
            }
        }
        let reason = copyOnlyReason(for: request, targetBundleID: targetBundleID)
        let saved = reason == nil && preferences.restorePreviousClipboard ? PasteboardWriter.saveContents(of: pasteboard) : nil

        let wrote: Bool
        if items.allSatisfy({ $0.kind == .file && !$0.missingFiles }) {
            wrote = PasteboardWriter.write(Self.renumbered(payloads.map(\.representations)), to: pasteboard)
        } else {
            let texts = payloads.compactMap { PasteboardWriter.plainText(for: $0.item, representations: $0.representations) }
            guard !texts.isEmpty else {
                closeShelf()
                return .failed
            }
            let joined = texts.joined(separator: "\n")
            let transform: TextTransform? = if case .transformed(let transform) = request { transform } else { nil }
            wrote = PasteboardWriter.writePlainText(transform?.apply(joined) ?? joined, to: pasteboard)
        }
        closeShelf()
        guard wrote else { return .failed }
        return await finish(ids: payloads.map(\.item.id), reason: reason, saved: saved)
    }

    /// Concatenates several items' representations with fresh, consecutive item indexes.
    static func renumbered(_ groups: [[ClipRepresentation]]) -> [ClipRepresentation] {
        var combined: [ClipRepresentation] = []
        var index = 0
        for representations in groups {
            let byItem = Dictionary(grouping: representations, by: \.itemIndex)
            for key in byItem.keys.sorted() {
                for representation in byItem[key] ?? [] {
                    combined.append(ClipRepresentation(itemIndex: index, uti: representation.uti, data: representation.data))
                }
                index += 1
            }
        }
        return combined
    }

    private func finish(ids: [UUID], reason: CopyReason?, saved: [ClipRepresentation]?) async -> Outcome {
        if let reason {
            for id in ids { try? await store.markUsed(id) }
            return .copied(reason)
        }
        // The keystroke goes first: waiting on the store here could delay ⌘V
        // until the user has moved on to another window.
        keystrokes.sendPaste()
        for id in ids { try? await store.markUsed(id) }
        if let saved {
            try? await Task.sleep(for: restoreDelay)
            PasteboardWriter.restore(saved, to: pasteboard)
        }
        return .pasted
    }

    /// Writes an item without pasting, for the Paste Stack's click-to-copy fallback.
    @discardableResult
    public func copyToClipboard(_ item: ClipItem, representations: [ClipRepresentation]) -> Bool {
        if preferences.alwaysPastePlainText, let text = PasteboardWriter.plainText(for: item, representations: representations) {
            return PasteboardWriter.writePlainText(text, to: pasteboard)
        }
        return PasteboardWriter.write(representations, to: pasteboard)
    }

    /// The stored types, or the thumbnail for oversized items that kept nothing else.
    public func payload(for item: ClipItem) async throws -> [ClipRepresentation] {
        let stored = try await store.representations(for: item.id)
        if stored.isEmpty, item.oversized, let thumbnail = store.thumbnail(for: item.id),
           let png = PasteboardWriter.pngRepresentation(ofThumbnail: thumbnail) {
            return [png]
        }
        return stored
    }

    private func copyOnlyReason(for request: Request, targetBundleID: String?) -> CopyReason? {
        if request == .copy { return .requested }
        if !accessibility.isTrusted { return .accessibilityMissing }
        if preferences.pasteMode == .toClipboard { return .pasteModeIsClipboard }
        if let targetBundleID, AppList.matches(targetBundleID, in: preferences.manualPasteApps) {
            return .manualPasteApp(targetBundleID)
        }
        return nil
    }
}
