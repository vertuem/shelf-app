import Foundation
import ShelfCore
import UniformTypeIdentifiers

/// Step 8 of the capture flow: one `ContentKind` per copy, first match wins.
///
/// | Kind     | Rule |
/// |----------|------|
/// | color    | the color pasteboard type is present |
/// | file     | `public.file-url` or a file promise is present |
/// | image    | image data is present, no file URL, and no rich text with real text beside it |
/// | audio    | a type conforming to `public.audio` is present |
/// | link     | a single `public.url`, or text that is exactly one URL with a scheme |
/// | richText | `public.rtf`, `public.html` or `com.apple.flat-rtfd` is present |
/// | text     | plain text is present; a lone `#RRGGBB` becomes a color |
/// | other    | anything else; stored and shown with a generic card |
///
/// Images are not simply "has image data": Excel,
/// Numbers and Pages put a rendered picture next to the text of every copy,
/// and those copies are text to the user.
public enum Classifier {
    public static func classify(_ snapshot: PasteboardSnapshot) -> ContentKind {
        let types = snapshot.allTypes

        if types.contains(PasteboardTypes.color) { return .color }
        if types.contains(PasteboardTypes.fileURL) || !snapshot.promisedTypes.isEmpty { return .file }

        let text = snapshot.plainText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasRichText = !types.isDisjoint(with: PasteboardTypes.richTextTypes)
        let textIsJustAReference = text.isEmpty || singleURL(in: text) != nil
        // A file name or alt text beside a picture does not make it text; a spreadsheet
        // range (rich text plus real text) or a long passage does.
        let hasRealText = !textIsJustAReference && (hasRichText || text.count >= 200)

        if hasImage(types), !hasRealText { return .image }
        if types.contains(where: isAudio) { return .audio }

        if snapshot.items.count == 1, snapshot.data(for: PasteboardTypes.url) != nil, textIsJustAReference {
            return .link
        }
        if singleURL(in: text) != nil { return .link }

        if hasRichText { return .richText }
        if !text.isEmpty {
            return hexColor(in: text) != nil ? .color : .text
        }
        return .other
    }

    static func hasImage(_ types: Set<String>) -> Bool {
        if !types.isDisjoint(with: PasteboardTypes.imageTypes) { return true }
        return types.contains { type in
            guard let utType = UTType(type) else { return false }
            return utType.conforms(to: .image) && utType != .icns && !type.hasPrefix("com.apple.icns")
        }
    }

    static func isAudio(_ type: String) -> Bool {
        UTType(type)?.conforms(to: .audio) ?? false
    }

    /// The URL if `text` is exactly one URL with a scheme and a host (or a mailto).
    public static func singleURL(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count < 4_096, !trimmed.contains(where: \.isWhitespace) else { return nil }
        guard let components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased() else { return nil }
        switch scheme {
        case "http", "https", "ftp", "ssh", "sftp":
            guard let host = components.host, !host.isEmpty else { return nil }
        case "mailto", "tel":
            guard !components.path.isEmpty else { return nil }
        case "file":
            return nil
        default:
            // Custom schemes (slack://, figma://) count when they look like URLs.
            guard trimmed.contains("://"), scheme.count > 1 else { return nil }
        }
        return components.url
    }

    /// Normalized `#RRGGBB` or `#RRGGBBAA` if `text` is a lone hex color.
    public static func hexColor(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("#") else { return nil }
        let digits = trimmed.dropFirst()
        guard [3, 6, 8].contains(digits.count), digits.allSatisfy(\.isHexDigit) else { return nil }
        let expanded = digits.count == 3 ? digits.map { "\($0)\($0)" }.joined() : String(digits)
        return "#" + expanded.uppercased()
    }
}
