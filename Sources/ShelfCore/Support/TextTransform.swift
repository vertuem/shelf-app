import Foundation

/// Case changes applied to a card's plain text on paste: "Paste as Uppercase".
public enum TextTransform: String, Sendable, CaseIterable, Hashable {
    case uppercase, lowercase, titleCase, snakeCase, kebabCase

    public var displayName: String {
        switch self {
        case .uppercase: String(localized: "UPPERCASE")
        case .lowercase: String(localized: "lowercase")
        case .titleCase: String(localized: "Title Case")
        case .snakeCase: String(localized: "snake_case")
        case .kebabCase: String(localized: "kebab-case")
        }
    }

    public func apply(_ text: String) -> String {
        switch self {
        case .uppercase: return text.uppercased()
        case .lowercase: return text.lowercased()
        case .titleCase: return text.capitalized
        case .snakeCase: return Self.words(in: text).joined(separator: "_")
        case .kebabCase: return Self.words(in: text).joined(separator: "-")
        }
    }

    /// Lowercase words split on whitespace, punctuation, line breaks and camelCase boundaries.
    static func words(in text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var previousWasLower = false
        func flush() {
            if !current.isEmpty { result.append(current.lowercased()) }
            current = ""
        }
        for character in text {
            if character.isLetter || character.isNumber {
                if character.isUppercase, previousWasLower { flush() }
                current.append(character)
                previousWasLower = character.isLowercase || character.isNumber
            } else {
                flush()
                previousWasLower = false
            }
        }
        flush()
        return result
    }
}
