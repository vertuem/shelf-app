import Foundation

/// A named, ordered list of items that are exempt from history retention.
public struct Pinboard: Sendable, Identifiable, Hashable {
    public let id: UUID
    public var name: String
    public var color: PinboardColor
    /// SF Symbol name, chosen in the pinboard's context menu (v1.1).
    public var icon: String?
    public var ordinal: Int
    public var createdAt: Date
    /// Number of items on the board, filled in by `Store.pinboards()`.
    public var itemCount: Int

    public init(
        id: UUID = UUIDv7.make(),
        name: String,
        color: PinboardColor = .blue,
        icon: String? = nil,
        ordinal: Int = 0,
        createdAt: Date = Date(),
        itemCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.icon = icon
        self.ordinal = ordinal
        self.createdAt = createdAt
        self.itemCount = itemCount
    }

    /// Soft limits: crossing them shows a warning, never an error.
    public static let softLimitCount = 50
    public static let softLimitItems = 2_000
}

/// The palette offered for pinboard chips. Maps to system colors in the UI.
public enum PinboardColor: String, Sendable, CaseIterable, Codable {
    case red, orange, yellow, green, mint, teal, cyan, blue, indigo, purple, pink, brown, gray

    /// Cycles through the palette so new boards get distinct colors.
    public static func next(after count: Int) -> PinboardColor {
        let order: [PinboardColor] = [.blue, .green, .orange, .purple, .pink, .teal, .yellow, .red, .indigo, .mint, .cyan, .brown, .gray]
        return order[count % order.count]
    }
}

/// Icons offered for pinboards (v1.1). SF Symbols available on macOS 14.
public enum PinboardIcon {
    public static let choices = [
        "pin", "star", "heart", "bookmark", "tag", "folder", "doc.text", "curlybraces",
        "terminal", "link", "photo", "paintpalette", "envelope", "person", "briefcase",
        "cart", "lightbulb", "flag", "bolt", "globe",
    ]
}
