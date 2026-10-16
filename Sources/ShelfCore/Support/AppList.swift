import Foundation

/// Bundle id lists with optional trailing wildcards: `com.parallels.*` matches
/// every Parallels process, `com.wiheads.paste*` every edition of Paste.
public enum AppList {
    public static func matches(_ bundleID: String, in list: some Collection<String>) -> Bool {
        list.contains { entry in
            entry.hasSuffix("*") ? bundleID.hasPrefix(String(entry.dropLast())) : entry == bundleID
        }
    }
}
