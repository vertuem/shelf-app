import Foundation
import ShelfCore

/// Card-facing strings: relative times, footers, VoiceOver labels.
@MainActor
public enum Formatters {
    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return formatter
    }()

    private static let bytes: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    public static func relativeTime(_ date: Date, now: Date = Date()) -> String {
        if now.timeIntervalSince(date) < 60 { return String(localized: "Just now") }
        return relative.localizedString(for: date, relativeTo: now)
    }

    public static func byteCount(_ count: Int64) -> String {
        bytes.string(fromByteCount: count)
    }

    /// The footer line: character count, dimensions, file size or host.
    public static func footer(for item: ClipItem) -> String {
        switch item.kind {
        case .text, .richText:
            return String(localized: "\(item.characterCount) characters")
        case .image:
            if let width = item.width, let height = item.height {
                return "\(width) × \(height)"
            }
            return byteCount(Int64(item.byteSize))
        case .link:
            return item.host ?? item.url ?? ""
        case .file:
            if item.filePaths.count > 1 {
                return String(localized: "\(item.filePaths.count) files")
            }
            if let path = item.filePaths.first {
                // Where the file lives: "~/Documents/website".
                return ((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
            }
            return item.promised ? String(localized: "Pending") : ""
        case .color:
            return item.colorHex.flatMap(rgbDescription) ?? ""
        case .audio, .other:
            return byteCount(Int64(item.byteSize))
        }
    }

    static func rgbDescription(_ hex: String) -> String? {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count >= 6, let value = UInt64(digits.prefix(6), radix: 16) else { return nil }
        return "RGB \((value >> 16) & 0xFF) \((value >> 8) & 0xFF) \(value & 0xFF)"
    }

    /// "Text from Safari, 3 minutes ago, 65 characters"
    public static func accessibilityLabel(for item: ClipItem, now: Date = Date()) -> String {
        let source = item.sourceAppName ?? String(localized: "Unknown")
        let what = item.title.map { "\($0), \(item.kind.displayName)" } ?? item.kind.displayName
        return String(localized: "\(what) from \(source), \(relativeTime(item.lastUsedAt, now: now)), \(footer(for: item))")
    }
}
