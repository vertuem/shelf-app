import AppKit
import ApplicationServices

/// Whether Shelf may post keystrokes. A protocol so tests can deny it.
@MainActor
public protocol AccessibilityChecking {
    var isTrusted: Bool { get }
}

/// The real check. Accessibility is the only permission Shelf asks for.
@MainActor
public struct SystemAccessibility: AccessibilityChecking {
    public init() {}

    public var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that adds Shelf to the Accessibility list.
    public static func prompt() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Opens System Settings at Privacy & Security > Accessibility.
    public static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
