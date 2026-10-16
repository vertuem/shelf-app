import AppKit
import ImageIO
import ShelfCore
import UniformTypeIdentifiers

/// The only code that writes the general pasteboard.
public enum PasteboardWriter {
    public static let marker = NSPasteboard.PasteboardType(Brand.originMarkerType)
    public static let restoredMarker = NSPasteboard.PasteboardType(Brand.restoredMarkerType)

    /// Writes stored representations back, one `NSPasteboardItem` per original
    /// item, types in their original order. The origin marker goes on the first
    /// item so the monitor skips this change.
    @discardableResult
    public static func write(
        _ representations: [ClipRepresentation],
        to pasteboard: NSPasteboard,
        marker: NSPasteboard.PasteboardType? = PasteboardWriter.marker
    ) -> Bool {
        let grouped = Dictionary(grouping: representations, by: \.itemIndex)
        let items: [NSPasteboardItem] = grouped.keys.sorted().map { index in
            let item = NSPasteboardItem()
            for representation in grouped[index] ?? [] {
                item.setData(representation.data, forType: NSPasteboard.PasteboardType(representation.uti))
            }
            return item
        }
        guard !items.isEmpty else { return false }
        if let marker {
            items[0].setData(Data(), forType: marker)
        }
        pasteboard.clearContents()
        return pasteboard.writeObjects(items)
    }

    /// Plain-text mode writes `public.utf8-plain-text` only.
    @discardableResult
    public static func writePlainText(_ text: String, to pasteboard: NSPasteboard) -> Bool {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: marker)
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }

    /// Everything currently on the pasteboard, to put back after a paste.
    public static func saveContents(of pasteboard: NSPasteboard) -> [ClipRepresentation] {
        var saved: [ClipRepresentation] = []
        for (index, item) in (pasteboard.pasteboardItems ?? []).enumerated() {
            let itemTypes = Set(item.types.map(\.rawValue))
            for type in item.types where !PasteboardTypes.isPromise(type.rawValue)
                && !PasteboardTypes.isSynthesizedAlias(type.rawValue, itemTypes: itemTypes) {
                if let data = item.data(forType: type) {
                    saved.append(ClipRepresentation(itemIndex: index, uti: type.rawValue, data: data))
                }
            }
        }
        return saved
    }

    /// Puts saved contents back with the restored marker, which the monitor
    /// skips: restoring is not a copy, and recording it would attribute the
    /// content to the paste target, bypassing the ignored-apps list.
    public static func restore(_ saved: [ClipRepresentation], to pasteboard: NSPasteboard) {
        let content = saved.filter { $0.uti != Brand.originMarkerType && $0.uti != Brand.restoredMarkerType }
        if content.isEmpty {
            pasteboard.clearContents()
        } else {
            write(content, to: pasteboard, marker: restoredMarker)
        }
    }

    /// The text to use in plain-text mode, or nil when the item has no textual form.
    public static func plainText(for item: ClipItem, representations: [ClipRepresentation]) -> String? {
        switch item.kind {
        case .file:
            return item.filePaths.isEmpty ? nil : item.filePaths.joined(separator: "\n")
        case .link:
            return item.url ?? text(in: representations)
        case .color:
            return item.colorHex ?? text(in: representations)
        case .image, .audio:
            return nil
        case .text, .richText, .other:
            return text(in: representations) ?? (item.preview.isEmpty ? nil : item.preview)
        }
    }

    static func text(in representations: [ClipRepresentation]) -> String? {
        if let data = representations.first(where: { $0.uti == PasteboardTypes.plainText })?.data {
            return String(data: data, encoding: .utf8)
        }
        if let data = representations.first(where: { $0.uti == PasteboardTypes.utf16PlainText })?.data {
            return String(data: data, encoding: .utf16)
        }
        if let rtf = representations.first(where: { $0.uti == PasteboardTypes.rtf })?.data {
            return NSAttributedString(rtf: rtf, documentAttributes: nil)?.string
        }
        if let html = representations.first(where: { $0.uti == PasteboardTypes.html })?.data,
           let string = String(data: html, encoding: .utf8) {
            return TextPreview.stripHTML(string).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    /// For oversized images nothing but the thumbnail survives; paste it as PNG.
    public static func pngRepresentation(ofThumbnail data: Data) -> ClipRepresentation? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return ClipRepresentation(uti: PasteboardTypes.png, data: output as Data)
    }
}
