import Foundation

/// Builds the stored preview: at most 500 characters, whitespace normalized.
///
/// Line breaks survive (text cards show up to eight lines) but runs of blank
/// lines collapse to one, tabs and runs of spaces collapse to one space, and
/// leading and trailing whitespace is trimmed.
public enum TextPreview {
    public static let maxCharacters = 500

    public static func make(_ text: String) -> String {
        var lines: [String] = []
        var blankRun = 0
        // Scan at most a generous prefix; a 50 MB string should not be split in full.
        let head = text.prefix(maxCharacters * 8)
        for rawLine in head.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\u{00A0}" })
                .joined(separator: " ")
            if line.isEmpty {
                blankRun += 1
                if blankRun == 1, !lines.isEmpty { lines.append("") }
            } else {
                blankRun = 0
                lines.append(line)
            }
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return String(lines.joined(separator: "\n").prefix(maxCharacters))
    }

    /// A crude but main-thread-free HTML to text conversion for previews.
    /// Pasting always uses the stored HTML, never this text.
    public static func stripHTML(_ html: String) -> String {
        var text = html
        for pattern in ["(?is)<(script|style|head)[^>]*>.*?</\\1>", "(?i)<br\\s*/?>", "(?i)</(p|div|li|tr|h[1-6])>"] {
            let replacement = pattern.contains("br") || pattern.contains("/(p") ? "\n" : ""
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'"]
        for (entity, value) in entities {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        return text
    }
}
