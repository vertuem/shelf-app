import Foundation

/// What a clipboard item is, decided once at capture time by `Classifier`.
///
/// The raw values are stored in the `item.kind` column and used by the
/// `type:` search filter, so they must never change.
public enum ContentKind: String, Sendable, CaseIterable, Codable {
    case text
    case richText
    case link
    case image
    case file
    case color
    case audio
    case other

    /// The name printed in the card header. Color is never the only signal.
    public var displayName: String {
        switch self {
        case .text: String(localized: "Text")
        case .richText: String(localized: "Rich Text")
        case .link: String(localized: "Link")
        case .image: String(localized: "Image")
        case .file: String(localized: "File")
        case .color: String(localized: "Color")
        case .audio: String(localized: "Audio")
        case .other: String(localized: "Other")
        }
    }

    /// The canonical `type:` token, as offered by the search suggestions.
    public var searchToken: String { rawValue.lowercased() }

    /// Accepts the raw value and a few forgiving aliases for the `type:` filter.
    public init?(searchToken: String) {
        let token = searchToken.lowercased()
        switch token {
        case "text", "txt", "plain": self = .text
        case "richtext", "rich", "rtf", "html": self = .richText
        case "link", "url", "links", "urls": self = .link
        case "image", "img", "images", "picture", "photo": self = .image
        case "file", "files": self = .file
        case "color", "colour", "colors": self = .color
        case "audio", "sound": self = .audio
        case "other": self = .other
        default: return nil
        }
    }
}
