import ShelfCore
import SwiftUI
import UniformTypeIdentifiers

/// Left to right: search, the Clipboard tab, one chip per pinboard, the plus
/// button, then the item count and the settings gear. On a narrow shelf (left
/// or right edge) the search field and gear sit above the tabs, and only the
/// selected tab shows its name; the others are their icon or color dot.
struct TopRail: View {
    @Bindable var model: ShelfViewModel
    var searchFocused: FocusState<Bool>.Binding
    /// The selected tab's glass slides between chips through this namespace.
    @Namespace private var tabGlass
    @State private var tabsContentWidth: CGFloat = 0
    @State private var tabsViewportWidth: CGFloat = 0

    static let height: CGFloat = 46
    static let compactHeight: CGFloat = 84

    var body: some View {
        if model.layout.isCompact {
            VStack(spacing: 6) {
                ShelfGlassContainer(spacing: 8) {
                    HStack(spacing: 6) {
                        SearchField(model: model, focused: searchFocused)
                        newPinboard
                        gear
                    }
                }
                tabs
                    .environment(\.compactTabs, true)
            }
        } else {
            HStack(spacing: 12) {
                SearchField(model: model, focused: searchFocused)
                    .frame(width: 280)
                tabs
                Spacer(minLength: 8)
                count
                gear
            }
        }
    }

    /// The tab chips scroll sideways; a fade at the trailing edge shows when more
    /// are hidden. Their glass container sits inside the scroll view, so the
    /// glass is clipped with the chips instead of drawing past the rail.
    private var tabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            ShelfGlassContainer(spacing: 4) {
                HStack(spacing: 4) {
                    tabChips
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 2)
            }
            .background(SizeReader { tabsContentWidth = $0.width })
        }
        .background(SizeReader { tabsViewportWidth = $0.width })
        .mask {
            if tabsContentWidth > tabsViewportWidth + 1 {
                HStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 28)
                }
            } else {
                Color.black
            }
        }
    }

    @ViewBuilder
    private var tabChips: some View {
        TabChip(
            title: String(localized: "Clipboard"),
            symbol: "clock",
            tint: nil,
            isSelected: model.tab == .clipboard,
            glassNamespace: tabGlass
        ) {
            withAnimation(.smooth(duration: 0.3)) { model.switchTo(.clipboard) }
        }
        ForEach(model.pinboards) { board in
            PinboardChip(model: model, board: board, glassNamespace: tabGlass)
        }
        // The narrow rail has no room after the tabs; its plus sits by the gear.
        if !model.layout.isCompact {
            newPinboard
                .padding(.leading, 4)
        }
    }

    private var newPinboard: some View {
        Button {
            Task { await model.createPinboard() }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 18, height: 18)
        }
        .shelfIconButtonStyle()
        .help(String(localized: "New Pinboard"))
        .accessibilityLabel(String(localized: "New Pinboard"))
    }

    private var count: some View {
        Text(model.countLabel)
            .font(.system(size: 12 * ShelfAppearance.textScale))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .contentTransition(.numericText())
    }

    private var gear: some View {
        Button {
            model.hooks.openSettings()
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 18, height: 18)
        }
        .shelfIconButtonStyle()
        .help(String(localized: "Settings"))
        .accessibilityLabel(String(localized: "Settings"))
    }
}

struct SearchField: View {
    @Bindable var model: ShelfViewModel
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            ForEach(model.chipFilters) { filter in
                Button {
                    model.removeFilter(filter)
                } label: {
                    HStack(spacing: 3) {
                        Text(filter.label).lineLimit(1)
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    }
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.2), in: Capsule())
                }
                .buttonStyle(.plain)
                .help(String(localized: "Remove filter"))
            }
            TextField(model.layout.isCompact ? String(localized: "Search") : String(localized: "Search, or type: app: after:"), text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13 * ShelfAppearance.textScale))
                .focused(focused)
                .onSubmit { model.pasteSelected(.paste) }
            Button {
                model.toggleSearchEverywhere()
            } label: {
                Image(systemName: model.searchEverywhere ? "square.stack.3d.up.fill" : "square.stack.3d.up")
                    .foregroundStyle(model.searchEverywhere ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Search all tabs (⇧⌘F)"))
            .accessibilityLabel(String(localized: "Search all tabs"))
            if !model.searchText.isEmpty || !model.filterChips.isEmpty {
                Button {
                    model.escapeSearch()
                    model.focusSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Clear search"))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .shelfGlass(in: Capsule(), interactive: true, fallback: Color.primary.opacity(0.07))
    }
}

struct TabChip: View {
    let title: String
    let symbol: String?
    let tint: Color?
    let isSelected: Bool
    /// Items on the board, shown after the name.
    var count: Int?
    var glassNamespace: Namespace.ID?
    let action: () -> Void
    @Environment(\.compactTabs) private var compact

    /// On the narrow rail an unselected tab is only its icon or dot.
    private var showsTitle: Bool { isSelected || !compact }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol)
                        .foregroundStyle(tint ?? .primary)
                        .font(.system(size: showsTitle ? 11 : 12, weight: .semibold))
                } else if let tint {
                    Circle().fill(tint).frame(width: showsTitle ? 8 : 10, height: showsTitle ? 8 : 10)
                }
                if showsTitle {
                    Text(title)
                        .font(.system(size: 12 * ShelfAppearance.textScale, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)
                        .transition(.opacity)
                }
                if showsTitle, let count, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10 * ShelfAppearance.textScale, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(String(localized: "\(count) items"))
                }
            }
            .padding(.horizontal, showsTitle ? 11 : 0)
            .frame(minWidth: 28, minHeight: 28, maxHeight: 28)
            .modifier(SelectedTabGlass(isSelected: isSelected, namespace: glassNamespace))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(showsTitle ? "" : title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

extension EnvironmentValues {
    /// The narrow rail of the left and right shelves.
    @Entry var compactTabs = false
}

/// The selected tab sits on a glass capsule that slides from chip to chip
/// when the tab changes; a plain fill before macOS 26.
private struct SelectedTabGlass: ViewModifier {
    let isSelected: Bool
    let namespace: Namespace.ID?

    func body(content: Content) -> some View {
        if ShelfAppearance.usesGlass, #available(macOS 26, *), let namespace {
            if isSelected {
                content
                    .background(Color.primary.opacity(0.06), in: Capsule())
                    .glassEffect(.regular.interactive(), in: Capsule())
                    .glassEffectID("selected-tab", in: namespace)
            } else {
                content
            }
        } else {
            content.background(isSelected ? Color.primary.opacity(0.12) : .clear, in: Capsule())
        }
    }
}

