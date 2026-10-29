import AppKit
import ApplicationServices
import ShelfCore

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

/// After an update of a build Apple did not sign, macOS keeps the old
/// Accessibility entry, which names the previous build and no longer matches:
/// the switch in System Settings shows on, Shelf is refused, and turning it off
/// and on does not help. On the first start after such an update Shelf clears
/// its own entry once and asks again, so one click in the prompt fixes it.
@MainActor
public enum AccessibilityRecovery {
    /// Returns true when it reset the entry and asked again.
    @discardableResult
    public static func run(
        defaults: UserDefaults,
        build: String,
        isTrusted: Bool,
        reset: () -> Void = { resetOwnEntry() },
        prompt: () -> Void = { SystemAccessibility.prompt() }
    ) -> Bool {
        if isTrusted {
            recordGranted(defaults: defaults, build: build)
            return false
        }
        guard let granted = defaults.string(forKey: PrefKey.accessibilityGrantedBuild), granted != build else { return false }
        // Once per update: a user who turns it off afterwards is not asked again.
        defaults.removeObject(forKey: PrefKey.accessibilityGrantedBuild)
        reset()
        prompt()
        return true
    }

    public static func recordGranted(defaults: UserDefaults, build: String) {
        defaults.set(build, forKey: PrefKey.accessibilityGrantedBuild)
    }

    /// `tccutil reset Accessibility <own bundle id>`: only Shelf's own entry.
    public static func resetOwnEntry() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", bundleID]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}
