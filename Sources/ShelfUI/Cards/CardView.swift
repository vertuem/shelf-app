import AppKit
import ShelfCore
import SwiftUI

/// One card: a colored header with the kind (or the item's title) and time, a
/// body laid out per kind, and a centered footer. Images and colors fill the
/// card edge to edge with a pill for their dimensions or hex value.
///
/// 200 by 220 points, 16 point corners. Content, not controls, so no glass
/// (Apple: Liquid Glass is for the navigation layer). One soft shadow lifts the
/// card off the shelf; no blur, so a strip of hundreds stays cheap to scroll.
struct CardView: View {
    let item: ClipItem
    let isSelected: Bool
    let now: Date
    var isHovered = false
    var quickPasteNumber: Int?
    var quickPasteSymbol = "⌘"
    var boardNames: [String] = []
    /// Search terms to mark in the body, so a result shows why it matched.
    var highlightTerms: [String] = []
    /// ⌘R: the header shows a text field for the item's title.
    var isRenaming = false
    var onRename: (String?) -> Void = { _ in }
    let thumbnails: ThumbnailCache
    var richText: RichTextCache?

    static let size = CGSize(width: 200, height: 220)
    static let headerHeight: CGFloat = 48
    static let footerHeight: CGFloat = 24

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var scale: CGFloat { ShelfAppearance.textScale }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 16, style: .continuous) }
    /// Images and colors fill the body; their details sit in an overlay pill instead of a footer.
    private var fillsBody: Bool { item.kind == .image && item.hasThumbnail || item.kind == .color }

    var body: some View {
        VStack(spacing: 0) {
            CardHeader(item: item, now: now, isRenaming: isRenaming, onRename: onRename)
            CardBody(item: item, thumbnails: thumbnails, richText: richText, highlightTerms: highlightTerms, fillsBody: fillsBody)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
            if !fillsBody {
                footer
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Self.bodyColor(colorScheme))
        .clipShape(shape)
        .overlay(shape.strokeBorder(borderColor, lineWidth: contrast == .increased ? 2 : 1))
        .overlay(shape.strokeBorder(Color.accentColor, lineWidth: 2.5).opacity(isSelected ? 1 : 0))
        .overlay(alignment: .bottomTrailing) { quickPasteBadge }
        .shadow(color: shadowColor, radius: shadowRadius, y: isSelected ? 0 : (isHovered ? 5 : 3))
        .scaleEffect(isSelected && !reduceMotion ? 1.02 : 1)
        // A hovered card lifts a little, so mouse users see it responds.
        .offset(y: isHovered && !isSelected && !reduceMotion ? -2 : 0)
        .animation(.easeOut(duration: 0.1), value: isSelected)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .contentShape(shape)
    }

    private var shadowColor: Color {
        if isSelected { return Color.accentColor.opacity(0.35) }
        let base = colorScheme == .dark ? 0.35 : 0.12
        return .black.opacity(isHovered ? base + 0.08 : base)
    }

    private var shadowRadius: CGFloat {
        if isSelected { return 10 }
        return isHovered ? 10 : 6
    }

    /// Opaque in both appearances: a translucent card over glass looks muddy.
    static func bodyColor(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(white: 0.17) : .white
    }

    private var borderColor: Color {
        contrast == .increased ? Color.primary.opacity(0.6) : Color.primary.opacity(colorScheme == .dark ? 0.18 : 0.1)
    }

    /// Centered, with any badges at the trailing edge.
    private var footer: some View {
        ZStack {
            Text(Formatters.footer(for: item))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 28)
            HStack(spacing: 4) {
                Spacer(minLength: 0)
                badges
            }
            .padding(.horizontal, 10)
        }
        .font(.system(size: 11 * scale))
        .foregroundStyle(.secondary)
        .frame(height: Self.footerHeight)
    }

    @ViewBuilder
    private var badges: some View {
        if !boardNames.isEmpty {
            Label(boardNames.joined(separator: ", "), systemImage: "pin.fill")
                .labelStyle(.iconOnly)
                .help(boardNames.joined(separator: ", "))
                .accessibilityLabel(String(localized: "Pinned to \(boardNames.joined(separator: ", "))"))
        }
        if item.oversized {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .help(String(localized: "Too large to keep in full. Only a preview was stored."))
        }
        if item.missingFiles {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .help(String(localized: "The file no longer exists. Pasting inserts its path."))
        }
    }

    @ViewBuilder
    private var quickPasteBadge: some View {
        if let quickPasteNumber {
            Text("\(quickPasteSymbol)\(quickPasteNumber)")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .shelfGlass(in: Capsule())
                .padding(8)
        }
    }
}