/// A pinboard tab: click to open, double click to rename, right click for
/// color, icon and delete, drop a card to pin, drag to reorder.
struct PinboardChip: View {
    @Bindable var model: ShelfViewModel
    let board: Pinboard
    var glassNamespace: Namespace.ID?
    @State private var name = ""
    @State private var isTargeted = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        Group {
            if model.renamingPinboardID == board.id {
                HStack(spacing: 6) {
                    Circle().fill(board.color.color).frame(width: 8, height: 8)
                    TextField(String(localized: "Name"), text: $name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 120)
                        .focused($nameFocused)
                        .onSubmit { model.rename(board, to: name) }
                        .onAppear {
                            name = board.name
                            nameFocused = true
                        }
                        .onChange(of: nameFocused) { _, focused in
                            if !focused, model.renamingPinboardID == board.id { model.rename(board, to: name) }
                        }
                }
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Color.primary.opacity(0.12), in: Capsule())
            } else {
                TabChip(
                    title: board.name,
                    symbol: board.icon,
                    tint: board.color.color,
                    isSelected: model.tab == .pinboard(board.id),
                    count: board.itemCount,
                    glassNamespace: glassNamespace
                ) {
                    withAnimation(.smooth(duration: 0.3)) { model.switchTo(.pinboard(board.id)) }
                }
                .simultaneousGesture(TapGesture(count: 2).onEnded { model.renamingPinboardID = board.id })
            }
        }
        .overlay(Capsule().strokeBorder(Color.accentColor, lineWidth: 2).opacity(isTargeted ? 1 : 0))
        .onDrop(of: [.shelfItem, .shelfPinboard], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }
            if provider.hasItemConformingToTypeIdentifier(UTType.shelfPinboard.identifier) {
                provider.loadShelfID(for: .shelfPinboard) { id in model.movePinboard(id, before: board.id) }
            } else {
                provider.loadShelfID(for: .shelfItem) { id in model.pin(itemID: id, toBoardID: board.id) }
            }
            return true
        }
        .onDrag {
            let provider = NSItemProvider()
            provider.registerShelfID(board.id, as: .shelfPinboard)
            return provider
        }
        .contextMenu {
            Button(String(localized: "Rename"), systemImage: "pencil") { model.renamingPinboardID = board.id }
            Menu(String(localized: "Color"), systemImage: "paintpalette") {
                ForEach(PinboardColor.allCases, id: \.self) { color in
                    Button {
                        model.setColor(color, of: board)
                    } label: {
                        Label(color.displayName, systemImage: board.color == color ? "checkmark.circle.fill" : "circle.fill")
                    }
                }
            }
            Menu(String(localized: "Icon"), systemImage: "face.smiling") {
                Button(String(localized: "None")) { model.setIcon(nil, of: board) }
                Divider()
                ForEach(PinboardIcon.choices, id: \.self) { symbol in
                    Button { model.setIcon(symbol, of: board) } label: { Label(symbol, systemImage: symbol) }
                }
            }
            Divider()
            Button(String(localized: "Copy Board for AI"), systemImage: "sparkles") { model.copyBoardForAI(board) }
            Divider()
            Button(String(localized: "Delete…"), systemImage: "trash", role: .destructive) { model.requestDeletion(of: board) }
        }
        .help(String(localized: "\(board.itemCount) items"))
    }
}
