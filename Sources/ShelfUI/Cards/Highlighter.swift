import ShelfCore
import SwiftUI

/// Marks the search terms inside a card's text, so a result shows why it matched.
enum Highlighter {
    /// Every case- and diacritic-insensitive occurrence of each term is drawn
    /// bold in the accent color. Text without a match comes back unchanged.
    static func attributed(_ text: String, terms: [String]) -> AttributedString {
        var result = AttributedString(text)
        mark(terms, in: &result, text: text)
        return result
    }

    /// Marks the terms in an already-styled string (code colors, rich text).
    static func mark(_ terms: [String], in result: inout AttributedString, text: String) {
        guard !terms.isEmpty, !text.isEmpty else { return }
        for term in terms where !term.isEmpty {
            var searchRange = text.startIndex..<text.endIndex
            while let found = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange) {
                if let lower = AttributedString.Index(found.lowerBound, within: result),
                   let upper = AttributedString.Index(found.upperBound, within: result) {
                    result[lower..<upper].foregroundColor = .accentColor
                    result[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
                }
                searchRange = found.upperBound..<text.endIndex
            }
        }
    }

    /// Splits a text preview into a title line and the rest:
    /// a short first line followed by more text reads as a heading.
    static func titleAndBody(of preview: String) -> (title: String?, body: String) {
        guard let newline = preview.firstIndex(of: "\n") else { return (nil, preview) }
        let first = preview[..<newline].trimmingCharacters(in: .whitespaces)
        let rest = preview[preview.index(after: newline)...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...60).contains(first.count), !rest.isEmpty, !first.hasSuffix(",") else { return (nil, preview) }
        return (first, rest)
    }
}