/// The kind, or the title the user gave the item, with the time below, and the
/// source app's icon as a tile at the trailing edge.
struct CardHeader: View {
    let item: ClipItem
    let now: Date
    var isRenaming = false
    var onRename: (String?) -> Void = { _ in }
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.cardColorsFromApp) private var colorsFromApp
    @State private var draft = ""
    @FocusState private var draftFocused: Bool

    var body: some View {
        let scale = ShelfAppearance.textScale
        let palette = item.palette(fromApp: colorsFromApp)
        let textColor: Color = palette.darkText ? .black : .white
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                if isRenaming {
                    TextField(item.kind.displayName, text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13 * scale, weight: .bold))
                        .focused($draftFocused)
                        .onSubmit { onRename(draft) }
                        .onAppear {
                            draft = item.title ?? ""
                            draftFocused = true
                        }
                        .onChange(of: draftFocused) { _, focused in
                            if !focused { onRename(draft) }
                        }
                        .accessibilityLabel(String(localized: "Title"))
                } else {
                    Text(item.title ?? item.kind.displayName)
                        .font(.system(size: 13 * scale, weight: .bold))
                }
                Text(Formatters.relativeTime(item.lastUsedAt, now: now))
                    .font(.system(size: 11 * scale))
                    .opacity(contrast == .increased ? 1 : 0.85)
            }
            .foregroundStyle(textColor)
            .lineLimit(1)
            Spacer(minLength: 0)
            SourceIcon(bundleID: item.sourceBundleID)
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: CardView.headerHeight)
        .background(palette.header.gradient)
    }
}

/// The source app's icon, 36 points, as a tile with a soft shadow. macOS icons
/// carry their own shape, so no outline is drawn around them.
struct SourceIcon: View {
    let bundleID: String?

    var body: some View {
        if let icon = AppIcons.icon(for: bundleID) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 36, height: 36)
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                .accessibilityHidden(true)
        }
    }
}

struct CardBody: View {
    let item: ClipItem
    let thumbnails: ThumbnailCache
    var richText: RichTextCache?
    var highlightTerms: [String] = []
    var fillsBody = false
    @State private var thumbnail: NSImage?
    @State private var rich: AttributedString?

    static var bodyHeight: CGFloat { CardView.size.height - CardView.headerHeight - CardView.footerHeight }

    var body: some View {
        let scale = ShelfAppearance.textScale
        // Cached thumbnails show on the first frame; the task only loads misses.
        let thumbnail = self.thumbnail ?? (item.hasThumbnail ? thumbnails.cached(item.id) : nil)
        Group {
            switch item.kind {
            case .text, .other:
                if item.preview.isEmpty, item.kind == .other {
                    placeholder(symbol: item.kind.symbol, text: String(localized: "No preview"))
                } else if item.prefersMonospace {
                    // Code from an editor or terminal: monospace with light syntax colors.
                    Text(CodeHighlighter.attributed(item.preview, searchTerms: highlightTerms))
                        .font(.system(size: 11 * scale, design: .monospaced))
                        .lineLimit(9)
                        .padding(12)
                } else {
                    TextBody(preview: item.preview, highlightTerms: highlightTerms)
                }
            case .richText:
                if let rich = rich ?? richText?.cached(item.id) {
                    Text(marked(rich))
                        .lineLimit(8)
                        .padding(12)
                } else {
                    TextBody(preview: item.preview, highlightTerms: highlightTerms)
                }
            case .image:
                if let thumbnail {
                    // Edge to edge, with the dimensions in a pill, like a photo in a frame.
                    Image(nsImage: thumbnail)
                        .resizable()
                        .interpolation(.medium)
                        .scaledToFill()
                        .frame(width: CardView.size.width, height: fillsBody ? Self.bodyHeight + CardView.footerHeight : Self.bodyHeight)
                        .clipped()
                        .overlay(alignment: .bottom) { pill(Formatters.footer(for: item)) }
                        .overlay(alignment: .bottomTrailing) {
                            if item.ocrText != nil {
                                Image(systemName: "text.viewfinder")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(6)
                                    .background(.black.opacity(0.45), in: Circle())
                                    .padding(8)
                                    .help(String(localized: "Text in this image is searchable"))
                                    .accessibilityLabel(String(localized: "Contains recognized text"))
                            }
                        }
                } else {
                    placeholder(symbol: "photo", text: nil)
                }
            case .link:
                LinkBody(item: item, thumbnail: thumbnail, highlightTerms: highlightTerms)
            case .file:
                FileBody(item: item, thumbnail: thumbnail, highlightTerms: highlightTerms)
            case .color:
                let color = item.colorHex.flatMap(Color.init(hex:)) ?? .gray
                color
                    .frame(width: CardView.size.width, height: Self.bodyHeight + CardView.footerHeight)
                    .overlay(alignment: .bottom) {
                        pill(item.colorHex ?? "", detail: Formatters.footer(for: item), monospaced: true)
                    }
            case .audio:
                AudioBody(item: item, thumbnail: thumbnail)
            }
        }
        .task(id: item.hasThumbnail ? item.id : nil) {
            guard item.hasThumbnail, thumbnails.cached(item.id) == nil else { return }
            self.thumbnail = await thumbnails.image(for: item.id)
        }
        .task(id: item.kind == .richText ? item.id : nil) {
            guard item.kind == .richText, let richText, richText.cached(item.id) == nil else { return }
            rich = await richText.text(for: item.id)
        }
    }

