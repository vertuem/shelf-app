import AppKit
import ShelfCore

/// Decoded thumbnails, at most 200, least recently used evicted first.
/// Thumbnails are capped at 512 px, so the cache stays within a few MB.
@MainActor
public final class ThumbnailCache {
    public static let capacity = 200
    private var images: [UUID: NSImage] = [:]
    private var order: [UUID] = []
    private let load: @Sendable (UUID) -> Data?

    public init(load: @escaping @Sendable (UUID) -> Data?) {
        self.load = load
    }

    public func cached(_ id: UUID) -> NSImage? {
        guard let image = images[id] else { return nil }
        touch(id)
        return image
    }

    /// Loads off the main thread, then caches.
    public func image(for id: UUID) async -> NSImage? {
        if let cached = cached(id) { return cached }
        let load = self.load
        let data = await Task.detached(priority: .userInitiated) { load(id) }.value
        guard let data, let image = NSImage(data: data) else { return nil }
        insert(image, for: id)
        return image
    }

    public func preload(_ ids: [UUID]) async {
        for id in ids.prefix(40) where images[id] == nil {
            _ = await image(for: id)
        }
    }

    public func remove(_ id: UUID) {
        images[id] = nil
        order.removeAll { $0 == id }
    }

    private func insert(_ image: NSImage, for id: UUID) {
        images[id] = image
        touch(id)
        while order.count > Self.capacity {
            images[order.removeFirst()] = nil
        }
    }

    private func touch(_ id: UUID) {
        order.removeAll { $0 == id }
        order.append(id)
    }
}

/// App icons by bundle id, for the card headers.
@MainActor
public enum AppIcons {
    private static var cache: [String: NSImage] = [:]
    private static var accents: [String: NSColor?] = [:]

    /// The icon's main color, for the card header. Nil
    /// when the app is unknown; a gray for icons without a real color.
    public static func accentColor(for bundleID: String?) -> NSColor? {
        guard let bundleID else { return nil }
        if let cached = accents[bundleID] { return cached }
        let accent = (originalIcon(for: bundleID) ?? icon(for: bundleID)).flatMap(dominantColor(of:))
        accents[bundleID] = accent
        return accent
    }

    /// The icon file inside the app, in its own colors. The icon macOS 26 hands
    /// out follows the user's icon style, which can be tinted or clear: gray.
    static func originalIcon(for bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              let bundle = Bundle(url: url) else { return nil }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String) ?? "AppIcon"
        let base = name.hasSuffix(".icns") ? String(name.dropLast(5)) : name
        return bundle.path(forResource: base, ofType: "icns").flatMap(NSImage.init(contentsOfFile:))
    }

    /// The most common strong hue in a small rendering of the image. Near-white,
    /// near-black and gray pixels are ignored, so an icon's white or dark plate
    /// does not win over its color. An icon that is gray throughout gets its
    /// average gray. Kept between dark and light so header text stays legible.
    static func dominantColor(of image: NSImage) -> NSColor? {
        let side = 32
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()

        let bins = 24
        var weights = [Double](repeating: 0, count: bins)
        var sums = [(Double, Double, Double)](repeating: (0, 0, 0), count: bins)
        var opaque = 0.0
        var gray = (0.0, 0.0, 0.0)
        for y in 0..<side {
            for x in 0..<side {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.5 else { continue }
                let (red, green, blue) = (Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent))
                opaque += 1
                gray = (gray.0 + red, gray.1 + green, gray.2 + blue)
                let saturation = Double(color.saturationComponent), brightness = Double(color.brightnessComponent)
                guard saturation > 0.25, brightness > 0.2 else { continue }
                let bin = min(bins - 1, Int(Double(color.hueComponent) * Double(bins)))
                let weight = saturation * brightness
                weights[bin] += weight
                sums[bin] = (sums[bin].0 + red * weight, sums[bin].1 + green * weight, sums[bin].2 + blue * weight)
            }
        }
        guard opaque > 0 else { return nil }
        let colorful = weights.reduce(0, +)
        let result: NSColor
        if colorful / opaque < 0.08 {
            result = NSColor(srgbRed: gray.0 / opaque, green: gray.1 / opaque, blue: gray.2 / opaque, alpha: 1)
        } else {
            // The strongest bin with its neighbors, so a hue split across a bin edge still wins.
            let best = (0..<bins).max { neighborhood(weights, $0) < neighborhood(weights, $1) } ?? 0
            var total = 0.0
            var rgb = (0.0, 0.0, 0.0)
            for offset in -1...1 {
                let bin = (best + offset + bins) % bins
                total += weights[bin]
                rgb = (rgb.0 + sums[bin].0, rgb.1 + sums[bin].1, rgb.2 + sums[bin].2)
            }
            result = NSColor(srgbRed: rgb.0 / total, green: rgb.1 / total, blue: rgb.2 / total, alpha: 1)
        }
        let brightness = min(max(result.brightnessComponent, 0.32), 0.92)
        return NSColor(hue: result.hueComponent, saturation: min(result.saturationComponent, 0.85), brightness: brightness, alpha: 1)
    }

    private static func neighborhood(_ weights: [Double], _ bin: Int) -> Double {
        let count = weights.count
        return weights[(bin - 1 + count) % count] + weights[bin] + weights[(bin + 1) % count]
    }

    public static func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = cache[bundleID] { return cached }
        let icon: NSImage?
        if bundleID == UniversalClipboardSource.bundleID {
            icon = NSImage(systemSymbolName: "iphone.and.arrow.forward", accessibilityDescription: nil)
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            icon = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            icon = nil
        }
        cache[bundleID] = icon
        return icon
    }

    public static func appName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return Seeds.knownAppNames[bundleID] ?? bundleID
        }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}

