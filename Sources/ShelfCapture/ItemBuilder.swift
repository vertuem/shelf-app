import AppKit
import CryptoKit
import ShelfCore

/// The app a copy came from.
public struct SourceApp: Sendable, Equatable {
    public var bundleID: String?
    public var name: String?

    public init(bundleID: String?, name: String?) {
        self.bundleID = bundleID
        self.name = name
    }
}

/// Steps 6 to 8 of the capture flow: size check, hash, classification and
/// metadata extraction. Pure apart from reading file existence, so every
/// fixture test runs it directly.
public enum ItemBuilder {
    /// Types up to this size are still stored for oversized items, so a 20 MB
    /// image copied from a web page keeps its URL and name.
    public static let oversizedKeepLimit = 256 * 1_024

    public static func build(
        from snapshot: PasteboardSnapshot,
        source: SourceApp,
        maxItemBytes: Int,
        now: Date = Date()
    ) -> CapturedItem {
        let kind = Classifier.classify(snapshot)
        let byteSize = snapshot.byteSize
        let oversized = byteSize > maxItemBytes || !snapshot.skippedTypes.isEmpty
        let stored = oversized
            ? snapshot.representations.filter { $0.data.count <= oversizedKeepLimit }
            : snapshot.representations

        var item = CapturedItem(
            capturedAt: now,
            kind: kind,
            sourceBundleID: source.bundleID,
            sourceAppName: source.name,
            hash: hash(of: snapshot),
            byteSize: byteSize,
            oversized: oversized,
            promised: !snapshot.promisedTypes.isEmpty,
            representations: stored
        )

        let text = snapshot.plainText ?? ""
        switch kind {
        case .text:
            item.preview = TextPreview.make(text)
        case .richText:
            item.preview = TextPreview.make(text.isEmpty ? richTextFallback(snapshot) : text)
        case .link:
            let url = linkURL(in: snapshot, text: text)
            item.url = url
            item.preview = TextPreview.make(url ?? text)
        case .file:
            item.filePaths = filePaths(in: snapshot)
            item.preview = item.filePaths.isEmpty
                ? String(localized: "Pending file")
                : TextPreview.make(item.filePaths.map { ($0 as NSString).lastPathComponent }.joined(separator: "\n"))
        case .color:
            item.colorHex = colorHex(in: snapshot)
            item.preview = item.colorHex ?? ""
        case .image:
            if let data = bestImageData(in: snapshot) {
                if let info = Thumbnailer.info(of: data) {
                    item.width = info.width
                    item.height = info.height
                }
                item.thumbnail = Thumbnailer.thumbnail(of: data)
            }
            item.preview = TextPreview.make(text)
        case .audio, .other:
            item.preview = TextPreview.make(text)
        }
        return item
    }

    /// SHA-256 over every type identifier and its bytes, item by item.
    public static func hash(of snapshot: PasteboardSnapshot) -> Data {
        var hasher = SHA256()
        for representation in snapshot.representations {
            hasher.update(data: Data("\(representation.itemIndex):\(representation.uti)\u{0}".utf8))
            withUnsafeBytes(of: UInt64(representation.data.count).littleEndian) { hasher.update(bufferPointer: $0) }
            hasher.update(data: representation.data)
        }
        for promised in snapshot.promisedTypes {
            hasher.update(data: Data("promise:\(promised)\u{0}".utf8))
        }
        for skipped in snapshot.skippedTypes {
            hasher.update(data: Data("skipped:\(skipped)\u{0}".utf8))
        }
        return Data(hasher.finalize())
    }

    static func bestImageData(in snapshot: PasteboardSnapshot) -> Data? {
        for type in [PasteboardTypes.png, PasteboardTypes.heic, PasteboardTypes.jpeg, PasteboardTypes.tiff] {
            if let data = snapshot.data(for: type) { return data }
        }
        return snapshot.representations.first { Classifier.hasImage([$0.uti]) }?.data
    }

    static func linkURL(in snapshot: PasteboardSnapshot, text: String) -> String? {
        if let data = snapshot.data(for: PasteboardTypes.url),
           let string = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !string.isEmpty {
            return string
        }
        return Classifier.singleURL(in: text)?.absoluteString
    }

    static func filePaths(in snapshot: PasteboardSnapshot) -> [String] {
        snapshot.allData(for: PasteboardTypes.fileURL).compactMap { data in
            guard let string = String(data: data, encoding: .utf8), let url = URL(string: string) else { return nil }
            // Finder sometimes writes file reference URLs (file:///.file/id=…); resolve them to paths.
            return ((url as NSURL).filePathURL ?? url).path
        }
    }

    static func colorHex(in snapshot: PasteboardSnapshot) -> String? {
        if let data = snapshot.data(for: PasteboardTypes.color),
           let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data),
           let rgb = color.usingColorSpace(.sRGB) {
            let components = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
                .map { String(format: "%02X", Int(($0 * 255).rounded()).clamped(to: 0...255)) }
            let alpha = rgb.alphaComponent < 1 ? String(format: "%02X", Int((rgb.alphaComponent * 255).rounded())) : ""
            return "#" + components.joined() + alpha
        }
        return Classifier.hexColor(in: snapshot.plainText ?? "")
    }

    /// Plain text for rich text items that came without a plain-text type.
    static func richTextFallback(_ snapshot: PasteboardSnapshot) -> String {
        if let rtf = snapshot.data(for: PasteboardTypes.rtf),
           let string = NSAttributedString(rtf: rtf, documentAttributes: nil)?.string {
            return string
        }
        if let rtfd = snapshot.data(for: PasteboardTypes.rtfd),
           let string = NSAttributedString(rtfd: rtfd, documentAttributes: nil)?.string {
            return string
        }
        if let html = snapshot.data(for: PasteboardTypes.html), let string = String(data: html, encoding: .utf8) {
            return TextPreview.stripHTML(string)
        }
        return ""
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
