import AppKit
import KeyboardShortcuts

/// The configurable shortcuts. Stored by KeyboardShortcuts in UserDefaults.
///
/// Only the two activation shortcuts are registered globally. The pinboard
/// shortcuts are matched inside the shelf only, so Cmd+Left and Cmd+Right keep
/// working in every other app.
extension KeyboardShortcuts.Name {
    public static let activateShelf = Self("activateShelf", initial: .init(.v, modifiers: [.command, .shift]))
    public static let activatePasteStack = Self("activatePasteStack", initial: .init(.c, modifiers: [.command, .shift]))
    public static let nextPinboard = Self("nextPinboard", initial: .init(.rightArrow, modifiers: [.command]))
    public static let previousPinboard = Self("previousPinboard", initial: .init(.leftArrow, modifiers: [.command]))
    /// Pause or resume capture from anywhere. No default: set it in Settings.
    public static let togglePause = Self("togglePause")
}

@MainActor
public enum Hotkeys {
    public static func register(onShelf: @escaping () -> Void, onPasteStack: @escaping () -> Void, onPause: @escaping () -> Void = {}) {
        KeyboardShortcuts.onKeyDown(for: .activateShelf, action: onShelf)
        KeyboardShortcuts.onKeyDown(for: .activatePasteStack, action: onPasteStack)
        KeyboardShortcuts.onKeyDown(for: .togglePause, action: onPause)
    }

    public static func resetToDefaults() {
        KeyboardShortcuts.reset(.activateShelf, .activatePasteStack, .nextPinboard, .previousPinboard, .togglePause)
    }

    /// The shortcut for a menu row, or nil when none is set.
    public static func displayIfSet(_ name: KeyboardShortcuts.Name) -> String? {
        KeyboardShortcuts.getShortcut(for: name)?.description
    }

    /// Whether a key event inside the shelf matches a stored, unregistered shortcut.
    public static func matches(_ event: NSEvent, _ name: KeyboardShortcuts.Name) -> Bool {
        guard let shortcut = KeyboardShortcuts.getShortcut(for: name) else { return false }
        let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        return Int(event.keyCode) == shortcut.carbonKeyCode
            && event.modifierFlags.intersection(relevant) == shortcut.modifiers.intersection(relevant)
    }

    /// The shortcut as the user sees it, for menus and onboarding ("⇧⌘V").
    public static func display(_ name: KeyboardShortcuts.Name) -> String {
        KeyboardShortcuts.getShortcut(for: name)?.description ?? String(localized: "Not set")
    }
}
