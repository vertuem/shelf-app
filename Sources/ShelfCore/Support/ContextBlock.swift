import Foundation

/// One text document from several cards, for pasting into an AI chat ("Copy
/// for AI"): a header with the count and time span, then each card oldest first
/// with its kind, source app and time. Cards without a textual form are listed
/// by their metadata only.
public enum ContextBlock {
    public struct Entry: Sendable {
        public var item: ClipItem
        public var text: String?

        public init(item: ClipItem, text: String?) {
            self.item = item
            self.text = text
        }
    }

    public static func make(_ entries: [Entry], title: String? = nil, now: Date = Date()) -> String {
        let ordered = entries.sorted { $0.item.lastUsedAt < $1.item.lastUsedAt }
        let dates = ordered.map(\.item.lastUsedAt)
        var lines: [String] = []
        let heading = title.map { "\(Brand.name): \($0)" } ?? Brand.name
        lines.append("# \(heading), \(ordered.count) \(ordered.count == 1 ? "item" : "items")")
        if let first = dates.first, let last = dates.last {
            let span = first == last ? stamp(first) : "\(stamp(first)) to \(stamp(last))"
            lines.append("Copied \(span). Exported \(stamp(now)).")
        }
        for (index, entry) in ordered.enumerated() {
            let item = entry.item
            lines.append("")
            var header = "## \(index + 1). \(item.title ?? item.kind.displayName)"
            if item.title != nil { header += " (\(item.kind.displayName))" }
            lines.append(header)
            var meta: [String] = []
            if let app = item.sourceAppName { meta.append("From \(app)") }
            meta.append(stamp(item.lastUsedAt))
            if item.kind == .image, let width = item.width, let height = item.height { meta.append("\(width) × \(height)") }
            if item.kind == .file, !item.filePaths.isEmpty { meta.append(item.filePaths.joined(separator: ", ")) }
            lines.append(meta.joined(separator: " · "))
            lines.append("")
            if let text = entry.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                lines.append(item.prefersMonospace ? "```\n\(text)\n```" : text)
            } else if let ocr = item.ocrText, !ocr.isEmpty {
                lines.append("Text recognized in the image:")
                lines.append(ocr)
            } else {
                lines.append("(no text)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func stamp(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
