import Foundation

/// A parsed search string.
///
/// Free text is split into terms; every term must match (case-insensitive
/// substring on preview, app name, URL and file names). Quoted phrases stay
/// one term. Filters are written as prefixes and shown as removable chips:
///
/// ```
/// type:image   app:Safari   after:2026-10-01   before:7d   pinned:   pinned:Snippets
/// ```
public struct SearchQuery: Sendable, Equatable {
    public var terms: [String] = []
    public var kinds: Set<ContentKind> = []
    public var apps: [String] = []
    public var after: Date?
    public var before: Date?
    public var pinned: PinnedFilter?
    /// Filters in the order typed, for the chips.
    public var filters: [Filter] = []

    public enum PinnedFilter: Sendable, Equatable {
        case anyBoard
        case board(String)
    }

    /// One recognized `key:value` token and where it sits in the original text.
    public struct Filter: Sendable, Equatable, Identifiable {
        public var key: String
        public var value: String
        public var range: Range<String.Index>
        public var id: String { "\(key):\(value)" }
        public var label: String { value.isEmpty ? key : "\(key): \(value)" }
    }

    public init() {}

    public var isEmpty: Bool {
        terms.isEmpty && kinds.isEmpty && apps.isEmpty && after == nil && before == nil && pinned == nil
    }

    /// The free text without filters, for highlighting and fuzzy scoring.
    public var freeText: String { terms.joined(separator: " ") }

    public static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> SearchQuery {
        var query = SearchQuery()
        for token in tokenize(text) {
            if !token.quoted, let colon = token.text.firstIndex(of: ":") {
                let key = token.text[..<colon].lowercased()
                let value = String(token.text[token.text.index(after: colon)...])
                if query.apply(key: key, value: value, now: now, calendar: calendar) {
                    query.filters.append(Filter(key: key, value: value, range: token.range))
                    continue
                }
            }
            if !token.text.isEmpty {
                query.terms.append(token.text)
            }
        }
        return query
    }

    /// Returns `text` with one filter token removed, for the chip's close button.
    public static func removing(_ filter: Filter, from text: String) -> String {
        guard filter.range.upperBound <= text.endIndex else { return text }
        var result = text
        result.removeSubrange(filter.range)
        return result.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            + (text.hasSuffix(" ") ? " " : "")
    }

    private mutating func apply(key: String, value: String, now: Date, calendar: Calendar) -> Bool {
        switch key {
        case "type", "kind", "is":
            guard let kind = ContentKind(searchToken: value) else { return false }
            kinds.insert(kind)
        case "app", "from":
            guard !value.isEmpty else { return false }
            apps.append(value)
        case "after", "since":
            guard let date = Self.parseDate(value, now: now, calendar: calendar) else { return false }
            after = date
        case "before", "until":
            guard let date = Self.parseDate(value, now: now, calendar: calendar) else { return false }
            before = date
        case "pinned", "pin", "board":
            pinned = value.isEmpty ? .anyBoard : .board(value)
        default:
            return false
        }
        return true
    }

    /// Accepts ISO dates (`2026-10-01`), `today`, `yesterday`, and relative spans (`3d`, `2w`, `1m`, `1y`, `12h`).
    static func parseDate(_ value: String, now: Date, calendar: Calendar) -> Date? {
        let lower = value.lowercased()
        switch lower {
        case "today": return calendar.startOfDay(for: now)
        case "yesterday": return calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))
        default: break
        }
        if let unit = lower.last, let amount = Int(lower.dropLast()), amount >= 0 {
            let component: Calendar.Component? = switch unit {
            case "h": .hour
            case "d": .day
            case "w": .weekOfYear
            case "m": .month
            case "y": .year
            default: nil
            }
            if let component {
                return calendar.date(byAdding: component, value: -amount, to: now)
            }
        }
        let parts = lower.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private struct Token {
        var text: String
        var range: Range<String.Index>
        var quoted: Bool
    }

    /// Splits on whitespace, keeping `"quoted phrases"` together.
    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var index = text.startIndex
        while index < text.endIndex {
            if text[index].isWhitespace {
                index = text.index(after: index)
                continue
            }
            let start = index
            if text[index] == "\"" {
                let contentStart = text.index(after: index)
                let close = text[contentStart...].firstIndex(of: "\"")
                let contentEnd = close ?? text.endIndex
                let end = close.map { text.index(after: $0) } ?? text.endIndex
                tokens.append(Token(text: String(text[contentStart..<contentEnd]), range: start..<end, quoted: true))
                index = end
            } else {
                while index < text.endIndex, !text[index].isWhitespace {
                    index = text.index(after: index)
                }
                tokens.append(Token(text: String(text[start..<index]), range: start..<index, quoted: false))
            }
        }
        return tokens
    }
}
