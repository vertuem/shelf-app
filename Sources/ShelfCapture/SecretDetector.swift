import Foundation

/// The optional "Detect secrets" heuristic. Off by default because it also
/// flags harmless things like commit hashes.
///
/// Flags a single token of 20 to 64 characters with no spaces and high
/// Shannon entropy, plus a few unmistakable key prefixes of any length.
public enum SecretDetector {
    static let knownPrefixes = [
        "sk-", "sk_live_", "sk_test_", "rk_live_", "ghp_", "gho_", "ghu_", "ghs_", "github_pat_",
        "glpat-", "xoxb-", "xoxp-", "xoxa-", "AKIA", "ASIA", "AIza", "ya29.", "npm_", "pypi-",
    ]

    public static func looksLikeSecret(_ text: String) -> Bool {
        let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.contains(where: \.isWhitespace) else { return false }
        if candidate.count >= 16, knownPrefixes.contains(where: { candidate.hasPrefix($0) }) {
            return true
        }
        guard (20...64).contains(candidate.count) else { return false }
        if candidate.contains("://") || candidate.contains("@") && candidate.contains(".") { return false }
        if candidate.allSatisfy({ $0.isLetter }) { return false } // a long word, not a key

        let classes = [
            candidate.contains(where: \.isLowercase),
            candidate.contains(where: \.isUppercase),
            candidate.contains(where: \.isNumber),
            candidate.contains(where: { !$0.isLetter && !$0.isNumber }),
        ].filter { $0 }.count
        guard classes >= 2 else { return false }
        return entropy(candidate) >= 3.5
    }

    /// Shannon entropy in bits per character.
    static func entropy(_ text: String) -> Double {
        var counts: [Character: Int] = [:]
        for character in text { counts[character, default: 0] += 1 }
        let length = Double(text.count)
        return counts.values.reduce(0) { total, count in
            let probability = Double(count) / length
            return total - probability * log2(probability)
        }
    }
}
