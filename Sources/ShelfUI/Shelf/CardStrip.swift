import AppKit
import ShelfCore
import SwiftUI
import UniformTypeIdentifiers

/// The strip of cards: a horizontal row along the bottom, a column up a screen
/// edge, or a grid in the centered panel, depending on `model.layout`. Lazy,
/// with stable ids, so a new copy inserts one card instead of rebuilding the
/// strip. Scrolls to the selection only when the keyboard moved it.
struct CardStrip: View {
    @Bindable var model: ShelfViewModel
    let now: Date

    static let spacing: CGFloat = 16
    static let inset: CGFloat = 12

    var body: some View {
        // An empty history says so in the shelf itself; a sample card looked like
        // a real item that would not go away.
        if model.items.isEmpty && model.hasLoaded {
            EmptyStateView(model: model)
        } else {
            strip
        }
    }

    private var strip: some View {
        let numbers = Dictionary(uniqueKeysWithValues: model.items.prefix(9).enumerated().map { ($1.id, $0 + 1) })
        let quickSymbol = QuickPasteSymbol.current
        let terms = model.query.terms
        let layout = model.layout
        return ScrollViewReader { proxy in
            ScrollView(layout.isHorizontal ? .horizontal : .vertical, showsIndicators: !layout.isHorizontal) {
                Group {
                    if layout.isHorizontal {
                        LazyHStack(spacing: Self.spacing) { cards(numbers: numbers, quickSymbol: quickSymbol, terms: terms) }
                    } else {
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.fixed(CardView.size.width), spacing: Self.spacing), count: max(1, layout.columns)),
                            alignment: .leading,
                            spacing: Self.spacing
                        ) { cards(numbers: numbers, quickSymbol: quickSymbol, terms: terms) }
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(Self.inset)
                .scrollTargetLayout()
            }
            // Cards snap to the grid when the strip is flicked, so none is left half visible.
            .scrollTargetBehavior(.viewAligned(limitBehavior: .automatic))
            .background { SizeReader { model.visibleCardCount = Self.cardsThatFit(in: $0, layout: layout) } }
            .onChange(of: model.scrollTarget) { _, target in
                guard let target else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(target)
                }
            }
        }
    }

    private func cards(numbers: [UUID: Int], quickSymbol: String, terms: [String]) -> some View {
        ForEach(model.items) { item in
            InteractiveCard(
                model: model,
                item: item,
                now: now,
                quickPasteNumber: model.showsQuickPasteHints ? numbers[item.id] : nil,
                quickPasteSymbol: quickSymbol,
                highlightTerms: terms
            )
            .id(item.id)
        }
    }

    /// Whole cards visible at once, for Page Up and Page Down.
    static func cardsThatFit(in size: CGSize, layout: ShelfLayout) -> Int {
        let pitchX = CardView.size.width + spacing
        let pitchY = CardView.size.height + spacing
        if layout.isHorizontal {
            return max(1, Int((size.width - inset * 2 + spacing) / pitchX))
        }
        let rows = max(1, Int((size.height - inset * 2 + spacing) / pitchY))
        return rows * max(1, layout.columns)
    }
}

/// Reports a view's size, without taking any space itself.
struct SizeReader: View {
    let onChange: (CGSize) -> Void

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { onChange(proxy.size) }
                .onChange(of: proxy.size) { _, size in onChange(size) }
        }
    }
}

/// The quick-paste modifier as a symbol, for the hints on the first nine cards.
@MainActor
enum QuickPasteSymbol {
    static var current: String {
        switch Preferences().quickPasteModifier {
        case .command: "⌘"
        case .option: "⌥"
        case .control: "⌃"
        }
    }
}

/// A card with its mouse, drag and accessibility behavior.
struct InteractiveCard: View {
    @Bindable var model: ShelfViewModel
    let item: ClipItem
    let now: Date
    let quickPasteNumber: Int?
    let quickPasteSymbol: String
    var highlightTerms: [String] = []
    @State private var isDropTarget = false
    @State private var isHovered = false

