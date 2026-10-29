import AppKit
import KeyboardShortcuts
import ShelfCore
import SwiftUI

/// Every keyboard shortcut, in one place. Shown by the Help menu, by ⌘/ in the
/// shelf, and embedded in the Shortcuts settings pane.
public struct CheatSheetView: View {
    public init() {}

    /// Each row: the keys, drawn as separate caps, and what they do.
    static var rows: [(keys: [String], action: String)] {
        let quick = QuickPasteSymbol.current
        let plain = Preferences().plainTextModifier == .shift ? "⇧" : "⌥"
        return [
            ([Hotkeys.display(.activateShelf)], String(localized: "Open or close the shelf")),
            ([Hotkeys.display(.activatePasteStack)], String(localized: "Open or close the Paste Stack")),
            (["←", "→"], String(localized: "Move the selection")),
            (["↑", "↓"], String(localized: "Move between rows (left, right and center shelves)")),
            (["⇧←", "⇧→"], String(localized: "Select more cards; Return pastes them all")),
            (["⇞", "⇟"], String(localized: "A page of cards")),
            (["↖", "↘"], String(localized: "First or last card")),
            (["↩"], String(localized: "Paste the selected item and close")),
            (["⌘↩"], String(localized: "Paste as plain text")),
            (["⇧↩"], String(localized: "Copy to the clipboard without pasting")),
            (["\(quick)1 – \(quick)9"], String(localized: "Paste the nth visible card")),
            (["\(plain)\(quick)1 – 9"], String(localized: "Paste the nth visible card as plain text")),
            ([String(localized: "Space")], String(localized: "Open or close Quick Look")),
            (["⌫"], String(localized: "Remove from history (⌘⌫ while searching)")),
            (["⌘Z"], String(localized: "Undo the removal")),
            (["⌘P"], String(localized: "Pin to a pinboard")),
            (["⌘R"], String(localized: "Rename the selected card")),
            (["⌘G"], String(localized: "Show a search result in the Clipboard or its pinboard")),
            ([Hotkeys.display(.togglePause)], String(localized: "Pause or resume capture (anywhere)")),
            ([Hotkeys.display(.previousPinboard), Hotkeys.display(.nextPinboard), "⇧⇥", "⇥"], String(localized: "Previous or next pinboard")),
            (["⌘F"], String(localized: "Focus search")),
            (["⇥"], String(localized: "Accept the suggested filter while typing type:, app: or pinned:")),
            (["⇧⌘F"], String(localized: "Search all tabs")),
            (["⌘C"], String(localized: "Copy the selected item")),
            (["⌘,"], String(localized: "Settings")),
            (["⎋"], String(localized: "Clear search, then close")),
            ([String(localized: "Double click")], String(localized: "Paste; hold \(plain) for plain text")),
        ]
    }

    public var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
            ForEach(Self.rows, id: \.action) { row in
                GridRow {
                    KeyCaps(keys: row.keys)
                        .gridColumnAlignment(.trailing)
                    Text(row.action)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(28)
        .fixedSize()
    }
}

/// A plain window hosting the cheat sheet.
@MainActor
public final class CheatSheetWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    override public init() {}

    public func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: CheatSheetView().padding(.top, 12)))
            window.title = String(localized: "\(Brand.name) Keyboard Shortcuts")
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.center()
            window.delegate = self
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    public nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            // Otherwise Shelf stays frontmost and the next paste has no app to go to.
            NSApp.hide(nil)
        }
    }
}
