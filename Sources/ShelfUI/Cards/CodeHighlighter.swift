import SwiftUI

/// Light syntax coloring for code cards: comments, strings, numbers, keywords
/// and capitalized type names. Not a parser; regular expressions over the
/// 500-character preview, which is cheap enough to run per card.
enum CodeHighlighter {
    static let keywords: Set = [
        "let", "var", "func", "fn", "return", "if", "else", "guard", "for", "while", "in", "switch", "case", "default",
        "break", "continue", "struct", "class", "enum", "protocol", "extension", "import", "public", "private",
        "internal", "fileprivate", "static", "final", "override", "init", "deinit", "self", "Self", "super", "nil",
        "true", "false", "try", "catch", "throw", "throws", "async", "await", "actor", "some", "any", "where",
        "do", "defer", "typealias", "associatedtype", "inout", "mutating", "lazy", "weak", "unowned", "get", "set",
        "willSet", "didSet", "impl", "trait", "match", "mod", "pub", "use", "mut", "crate", "package", "type",
        "interface", "map", "chan", "go", "range", "select", "const", "void", "int", "char", "float", "double",
        "bool", "unsigned", "long", "short", "sizeof", "typedef", "include", "define", "namespace", "template",
        "new", "delete", "this", "nullptr", "null", "function", "export", "from", "yield", "of", "instanceof",
        "typeof", "undefined", "extends", "implements", "readonly", "declare", "module", "require", "def", "elif",
        "lambda", "pass", "with", "as", "not", "and", "or", "is", "None", "True", "False", "raise", "except", "finally",
        "global", "nonlocal", "assert", "del", "end", "begin", "rescue", "ensure", "unless", "until", "then", "elsif",
        "puts", "attr_accessor", "echo", "cd", "ls", "git", "npm", "yarn", "pnpm", "brew", "swift", "xcodebuild",
        "sudo", "source", "fi", "esac", "done", "exit", "curl", "cat", "grep", "sed", "awk", "rm", "cp", "mv",
        "mkdir", "docker", "kubectl", "python", "python3", "pip", "node", "cargo", "make", "SELECT", "FROM", "WHERE",
        "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE", "JOIN", "LEFT", "INNER", "ON", "GROUP", "BY", "ORDER",
        "LIMIT", "CREATE", "TABLE", "DROP", "ALTER", "AND", "OR", "NOT", "NULL", "AS", "IN", "insert", "into",
        "values", "update", "join", "order", "limit", "create", "table",
    ]

    // Fixed patterns: a typo fails the highlighter tests on the first run.
    // swiftlint:disable force_try
    private static let comment = try! NSRegularExpression(pattern: #"//[^\n]*|/\*[\s\S]*?\*/|(?m:^\s*#(?!!)[^\n]*)|--[^\n]*"#)
    private static let string = try! NSRegularExpression(pattern: #""(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'|`[^`\n]*`"#)
    private static let number = try! NSRegularExpression(pattern: #"\b\d+(?:\.\d+)?\b"#)
    private static let word = try! NSRegularExpression(pattern: #"\b[A-Za-z_][A-Za-z0-9_]*\b"#)
    // swiftlint:enable force_try

    static func attributed(_ text: String, searchTerms: [String] = []) -> AttributedString {
        var result = AttributedString(text)
        guard !text.isEmpty else { return result }
        let nsText = text as NSString
        let whole = NSRange(location: 0, length: nsText.length)
        var taken: [NSRange] = []

        func paint(_ range: NSRange, _ color: Color) {
            guard let swiftRange = Range(range, in: text),
                  let lower = AttributedString.Index(swiftRange.lowerBound, within: result),
                  let upper = AttributedString.Index(swiftRange.upperBound, within: result) else { return }
            result[lower..<upper].foregroundColor = color
        }
        func free(_ range: NSRange) -> Bool {
            !taken.contains { NSIntersectionRange($0, range).length > 0 }
        }

        for match in comment.matches(in: text, range: whole) {
            paint(match.range, .gray)
            taken.append(match.range)
        }
        for match in string.matches(in: text, range: whole) where free(match.range) {
            paint(match.range, .red)
            taken.append(match.range)
        }
        for match in number.matches(in: text, range: whole) where free(match.range) {
            paint(match.range, .blue)
        }
        for match in word.matches(in: text, range: whole) where free(match.range) {
            let token = nsText.substring(with: match.range)
            if keywords.contains(token) {
                paint(match.range, .purple)
            } else if token.count > 1, token.first?.isUppercase == true, token.dropFirst().contains(where: \.isLowercase) {
                paint(match.range, .teal)
            }
        }
        Highlighter.mark(searchTerms, in: &result, text: text)
        return result
    }
}