    private var isSelected: Bool { model.isSelected(item) }
    private var isOnPinboard: Bool { if case .pinboard = model.tab { true } else { false } }

    var body: some View {
        CardView(
            item: item,
            isSelected: isSelected,
            now: now,
            isHovered: isHovered,
            quickPasteNumber: quickPasteNumber,
            quickPasteSymbol: quickPasteSymbol,
            boardNames: model.boardNames[item.id] ?? [],
            highlightTerms: highlightTerms,
            isRenaming: model.renamingItemID == item.id,
            onRename: { model.rename(item, to: $0) },
            thumbnails: model.thumbnails,
            richText: model.richText
        )
        .overlay(alignment: model.layout.isHorizontal ? .leading : .top) {
            if isDropTarget {
                if model.layout.isHorizontal {
                    Capsule().fill(Color.accentColor).frame(width: 3).offset(x: -10)
                } else {
                    Capsule().fill(Color.accentColor).frame(height: 3).offset(y: -10)
                }
            }
        }
        .background {
            if model.pinPickerItemID == item.id {
                PinMenuPresenter(model: model, item: item)
            }
        }
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2) {
            model.select(item)
            model.paste(item, PlainTextModifierState.isHeld ? .pastePlain : .paste)
        }
        // ⌘-click adds a card to the selection, Shift-click selects a range, a plain click selects one.
        .simultaneousGesture(TapGesture().onEnded {
            let flags = NSEvent.modifierFlags
            if flags.contains(.command) {
                model.toggleInSelection(item)
            } else if flags.contains(.shift) {
                model.extendSelection(to: item)
            } else {
                model.select(item)
            }
        })
        .contextMenu { CardMenu(model: model, item: item) }
        .onDrag { dragProvider() }
        .onDrop(of: isOnPinboard ? [.shelfItem] : [], isTargeted: $isDropTarget) { providers in
            guard let provider = providers.first else { return false }
            provider.loadShelfID(for: .shelfItem) { id in
                model.movePinnedItem(id, before: item.id)
            }
            return true
        }
        .onAppear { model.loadMoreIfNeeded(after: item) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Formatters.accessibilityLabel(for: item, now: now))
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction(named: String(localized: "Paste")) { model.paste(item, .paste) }
        .accessibilityAction(named: String(localized: "Copy")) { model.paste(item, .copy) }
        .accessibilityAction(named: String(localized: "Pin")) {
            model.select(item)
            model.requestPinSelected()
        }
        .accessibilityAction(named: String(localized: "Remove")) { model.remove(item) }
    }

    private func dragProvider() -> NSItemProvider {
        model.select(item)
        let provider = model.hooks.dragProvider(item)
        provider.registerShelfID(item.id, as: .shelfItem)
        return provider
    }
}

/// Whether the configured plain-text modifier is held, for double clicks.
@MainActor
enum PlainTextModifierState {
    static var isHeld: Bool {
        let flags = NSEvent.modifierFlags
        switch Preferences().plainTextModifier {
        case .shift: return flags.contains(.shift)
        case .option: return flags.contains(.option)
        }
    }
}

/// The right-click menu on a card.
struct CardMenu: View {
    let model: ShelfViewModel
    let item: ClipItem

