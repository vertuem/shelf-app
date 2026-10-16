import Foundation

/// Decides when a text card reads better in a monospaced font.
public enum CodeDetector {
    /// Editors and terminals: everything copied there is code or output.
    public static let codeApps: Set = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty", "io.alacritty", "org.alacritty", "com.apple.dt.Xcode", "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.sublimetext.4",
        "com.sublimetext.3", "com.panic.Nova", "com.barebones.bbedit", "com.macromates.TextMate",
        "com.github.GitHubClient", "com.apple.dt.CommandLineTools", "com.jetbrains.intellij", "com.jetbrains.WebStorm",
        "com.jetbrains.PyCharm", "com.jetbrains.goland", "com.jetbrains.rubymine", "com.jetbrains.CLion",
        "com.jetbrains.rider", "com.jetbrains.AppCode", "com.jetbrains.PhpStorm", "com.jetbrains.datagrip",
        "com.jetbrains.fleet", "com.neovide.neovide", "org.vim.MacVim", "com.google.android.studio",
    ]

    public static func isCodeApp(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return codeApps.contains(bundleID) || bundleID.hasPrefix("com.jetbrains.")
    }

    /// Text that looks like code: braces and semicolons, indented lines, shell
    /// prompts, tags, or lines that end in the punctuation code ends in.
    public static func looksLikeCode(_ text: String) -> Bool {
        let sample = text.prefix(600)
        guard !sample.isEmpty else { return false }
        let lines = sample.split(separator: "\n", omittingEmptySubsequences: true)
        let trimmed = sample.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("#!") || trimmed.hasPrefix("$ ") || trimmed.hasPrefix("<?") || trimmed.hasPrefix("```") {
            return true
        }
        if lines.count == 1 {
            let line = trimmed
            // `git rebase -i origin/main`, `npm install --save`, `ls -la`
            let shellLike = line.range(of: #"^[a-z][\w.-]*(\s+(-{1,2}[\w-]+|[\w./~-]+))+$"#, options: .regularExpression) != nil
            // `foo(bar);`, `let x = y.z()`, `SELECT * FROM t`
            let statementLike = line.range(of: #"(\(\)|\);|=>|->|::|\{\}|\[\]|^\s*(let|var|const|def|func|fn|import|from|SELECT|INSERT|UPDATE|DELETE)\b)"#, options: .regularExpression) != nil
            return shellLike || statementLike
        }
        let indented = lines.filter { $0.hasPrefix("  ") || $0.hasPrefix("\t") }.count
        let punctuated = lines.filter { line in
            guard let last = line.last else { return false }
            return "{};()[]=>:,".contains(last)
        }.count
        let symbols = sample.filter { "{}[]();=<>".contains($0) }.count
        return Double(indented) / Double(lines.count) >= 0.3
            || Double(punctuated) / Double(lines.count) >= 0.5
            || Double(symbols) / Double(sample.count) >= 0.04
    }
}

extension ClipItem {
    /// Code from an editor or terminal, or text that looks like it, in monospace.
    public var prefersMonospace: Bool {
        guard kind == .text || kind == .other else { return false }
        return CodeDetector.isCodeApp(sourceBundleID) || CodeDetector.looksLikeCode(preview)
    }
}
