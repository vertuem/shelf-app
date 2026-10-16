import Foundation

/// A small subsequence scorer for ranking search results. No external library.
///
/// Every query character must appear in order in the candidate. Matches score
/// higher when they are contiguous, start a word, or come early in the text.
/// Returns nil when the query is not a subsequence of the candidate.
public enum FuzzyScorer {
    public static func score(_ query: String, in candidate: String) -> Double? {
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return 0 }
        let haystack = Array(candidate.lowercased())
        guard haystack.count >= needle.count else { return nil }

        // Exact substring is the best case and the common one.
        if let range = candidate.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
            let offset = candidate.distance(from: candidate.startIndex, to: range.lowerBound)
            let atBoundary = offset == 0 || isBoundary(haystack, offset)
            let position = 1.0 / (1.0 + Double(offset) / 40.0)
            return 0.6 + (atBoundary ? 0.25 : 0.1) + 0.15 * position
        }

        var score = 0.0
        var needleIndex = 0
        var previousMatch: Int?
        var firstMatch: Int?
        for (index, character) in haystack.enumerated() where needleIndex < needle.count {
            guard character == needle[needleIndex] else { continue }
            var bonus = 1.0
            if let previousMatch, previousMatch == index - 1 { bonus += 1.5 }
            if isBoundary(haystack, index) { bonus += 1.0 }
            score += bonus
            firstMatch = firstMatch ?? index
            previousMatch = index
            needleIndex += 1
        }
        guard needleIndex == needle.count else { return nil }

        let maximum = Double(needle.count) * 3.5
        let compactness = Double(needle.count) / Double(max(needle.count, (previousMatch ?? 0) - (firstMatch ?? 0) + 1))
        let position = 1.0 / (1.0 + Double(firstMatch ?? 0) / 40.0)
        // Capped at 0.5 so any substring match (0.6 and up) ranks above any scattered one.
        return 0.3 * (score / maximum) + 0.1 * compactness + 0.1 * position
    }

    private static func isBoundary(_ text: [Character], _ index: Int) -> Bool {
        guard index > 0, index <= text.count else { return true }
        let previous = text[index - 1]
        return previous.isWhitespace || previous.isPunctuation || previous == "/" || previous == "_" || previous == "-"
    }
}