/// Rendered rich text for cards, at most 100 entries. The RTF is decrypted and
/// parsed once per item, off the main thread, then kept as an `AttributedString`.
@MainActor
public final class RichTextCache {
    public static let capacity = 100
    private var texts: [UUID: AttributedString] = [:]
    private var misses: Set<UUID> = []
    private var order: [UUID] = []
    private let load: @Sendable (UUID) async -> AttributedString?

    public init(load: @escaping @Sendable (UUID) async -> AttributedString?) {
        self.load = load
    }

    public func cached(_ id: UUID) -> AttributedString? {
        guard let text = texts[id] else { return nil }
        touch(id)
        return text
    }

    public func text(for id: UUID) async -> AttributedString? {
        if let cached = cached(id) { return cached }
        if misses.contains(id) { return nil }
        let load = self.load
        guard let text = await Task.detached(priority: .userInitiated) { await load(id) }.value else {
            misses.insert(id)
            return nil
        }
        texts[id] = text
        touch(id)
        while order.count > Self.capacity {
            texts[order.removeFirst()] = nil
        }
        return text
    }

    public func remove(_ id: UUID) {
        texts[id] = nil
        misses.remove(id)
        order.removeAll { $0 == id }
    }

    private func touch(_ id: UUID) {
        order.removeAll { $0 == id }
        order.append(id)
    }
}

/// Turns stored RTF into card text: bold, italic, underline and strikethrough
/// survive; fonts, sizes and colors are replaced so the card matches the shelf.
public enum RichTextRenderer {
    public static func attributed(from representations: [ClipRepresentation], maxCharacters: Int = 600, pointSize: CGFloat = 12) -> AttributedString? {
        let source: NSAttributedString?
        if let rtf = representations.first(where: { $0.uti == PasteboardTypes.rtf })?.data {
            source = NSAttributedString(rtf: rtf, documentAttributes: nil)
        } else if let rtfd = representations.first(where: { $0.uti == PasteboardTypes.rtfd })?.data {
            source = NSAttributedString(rtfd: rtfd, documentAttributes: nil)
        } else {
            source = nil
        }
        guard let source, source.length > 0 else { return nil }
        let trimmed = source.attributedSubstring(from: NSRange(location: 0, length: min(source.length, maxCharacters)))
        let output = NSMutableAttributedString(string: trimmed.string)
        let base = NSFont.systemFont(ofSize: pointSize)
        output.addAttribute(.font, value: base, range: NSRange(location: 0, length: output.length))
        trimmed.enumerateAttributes(in: NSRange(location: 0, length: trimmed.length)) { attributes, range, _ in
            var font = base
            if let original = attributes[.font] as? NSFont {
                let traits = original.fontDescriptor.symbolicTraits
                let managerTraits = NSFontManager.shared.traits(of: original)
                var symbolic: NSFontDescriptor.SymbolicTraits = []
                if traits.contains(.bold) || managerTraits.contains(.boldFontMask) { symbolic.insert(.bold) }
                if traits.contains(.italic) || managerTraits.contains(.italicFontMask) { symbolic.insert(.italic) }
                if traits.contains(.monoSpace) { symbolic.insert(.monoSpace) }
                let descriptor = base.fontDescriptor.withSymbolicTraits(symbolic)
                font = NSFont(descriptor: descriptor, size: pointSize) ?? base
                // Headings keep a little of their size difference.
                if original.pointSize >= 18 { font = NSFont(descriptor: descriptor, size: pointSize + 2) ?? font }
            }
            output.addAttribute(.font, value: font, range: range)
            if let underline = attributes[.underlineStyle] { output.addAttribute(.underlineStyle, value: underline, range: range) }
            if let strike = attributes[.strikethroughStyle] { output.addAttribute(.strikethroughStyle, value: strike, range: range) }
        }
        return AttributedString(output)
    }
}
