import AppKit
import ShelfCore

/// Works out which app a copy came from.
///
/// In order: the Universal Clipboard marker (the frontmost app is irrelevant
/// for items from another device), the `org.nspasteboard.source` type some
/// apps volunteer, then the frontmost application.
public enum SourceResolver {
    public static func resolve(types: Set<String>, declaredSource: String?, frontmost: SourceApp) -> SourceApp {
        if types.contains(PasteboardTypes.remoteClipboard) {
            return SourceApp(bundleID: UniversalClipboardSource.bundleID, name: UniversalClipboardSource.name)
        }
        if let declaredSource, !declaredSource.isEmpty, declaredSource != frontmost.bundleID {
            return SourceApp(bundleID: declaredSource, name: appName(for: declaredSource) ?? frontmost.name)
        }
        return frontmost
    }

    /// The frontmost application. `NSWorkspace.frontmostApplication` may be read from any thread.
    public static func frontmost() -> SourceApp {
        let app = NSWorkspace.shared.frontmostApplication
        return SourceApp(bundleID: app?.bundleIdentifier, name: app?.localizedName)
    }

    public static func appName(for bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}
