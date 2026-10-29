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
    /// Between the pastes of several cards that go in one at a time.
    public var pasteInterval: Duration = .milliseconds(250)

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
    /// text is joined as plain text, one card per line, in strip order. With an
    /// image or audio card among them, the cards are pasted one after another
    /// (runs of text still as lines), since most apps take one image per paste.
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
        let transform: TextTransform? = if case .transformed(let transform) = request { transform } else { nil }

        let wrote: Bool
        if items.allSatisfy({ $0.kind == .file && !$0.missingFiles }) {
            wrote = PasteboardWriter.write(Self.renumbered(payloads.map(\.representations)), to: pasteboard)
        } else {
            let chunks = Self.chunks(payloads, transform: transform)
            if chunks.count == 1, case .text(let text) = chunks[0] {
                wrote = PasteboardWriter.writePlainText(text, to: pasteboard)
            } else {
                closeShelf()
                guard !chunks.isEmpty else { return .failed }
                guard reason == nil else {
                    // Copy only: most apps read just the first pasteboard item, so all the
                    // text goes there as lines; the other cards follow for the apps that take several.
                    guard PasteboardWriter.write(Self.renumbered(Self.copyGroups(chunks)), to: pasteboard) else { return .failed }
                    return await finish(ids: payloads.map(\.item.id), reason: reason, saved: nil)
                }
                return await pasteInTurn(chunks, ids: payloads.map(\.item.id), saved: saved)
            }
        }
        closeShelf()
        guard wrote else { return .failed }
        return await finish(ids: payloads.map(\.item.id), reason: reason, saved: saved)
    }

    /// One paste's worth of several cards: consecutive text joined as lines, or one card with no text.
    enum Chunk: Equatable {
        case text(String)
        case card([ClipRepresentation])

        /// What goes on the pasteboard for this chunk: text already in plain or transformed form.
        var representations: [ClipRepresentation] {
            switch self {
            case .text(let text): [ClipRepresentation(uti: PasteboardTypes.plainText, data: Data(text.utf8))]
            case .card(let representations): representations
            }
        }
    }

    /// Pasteboard items for copying several chunks at once: the text first, joined, then each card.
    static func copyGroups(_ chunks: [Chunk]) -> [[ClipRepresentation]] {
        var texts: [String] = []
        var cards: [[ClipRepresentation]] = []
        for chunk in chunks {
            switch chunk {
            case .text(let text): texts.append(text)
            case .card: cards.append(chunk.representations)
            }
        }
        let text = texts.isEmpty ? [] : [Chunk.text(texts.joined(separator: "\n")).representations]
        return text + cards
    }

    static func chunks(_ payloads: [(item: ClipItem, representations: [ClipRepresentation])], transform: TextTransform?) -> [Chunk] {
        var chunks: [Chunk] = []
        var lines: [String] = []
        func flush() {
            guard !lines.isEmpty else { return }
            let joined = lines.joined(separator: "\n")
            chunks.append(.text(transform?.apply(joined) ?? joined))
            lines = []
        }
        for payload in payloads {
            if let text = PasteboardWriter.plainText(for: payload.item, representations: payload.representations) {
                lines.append(text)
            } else if !payload.representations.isEmpty {
                flush()
                chunks.append(.card(payload.representations))
            }
        }
        flush()
        return chunks
    }

    /// Pastes each chunk with its own ⌘V, waiting `pasteInterval` between them
    /// so the target app has read one before the next replaces it.
    private func pasteInTurn(_ chunks: [Chunk], ids: [UUID], saved: [ClipRepresentation]?) async -> Outcome {
        var pasted = 0
        for chunk in chunks {
            if pasted > 0 { try? await Task.sleep(for: pasteInterval) }
            let wrote = switch chunk {
            case .text(let text): PasteboardWriter.writePlainText(text, to: pasteboard)
            case .card(let representations): PasteboardWriter.write(representations, to: pasteboard)
            }
            guard wrote else { continue }
            keystrokes.sendPaste()
            pasted += 1
        }
        guard pasted > 0 else { return .failed }
        for id in ids.reversed() { try? await store.markUsed(id) }
        if let saved {
            try? await Task.sleep(for: restoreDelay)
            PasteboardWriter.restore(saved, to: pasteboard)
        }
        return .pasted
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
            for id in ids.reversed() { try? await store.markUsed(id) }
            return .copied(reason)
        }
        // The keystroke goes first: waiting on the store here could delay ⌘V
        // until the user has moved on to another window.
        keystrokes.sendPaste()
        for id in ids.reversed() { try? await store.markUsed(id) }
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