    private func marked(_ text: AttributedString) -> AttributedString {
        var result = text
        Highlighter.mark(highlightTerms, in: &result, text: String(text.characters))
        return result
    }

    /// A translucent capsule over an image or color, white text on a dark fill.
    private func pill(_ text: String, detail: String? = nil, monospaced: Bool = false) -> some View {
        VStack(spacing: 1) {
            Text(text)
                .font(.system(size: 11 * ShelfAppearance.textScale, weight: .semibold, design: monospaced ? .monospaced : .default))
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 9 * ShelfAppearance.textScale, weight: .medium))
                    .opacity(0.85)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(.black.opacity(0.5), in: Capsule())
        .padding(.bottom, 10)
    }

    private func placeholder(symbol: String, text: String?) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
            if let text {
                Text(text)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(12)
    }
}

/// Plain text: a short first line reads as a heading, the rest as body.
struct TextBody: View {
    let preview: String
    var highlightTerms: [String] = []

    var body: some View {
        let scale = ShelfAppearance.textScale
        let (title, text) = Highlighter.titleAndBody(of: preview)
        VStack(alignment: .leading, spacing: 4) {
            if let title {
                Text(Highlighter.attributed(title, terms: highlightTerms))
                    .font(.system(size: 12.5 * scale, weight: .semibold))
                    .lineLimit(2)
            }
            Text(Highlighter.attributed(text, terms: highlightTerms))
                .font(.system(size: 12 * scale))
                .foregroundStyle(title == nil ? .primary : .secondary)
                .lineLimit(title == nil ? 8 : 6)
        }
        .padding(12)
    }
}

/// A link: the page image across the top (or a tinted band with a globe), then
/// the title and the address at the bottom.
struct LinkBody: View {
    let item: ClipItem
    let thumbnail: NSImage?
    var highlightTerms: [String] = []
    @Environment(\.cardColorsFromApp) private var colorsFromApp
    private var accent: Color { item.palette(fromApp: colorsFromApp).header }

    var body: some View {
        let scale = ShelfAppearance.textScale
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        LinearGradient(colors: [accent.opacity(0.22), accent.opacity(0.06)], startPoint: .top, endPoint: .bottom)
                        Image(systemName: "globe")
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(accent)
                    }
                }
            }
            .frame(width: CardView.size.width, height: 86)
            .clipped()
            VStack(alignment: .leading, spacing: 3) {
                Text(Highlighter.attributed(item.linkTitle ?? item.host ?? item.preview, terms: highlightTerms))
                    .font(.system(size: 12 * scale, weight: .semibold))
                    .lineLimit(2)
                Text(Highlighter.attributed(item.url ?? item.preview, terms: highlightTerms))
                    .font(.system(size: 11 * scale))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            Spacer(minLength: 0)
        }
    }
}

/// A file: a large Quick Look thumbnail or icon, with the name below.
struct FileBody: View {
    let item: ClipItem
    let thumbnail: NSImage?
    var highlightTerms: [String] = []

    var body: some View {
        VStack(spacing: 8) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                } else if let path = item.filePaths.first {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().scaledToFit()
                } else {
                    Image(systemName: "doc.badge.clock").resizable().scaledToFit().foregroundStyle(.secondary)
                }
            }
            .frame(width: 84, height: 84)
            Text(Highlighter.attributed(title, terms: highlightTerms))
                .font(.system(size: 12 * ShelfAppearance.textScale, weight: .medium))
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(12)
    }

    private var title: String {
        guard let first = item.filePaths.first else { return item.preview }
        let name = (first as NSString).lastPathComponent
        let others = item.filePaths.count - 1
        return others > 0 ? String(localized: "\(name) and \(others) more") : name
    }
}

/// Audio: artwork when the copy carried one, otherwise a waveform on a tinted tile.
struct AudioBody: View {
    let item: ClipItem
    let thumbnail: NSImage?
    @Environment(\.cardColorsFromApp) private var colorsFromApp
    private var accent: Color { item.palette(fromApp: colorsFromApp).header }

    var body: some View {
        VStack(spacing: 10) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().scaledToFill()
                } else {
                    ZStack {
                        accent.opacity(0.18)
                        Image(systemName: "waveform")
                            .font(.system(size: 34, weight: .light))
                            .foregroundStyle(accent)
                    }
                }
            }
            .frame(width: 84, height: 84)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
            if !item.preview.isEmpty {
                Text(item.preview)
                    .font(.system(size: 12 * ShelfAppearance.textScale, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(12)
    }
}
