import AppKit
import ShelfCore
import SwiftUI

/// Header colors and symbols per kind. System colors, so they follow the
/// accessibility display settings.
extension ContentKind {
    public var headerColor: Color {
        switch self {
        case .text: .blue
        case .richText: .yellow
        case .link: .green
        case .image: .red
        case .file: .cyan
        case .color: .gray // replaced by the color itself
        case .audio: .pink
        case .other: .gray
        }
    }

    public var symbol: String {
        switch self {
        case .text: "text.alignleft"
        case .richText: "textformat"
        case .link: "link"
        case .image: "photo"
        case .file: "doc"
        case .color: "paintpalette"
        case .audio: "waveform"
        case .other: "questionmark.square.dashed"
        }
    }
}

/// A card's header color and whether its text is dark.
public struct CardPalette {
    public var header: Color
    public var darkText: Bool
}

extension ClipItem {
    /// The header color: the source app's icon color (or the kind color when
    /// `fromApp` is off or the app is unknown), and the copied color itself for
    /// color cards.
    @MainActor
    public func palette(fromApp: Bool) -> CardPalette {
        if kind != .color, fromApp, let accent = AppIcons.accentColor(for: sourceBundleID) {
            let luminance = 0.2126 * accent.redComponent + 0.7152 * accent.greenComponent + 0.0722 * accent.blueComponent
            return CardPalette(header: Color(nsColor: accent), darkText: luminance > 0.62)
        }
        return CardPalette(header: headerColor, darkText: headerUsesDarkText)
    }

    /// The header fill: the kind color, or the copied color itself.
    public var headerColor: Color {
        if kind == .color, let colorHex, let color = Color(hex: colorHex) { return color }
        return kind.headerColor
    }

    /// Light headers (yellow, cyan, pale swatches) get dark text.
    public var headerUsesDarkText: Bool {
        switch kind {
        case .richText, .file: return true
        case .color: return colorHex.flatMap(Color.luminance(hex:)).map { $0 > 0.6 } ?? false
        default: return false
        }
    }
}

extension Color {
    /// `#RRGGBB` or `#RRGGBBAA`.
    public init?(hex: String) {
        guard let rgba = Self.components(hex: hex) else { return nil }
        self.init(.sRGB, red: rgba.0, green: rgba.1, blue: rgba.2, opacity: rgba.3)
    }

    static func components(hex: String) -> (Double, Double, Double, Double)? {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6 || digits.count == 8, let value = UInt64(digits, radix: 16) else { return nil }
        let hasAlpha = digits.count == 8
        let red = Double((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let green = Double((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let blue = Double((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let alpha = hasAlpha ? Double(value & 0xFF) / 255 : 1
        return (red, green, blue, alpha)
    }

    /// Relative luminance, 0 (black) to 1 (white).
    static func luminance(hex: String) -> Double? {
        guard let (red, green, blue, _) = components(hex: hex) else { return nil }
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue
    }
}

extension PinboardColor {
    public var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .mint: .mint
        case .teal: .teal
        case .cyan: .cyan
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .brown: .brown
        case .gray: .gray
        }
    }

    public var displayName: String {
        switch self {
        case .red: String(localized: "Red")
        case .orange: String(localized: "Orange")
        case .yellow: String(localized: "Yellow")
        case .green: String(localized: "Green")
        case .mint: String(localized: "Mint")
        case .teal: String(localized: "Teal")
        case .cyan: String(localized: "Cyan")
        case .blue: String(localized: "Blue")
        case .indigo: String(localized: "Indigo")
        case .purple: String(localized: "Purple")
        case .pink: String(localized: "Pink")
        case .brown: String(localized: "Brown")
        case .gray: String(localized: "Gray")
        }
    }
}

extension EnvironmentValues {
    /// Card headers take the source app's icon color (General settings).
    @Entry var cardColorsFromApp = true
}