    var body: some View {
        Button(String(localized: "Paste"), systemImage: "doc.on.clipboard") { model.paste(item, .paste) }
        Button(String(localized: "Paste as Plain Text"), systemImage: "text.alignleft") { model.paste(item, .pastePlain) }
        if item.kind == .text || item.kind == .richText || item.kind == .link {
            Menu(String(localized: "Paste as"), systemImage: "textformat") {
                ForEach(TextTransform.allCases, id: \.self) { transform in
                    Button(transform.displayName) { model.paste(item, .transformed(transform)) }
                }
            }
        }
        Button(String(localized: "Copy"), systemImage: "doc.on.doc") { model.paste(item, .copy) }
        Button(model.selectedItems.count > 1 && model.isSelected(item)
            ? String(localized: "Copy \(model.selectedItems.count) Items for AI")
            : String(localized: "Copy for AI"), systemImage: "sparkles") { model.copyForAI(item) }
        Divider()
        Button(String(localized: "Rename…"), systemImage: "pencil") {
            model.select(item)
            model.requestRenameSelected()
        }
        let targets = model.revealTargets(for: item)
        ForEach(targets, id: \.self) { target in
            Button(target.title, systemImage: target == .clipboard ? "clock" : "pin") {
                Task { await model.reveal(item, in: target) }
            }
        }
        if !targets.isEmpty { Divider() }
        Menu(String(localized: "Pin to"), systemImage: "pin") {
            ForEach(model.pinboards) { board in
                Button(board.name) { Task { await model.pin(item, to: board) } }
            }
            if !model.pinboards.isEmpty { Divider() }
            Button(String(localized: "New Pinboard"), systemImage: "plus") { Task { await model.createPinboard(pinning: item) } }
        }
        if let add = model.hooks.addToPasteStack {
            Button(String(localized: "Add to Paste Stack"), systemImage: "square.stack.3d.down.right") { add(item) }
        }
        Button(String(localized: "Quick Look"), systemImage: "eye") { model.quickLook(item) }
        if item.kind == .file, !item.filePaths.isEmpty, !item.missingFiles {
            Button(String(localized: "Show in Finder"), systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting(item.filePaths.map { URL(fileURLWithPath: $0) })
            }
        }
        if item.kind == .link, let url = item.url.flatMap(URL.init(string:)) {
            Button(String(localized: "Open Link"), systemImage: "safari") { NSWorkspace.shared.open(url) }
        }
        Divider()
        if case .pinboard = model.tab {
            Button(String(localized: "Remove from Pinboard"), systemImage: "pin.slash", role: .destructive) { model.remove(item) }
        } else {
            Button(String(localized: "Remove"), systemImage: "trash", role: .destructive) { model.remove(item) }
        }
    }
}

/// The empty states: no history yet, an empty pinboard, and no search results.
struct EmptyStateView: View {
    let model: ShelfViewModel

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.system(size: 14 * ShelfAppearance.textScale))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        if !model.query.isEmpty { return "magnifyingglass" }
        if case .pinboard = model.tab { return "pin" }
        return "clipboard"
    }

    private var message: String {
        if !model.query.isEmpty || model.searchEverywhere {
            return String(localized: "No results for \(model.effectiveSearchText)")
        }
        if case .pinboard = model.tab {
            return String(localized: "Drag cards here or press ⌘P")
        }
        return String(localized: "Copy something and it appears here")
    }
}

/// Pops the native pinboard menu for Cmd+P at the selected card, so arrows,
/// Return and Escape work as in any menu.
struct PinMenuPresenter: NSViewRepresentable {
    let model: ShelfViewModel
    let item: ClipItem

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            let menu = NSMenu(title: String(localized: "Pin to"))
            let header = NSMenuItem(title: String(localized: "Pin to"), action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for (index, board) in model.pinboards.enumerated() {
                let entry = ClosureMenuItem(title: board.name, key: index < 9 ? "\(index + 1)" : "") {
                    Task { await model.pin(item, to: board) }
                }
                entry.image = NSImage(systemSymbolName: board.icon ?? "circle.fill", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(paletteColors: [NSColor(board.color.color)]))
                menu.addItem(entry)
            }
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: String(localized: "New Pinboard"), key: "n") {
                Task { await model.createPinboard(pinning: item) }
            })
            menu.popUp(positioning: nil, at: NSPoint(x: 12, y: view.bounds.height - CardView.headerHeight), in: view)
            if model.pinPickerItemID == item.id { model.pinPickerItemID = nil }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// An `NSMenuItem` that runs a closure.
final nonisolated class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, key: String = "", handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        keyEquivalentModifierMask = []
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    // Menu actions are delivered on the main thread.
    @objc private func run() {
        let handler = self.handler
        MainActor.assumeIsolated { handler() }
    }
}
