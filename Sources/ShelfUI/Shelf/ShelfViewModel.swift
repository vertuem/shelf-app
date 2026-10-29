import AppKit
import Observation
import ShelfCore

/// What the user asked for when choosing a card.
public enum PasteRequest: Sendable, Equatable {
    /// Enter, double click: paste into the active app.
    case paste
    /// Cmd+Enter, or the plain-text modifier: paste as plain text.
    case pastePlain
    /// Shift+Enter: put on the clipboard without pasting.
    case copy
    /// "Paste as Uppercase" and friends: plain text with a case change.
    case transformed(TextTransform)
}

/// Everything the shelf needs from the rest of the app. The app target fills
/// these in; tests pass recording closures.
@MainActor
public struct ShelfHooks {
    /// Writes and pastes. Must call `closeShelf` after writing the pasteboard and
    /// before posting the keystroke.
    public var perform: (_ item: ClipItem, _ request: PasteRequest, _ closeShelf: @escaping @MainActor () -> Void) async -> Void
    /// Pastes several cards at once, in strip order. Nil pastes only the current card.
    public var performMany: ((_ items: [ClipItem], _ request: PasteRequest, _ closeShelf: @escaping @MainActor () -> Void) async -> Void)?
    public var close: () -> Void
    public var openSettings: () -> Void
    public var addToPasteStack: ((ClipItem) -> Void)?
    /// Shows an item in Quick Look, replacing what an open preview shows; nil closes it.
    public var quickLook: (ClipItem?) -> Void
    public var isQuickLookVisible: () -> Bool
    public var showCheatSheet: () -> Void
    public var dragProvider: (ClipItem) -> NSItemProvider
    public var playSound: (Sound) -> Void
    /// "Copy for AI": one text block from several cards onto the clipboard.
    public var copyForAI: ([ClipItem]) async -> Void

    public enum Sound { case pin, delete }

    public init(
        perform: @escaping (ClipItem, PasteRequest, @escaping @MainActor () -> Void) async -> Void,
        performMany: ((_ items: [ClipItem], PasteRequest, @escaping @MainActor () -> Void) async -> Void)? = nil,
        close: @escaping () -> Void,
        openSettings: @escaping () -> Void = {},
        addToPasteStack: ((ClipItem) -> Void)? = nil,
        quickLook: @escaping (ClipItem?) -> Void = { _ in },
        isQuickLookVisible: @escaping () -> Bool = { false },
        showCheatSheet: @escaping () -> Void = {},
        dragProvider: @escaping (ClipItem) -> NSItemProvider = { _ in NSItemProvider() },
        playSound: @escaping (Sound) -> Void = { _ in },
        copyForAI: @escaping ([ClipItem]) async -> Void = { _ in }
    ) {
        self.perform = perform
        self.performMany = performMany
        self.close = close
        self.openSettings = openSettings
        self.addToPasteStack = addToPasteStack
        self.quickLook = quickLook
        self.isQuickLookVisible = isQuickLookVisible
        self.showCheatSheet = showCheatSheet
        self.dragProvider = dragProvider
        self.playSound = playSound
        self.copyForAI = copyForAI
    }
}

/// A short message at the bottom of the shelf, with an optional Undo.
public struct Toast: Identifiable, Equatable {
    public let id = UUID()
    public var message: String
    public var canUndo = false
    public var isWarning = false
}

/// How the cards are laid out for a shelf position: a horizontal strip along
/// the bottom, a column up the left or right edge, or a grid in a centered panel.
public struct ShelfLayout: Sendable, Equatable {
    public var position: ShelfPosition

    public init(position: ShelfPosition) {
        self.position = position
    }

    /// Cards per row. 0 means one horizontal row that scrolls sideways.
    public var columns: Int {
        switch position {
        case .bottom: 0
        case .left, .right: 1
        case .center: 3
        }
    }

    /// A narrow rail: the search field above the tabs instead of beside them.
    public var isCompact: Bool { position == .left || position == .right }

    public var isHorizontal: Bool { columns == 0 }
    public static let bottom = ShelfLayout(position: .bottom)
}

/// One completion offered under the search field while a filter is typed.
public struct SearchSuggestion: Identifiable, Equatable, Sendable {
    /// The full token, such as `type:image`, that replaces what was typed.
    public var token: String
    public var label: String
    public var symbol: String?
    public var id: String { token }
}

/// The state behind the shelf. Talks to the Store; never to the pasteboard.
@MainActor
@Observable
public final class ShelfViewModel {
    public enum Tab: Hashable, Sendable {
        case clipboard
        case pinboard(UUID)
    }

    public private(set) var pinboards: [Pinboard] = []
    public private(set) var tab: Tab = .clipboard
    /// The text in the search field. A filter token followed by a space
    /// (`type:image `) moves out of the text into `filterChips`.
    public var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            absorbCompletedFilters()
            searchChanged()
        }
    }
    /// Completed filter tokens, shown as removable chips in front of the text.
    public private(set) var filterChips: [String] = []
    public private(set) var searchEverywhere = false
    public private(set) var query = SearchQuery()
    public private(set) var items: [ClipItem] = []
    /// Pinboard names per item, shown on cards during a global search.
    public private(set) var boardNames: [UUID: [String]] = [:]
    public private(set) var selectedID: UUID? {
        didSet {
            // An open preview follows the selection, as in Finder.
            if selectedID != oldValue, hooks.isQuickLookVisible(), let selectedItem { hooks.quickLook(selectedItem) }
        }
    }
    /// Cards chosen with Shift and the arrows, or ⌘ and Shift clicks, on top of
    /// the current card. Return pastes them all, Delete removes them all.
    public private(set) var multiSelection: Set<UUID> = []
    /// The strip layout for the shelf position in effect, set on every open.
    public var layout: ShelfLayout = .bottom
    /// How many cards fit in the viewport, from the strip's size, for Page Up and Page Down.
    public var visibleCardCount = 6
    /// Completions for the filter being typed (`type:`, `app:`, `pinned:`).
    public private(set) var suggestions: [SearchSuggestion] = []
    public private(set) var suggestionIndex = 0
    public private(set) var historyCount = 0
    public private(set) var toast: Toast?
    public private(set) var hasLoaded = false
    public var renamingPinboardID: UUID?
    /// The card whose title is being edited (⌘R).
    public var renamingItemID: UUID?
    /// The item the Cmd+P pinboard menu is open for.
    public var pinPickerItemID: UUID?
    /// Bumped to ask the view to focus the search field.
    public private(set) var focusRequest = 0
    /// Set by keyboard navigation only; the strip scrolls to it.
    public private(set) var scrollTarget: UUID?
    /// Shown while the quick-paste modifier is held.
    public var showsQuickPasteHints = false
    /// A pinboard waiting for delete confirmation.
    public var pinboardPendingDeletion: Pinboard?
    public var isRightToLeft = false

    @ObservationIgnored public let store: Store
    @ObservationIgnored public var hooks: ShelfHooks
    @ObservationIgnored public let thumbnails: ThumbnailCache
    @ObservationIgnored public let richText: RichTextCache
    @ObservationIgnored private var pendingRemoval: (items: [ClipItem], tab: Tab)?
    @ObservationIgnored private var removalTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var canLoadMore = true
    @ObservationIgnored private var sourceAppNames: [String] = []
    @ObservationIgnored private var isLoadingMore = false
    @ObservationIgnored public var searchDebounce: Duration = .milliseconds(40)
    @ObservationIgnored public var undoWindow: Duration = .seconds(3)
    public static let pageSize = 200

    public init(store: Store, hooks: ShelfHooks) {
        self.store = store
        self.hooks = hooks
        self.thumbnails = ThumbnailCache { [store] id in store.thumbnail(for: id) }
        self.richText = RichTextCache { [store] id in
            guard let representations = try? await store.representations(for: id) else { return nil }
            return RichTextRenderer.attributed(from: representations)
        }
    }

    // MARK: Lifecycle

    /// Loads the first page and subscribes to store changes. Called at launch,
    /// so the shelf opens with cards and thumbnails already in memory.
    public func start() async {
        guard eventsTask == nil else { return }
        eventsTask = Task { [weak self, store] in
            for await event in store.events() {
                await self?.handle(event)
            }
        }
        await reloadAll()
        await thumbnails.preload(items.filter(\.hasThumbnail).map(\.id))
        sourceAppNames = (try? await store.sourceAppNames()) ?? []
    }

    public func stop() {
        eventsTask?.cancel()
        eventsTask = nil
    }

    /// Every open starts on the Clipboard tab with an empty search and the newest card selected.
    public func prepareForShow() {
        commitPendingRemoval()
        pinPickerItemID = nil
        pinboardPendingDeletion = nil
        renamingPinboardID = nil
        renamingItemID = nil
        toast = nil
        multiSelection = []
        suggestions = []
        let needsReload = tab != .clipboard || !searchText.isEmpty || !filterChips.isEmpty || searchEverywhere || !query.isEmpty
        tab = .clipboard
        searchEverywhere = false
        searchTask?.cancel()
        filterChips = []
        searchText = ""
        query = SearchQuery()
        if needsReload {
            Task { await reloadItems() }
        }
        selectedID = items.first?.id
        scrollTarget = items.first?.id
        focusRequest += 1
    }

    public func didHide() {
        commitPendingRemoval()
        showsQuickPasteHints = false
        if hooks.isQuickLookVisible() { hooks.quickLook(nil) }
    }

    // MARK: Loading

    public func reloadAll() async {
        await reloadPinboards()
        await reloadItems()
        hasLoaded = true
    }

    func reloadPinboards() async {
        pinboards = (try? await store.pinboards()) ?? []
        if case .pinboard(let id) = tab, !pinboards.contains(where: { $0.id == id }) {
            tab = .clipboard
            await reloadItems()
        }
    }

    func reloadItems() async {
        historyCount = (try? await store.historyCount()) ?? 0
        if !query.isEmpty {
            await runSearch()
            return
        }
        let loaded: [ClipItem]
        switch tab {
        case .clipboard:
            loaded = (try? await store.history(limit: Self.pageSize)) ?? []
            canLoadMore = loaded.count == Self.pageSize
        case .pinboard(let id):
            loaded = (try? await store.items(onPinboard: id)) ?? []
            canLoadMore = false
        }
        boardNames = [:]
        setItems(loaded)
    }

    /// Loads the next page when the selection or scroll gets near the end.
    public func loadMoreIfNeeded(after item: ClipItem) {
        guard canLoadMore, !isLoadingMore, tab == .clipboard, query.isEmpty,
              let index = items.firstIndex(where: { $0.id == item.id }), index >= items.count - 20 else { return }
        isLoadingMore = true
        Task {
            let more = (try? await store.history(limit: Self.pageSize, offset: items.count)) ?? []
            let known = Set(items.map(\.id))
            items.append(contentsOf: more.filter { !known.contains($0.id) })
            canLoadMore = more.count == Self.pageSize
            isLoadingMore = false
        }
    }

    private func setItems(_ newItems: [ClipItem]) {
        let hidden = Set(pendingRemoval?.items.map(\.id) ?? [])
        items = newItems.filter { !hidden.contains($0.id) }
        if selectedID == nil || !items.contains(where: { $0.id == selectedID }) {
            selectedID = items.first?.id
        }
    }

    // MARK: Store events

    func handle(_ event: StoreEvent) async {
        switch event {
        case .captured(let item, _), .used(let item):
            historyCount = (try? await store.historyCount()) ?? historyCount
            keepPendingRemoval(from: item.id)
            if let name = item.sourceAppName, !sourceAppNames.contains(name) { sourceAppNames.insert(name, at: 0) }
            if !query.isEmpty {
                scheduleSearch(immediately: true, keepSelection: true)
            } else if tab == .clipboard {
                items.removeAll { $0.id == item.id }
                items.insert(item, at: 0)
                if selectedID == nil { selectedID = item.id }
            }
        case .updated(let item):
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index] = item
                thumbnails.remove(item.id)
                richText.remove(item.id)
            }
        case .removed(let ids):
            historyCount = (try? await store.historyCount()) ?? historyCount
            if tab == .clipboard || searchEverywhere {
                removeLocally(ids)
            }
        case .pinsChanged:
            await reloadPinboards()
            if case .pinboard = tab { await reloadItems() }
        case .pinboardsChanged:
            await reloadPinboards()
        case .reloaded:
            await reloadAll()
        }
    }

    private func removeLocally(_ ids: Set<UUID>) {
        multiSelection.subtract(ids)
        guard let selectedID, ids.contains(selectedID) else {
            items.removeAll { ids.contains($0.id) }
            return
        }
        let index = items.firstIndex { $0.id == selectedID } ?? 0
        items.removeAll { ids.contains($0.id) }
        self.selectedID = items.isEmpty ? nil : items[min(index, items.count - 1)].id
    }

    // MARK: Search

    private func searchChanged() {
        updateSuggestions()
        scheduleSearch(immediately: false)
    }

    // MARK: Filter suggestions

    /// Offers completions once a filter key and its colon are typed: the kinds
    /// for `type:`, the apps in history for `app:`, the boards for `pinned:`.
    private func updateSuggestions() {
        suggestionIndex = 0
        guard let token = searchText.split(separator: " ", omittingEmptySubsequences: false).last.map(String.init),
              !token.isEmpty, let colon = token.firstIndex(of: ":") else {
            suggestions = []
            return
        }
        let key = token[..<colon].lowercased()
        let typed = token[token.index(after: colon)...].lowercased()
        func matches(_ value: String) -> Bool { typed.isEmpty || value.lowercased().hasPrefix(typed) }
        switch key {
        case "type", "kind", "is":
            suggestions = ContentKind.allCases.filter { $0 != .other && matches($0.searchToken) }.map {
                SearchSuggestion(token: "\(key):\($0.searchToken)", label: $0.displayName, symbol: $0.symbol)
            }
        case "app", "from":
            suggestions = sourceAppNames.filter(matches).prefix(8).map {
                SearchSuggestion(token: "\(key):\(Self.quoted($0))", label: $0, symbol: "app")
            }
        case "pinned", "pin", "board":
            suggestions = pinboards.filter { matches($0.name) }.map {
                SearchSuggestion(token: "\(key):\(Self.quoted($0.name))", label: $0.name, symbol: $0.icon ?? "pin")
            }
        default:
            suggestions = []
        }
        if suggestions.count == 1, suggestions[0].token.lowercased() == token.lowercased() { suggestions = [] }
    }

    /// Values with spaces cannot be typed as one token; use the first word, which `app:` matches as a prefix anyway.
    private static func quoted(_ value: String) -> String {
        value.split(separator: " ").first.map(String.init) ?? value
    }

    public func moveSuggestion(by offset: Int) {
        guard !suggestions.isEmpty else { return }
        suggestionIndex = (suggestionIndex + offset + suggestions.count) % suggestions.count
    }

    /// Tab or Return while suggestions show: the typed token becomes the chosen filter chip.
    public func acceptSuggestion(_ suggestion: SearchSuggestion? = nil) {
        guard let chosen = suggestion ?? (suggestions.indices.contains(suggestionIndex) ? suggestions[suggestionIndex] : nil) else { return }
        var tokens = searchText.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        if tokens.isEmpty { tokens = [""] }
        tokens[tokens.count - 1] = chosen.token
        suggestions = []
        // The trailing space turns the token into a chip.
        searchText = tokens.joined(separator: " ") + " "
        focusRequest += 1
    }

    public var hasSuggestions: Bool { !suggestions.isEmpty }

    /// Runs the query. Typing moves the selection to the best match; refreshes
    /// caused by a background copy keep the card the user arrowed to.
    private func scheduleSearch(immediately: Bool, keepSelection: Bool = false) {
        searchTask?.cancel()
        let debounce = searchDebounce
        searchTask = Task {
            if !immediately {
                try? await Task.sleep(for: debounce)
                guard !Task.isCancelled else { return }
            }
            query = SearchQuery.parse(effectiveSearchText)
            if query.isEmpty {
                await reloadItems()
            } else {
                await runSearch()
            }
            if keepSelection, let selectedID, items.contains(where: { $0.id == selectedID }) {
                return
            }
            selectedID = items.first?.id
            scrollTarget = items.first?.id
        }
    }

    private func runSearch() async {
        let scope: Store.Scope
        if searchEverywhere {
            scope = .everywhere
        } else {
            switch tab {
            case .clipboard: scope = .history
            case .pinboard(let id): scope = .pinboard(id)
            }
        }
        let results = (try? await store.search(query, scope: scope)) ?? []
        guard !Task.isCancelled else { return }
        boardNames = searchEverywhere ? ((try? await store.pinboardNames(for: results.map(\.id))) ?? [:]) : [:]
        setItems(results)
    }

    /// Cmd+Shift+F: search every tab, with pinboard names on the cards.
    public func toggleSearchEverywhere() {
        searchEverywhere.toggle()
        focusRequest += 1
        scheduleSearch(immediately: true)
    }

    /// The chips, parsed, for display.
    public var chipFilters: [SearchQuery.Filter] {
        SearchQuery.parse(filterChips.joined(separator: " ")).filters
    }

    /// Chips and field text together: what is actually searched.
    public var effectiveSearchText: String {
        (filterChips + [searchText]).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    public func removeFilter(_ filter: SearchQuery.Filter) {
        if let index = filterChips.firstIndex(where: { SearchQuery.parse($0).filters.first?.id == filter.id }) {
            filterChips.remove(at: index)
        }
        focusRequest += 1
        scheduleSearch(immediately: true)
    }

    private func absorbCompletedFilters() {
        guard let last = searchText.last, last.isWhitespace else { return }
        let parsed = SearchQuery.parse(searchText)
        guard !parsed.filters.isEmpty else { return }
        var text = searchText
        for filter in parsed.filters.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            filterChips.append(String(text[filter.range]))
            text.removeSubrange(filter.range)
        }
        filterChips = Array(NSOrderedSet(array: filterChips).compactMap { $0 as? String })
        let rest = text.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        // The space the user just typed stays, so the next word does not join the last one.
        searchText = rest.isEmpty ? "" : rest + " "
    }

    public func focusSearch() {
        focusRequest += 1
    }

    // MARK: Selection

    public var selectedItem: ClipItem? {
        items.first { $0.id == selectedID }
    }

    public var selectedIndex: Int? {
        items.firstIndex { $0.id == selectedID }
    }

    public func select(_ item: ClipItem) {
        multiSelection = []
        selectedID = item.id
        loadMoreIfNeeded(after: item)
    }

    /// Whether a card is drawn as selected: the current card or part of the multi-selection.
    public func isSelected(_ item: ClipItem) -> Bool {
        item.id == selectedID || multiSelection.contains(item.id)
    }

    /// The current card plus the multi-selection, in strip order.
    public var selectedItems: [ClipItem] {
        guard !multiSelection.isEmpty else { return selectedItem.map { [$0] } ?? [] }
        var ids = multiSelection
        if let selectedID { ids.insert(selectedID) }
        return items.filter { ids.contains($0.id) }
    }

    /// Left and Right. In right-to-left layouts the strip is mirrored, so the
    /// keys follow reading direction. With `extending`, the cards passed over
    /// join the multi-selection (Shift with the arrows).
    public func moveSelection(by offset: Int, extending: Bool = false) {
        guard !items.isEmpty else { return }
        let step = isRightToLeft ? -offset : offset
        let current = selectedIndex ?? -1
        let next = min(max(current + step, 0), items.count - 1)
        if extending, current >= 0 {
            for index in min(current, next)...max(current, next) { multiSelection.insert(items[index].id) }
        } else {
            multiSelection = []
        }
        selectedID = items[next].id
        // Scroll one card past the target so the selection never sits at the very edge.
        let lookahead = min(max(next + (step > 0 ? 1 : -1), 0), items.count - 1)
        scrollTarget = items[lookahead].id
        loadMoreIfNeeded(after: items[next])
    }

    /// Up and Down: a row in a grid, a card in a column, nothing in a horizontal strip.
    public func moveSelectionVertically(by rows: Int, extending: Bool = false) {
        guard layout.columns > 0 else { return }
        moveSelection(by: rows * layout.columns * (isRightToLeft ? -1 : 1), extending: extending)
    }

    /// Page Up and Page Down: a viewport's worth of cards.
    public func moveSelectionByPage(_ direction: Int) {
        moveSelection(by: direction * max(1, visibleCardCount) * (isRightToLeft ? -1 : 1))
    }

    /// ⌘-click: adds or removes one card without moving the current one.
    public func toggleInSelection(_ item: ClipItem) {
        if item.id == selectedID {
            // Taking the current card out hands the role to another selected
            // card. The current card can itself be in the set (Shift with the
            // arrows, Shift-click put it there), so it leaves the set first.
            multiSelection.remove(item.id)
            guard let other = items.first(where: { multiSelection.contains($0.id) }) else { return }
            selectedID = other.id
            // One card left is a plain selection again.
            if multiSelection.count == 1 { multiSelection = [] }
        } else if multiSelection.contains(item.id) {
            multiSelection.remove(item.id)
        } else {
            multiSelection.insert(item.id)
            if selectedID == nil { selectedID = item.id }
        }
    }

    /// Shift-click: every card between the current one and the clicked one.
    public func extendSelection(to item: ClipItem) {
        guard let from = selectedIndex, let to = items.firstIndex(where: { $0.id == item.id }) else {
            select(item)
            return
        }
        for index in min(from, to)...max(from, to) { multiSelection.insert(items[index].id) }
        selectedID = item.id
    }

    public func selectFirst() {
        guard let first = items.first else { return }
        multiSelection = []
        selectedID = first.id
        scrollTarget = first.id
    }

    public func selectLast() {
        guard let last = items.last else { return }
        multiSelection = []
        selectedID = last.id
        scrollTarget = last.id
        loadMoreIfNeeded(after: last)
    }

    // MARK: Paste

    public func pasteSelected(_ request: PasteRequest) {
        let selected = selectedItems
        if selected.count > 1, let performMany = hooks.performMany {
            commitPendingRemoval()
            let hooks = self.hooks
            Task {
                await performMany(selected, request) { hooks.close() }
            }
            return
        }
        guard let item = selectedItem else { return }
        paste(item, request)
    }

    /// Cmd+1 to Cmd+9: the nth card in the strip.
    public func quickPaste(number: Int, plain: Bool) {
        guard (1...9).contains(number), number <= items.count else { return }
        paste(items[number - 1], plain ? .pastePlain : .paste)
    }

    public func paste(_ item: ClipItem, _ request: PasteRequest) {
        commitPendingRemoval()
        let hooks = self.hooks
        Task {
            await hooks.perform(item, request) { hooks.close() }
        }
    }

    // MARK: Removing, with undo

    /// Delete: on the Clipboard tab removes from history (pinned copies stay);
    /// on a pinboard removes the pin. Undo is offered for three seconds.
    public func removeSelected() {
        let selected = selectedItems
        guard !selected.isEmpty else { return }
        remove(selected)
    }

    public func remove(_ item: ClipItem) {
        remove([item])
    }

    public func remove(_ removed: [ClipItem]) {
        guard !removed.isEmpty else { return }
        commitPendingRemoval()
        removeLocally(Set(removed.map(\.id)))
        pendingRemoval = (removed, tab)
        hooks.playSound(.delete)
        let message = switch (removed.count > 1, tab == .clipboard) {
        case (true, true): String(localized: "Removed \(removed.count) items from history")
        case (true, false): String(localized: "Removed \(removed.count) items from pinboard")
        case (false, true): String(localized: "Removed from history")
        case (false, false): String(localized: "Removed from pinboard")
        }
        show(Toast(message: message, canUndo: true), for: undoWindow)
        removalTask?.cancel()
        let window = undoWindow
        removalTask = Task {
            try? await Task.sleep(for: window)
            guard !Task.isCancelled else { return }
            commitPendingRemoval()
        }
    }

    public func undoRemoval() {
        guard let pending = pendingRemoval else { return }
        removalTask?.cancel()
        pendingRemoval = nil
        toast = nil
        if pending.tab == tab {
            Task {
                await reloadItems()
                selectedID = pending.items.first?.id
                scrollTarget = selectedID
            }
        }
    }

    public var canUndo: Bool { pendingRemoval != nil }

    /// The same content was copied again during the undo window: keep it.
    private func keepPendingRemoval(from id: UUID) {
        guard var pending = pendingRemoval, pending.items.contains(where: { $0.id == id }) else { return }
        pending.items.removeAll { $0.id == id }
        if pending.items.isEmpty {
            pendingRemoval = nil
            removalTask?.cancel()
            if toast?.canUndo == true { toast = nil }
        } else {
            pendingRemoval = pending
        }
    }

    private func commitPendingRemoval() {
        guard let pending = pendingRemoval else { return }
        pendingRemoval = nil
        removalTask?.cancel()
        let ids = pending.items.map(\.id)
        let store = self.store
        Task {
            switch pending.tab {
            case .clipboard:
                try? await store.removeFromHistory(ids)
            case .pinboard(let boardID):
                for id in ids { try? await store.unpin(id, from: boardID) }
            }
        }
    }

    // MARK: Tabs and pinboards

    public var tabs: [Tab] { [.clipboard] + pinboards.map { .pinboard($0.id) } }

    public func switchTo(_ newTab: Tab) {
        guard newTab != tab else { return }
        commitPendingRemoval()
        tab = newTab
        renamingPinboardID = nil
        selectedID = nil
        multiSelection = []
        focusRequest += 1
        Task {
            if searchEverywhere { searchEverywhere = false }
            await reloadItems()
            selectFirst()
        }
    }

    public func nextTab() { cycleTab(by: 1) }
    public func previousTab() { cycleTab(by: -1) }

    private func cycleTab(by offset: Int) {
        let all = tabs
        guard let index = all.firstIndex(of: tab) else { return }
        switchTo(all[(index + offset + all.count) % all.count])
    }

    public var currentPinboard: Pinboard? {
        guard case .pinboard(let id) = tab else { return nil }
        return pinboards.first { $0.id == id }
    }

    /// The plus chip: creates a board and starts renaming it inline.
    @discardableResult
    public func createPinboard(pinning item: ClipItem? = nil) async -> Pinboard? {
        if pinboards.count >= Pinboard.softLimitCount {
            show(Toast(message: String(localized: "That is a lot of pinboards. Consider merging some."), isWarning: true))
        }
        guard let board = try? await store.createPinboard(name: uniqueBoardName()) else { return nil }
        await reloadPinboards()
        if let item {
            await pin(item, to: board)
        }
        renamingPinboardID = board.id
        return board
    }

    private func uniqueBoardName() -> String {
        let base = String(localized: "New Pinboard")
        let names = Set(pinboards.map(\.name))
        guard names.contains(base) else { return base }
        var number = 2
        while names.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }

    public func rename(_ board: Pinboard, to name: String) {
        renamingPinboardID = nil
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != board.name else { return }
        Task { try? await store.updatePinboard(board.id, name: trimmed) }
        if let index = pinboards.firstIndex(where: { $0.id == board.id }) { pinboards[index].name = trimmed }
    }

    public func setColor(_ color: PinboardColor, of board: Pinboard) {
        Task { try? await store.updatePinboard(board.id, color: color) }
    }

    public func setIcon(_ icon: String?, of board: Pinboard) {
        Task { try? await store.updatePinboard(board.id, icon: .some(icon)) }
    }

    /// Right-click "Delete…" asks first; the dialog names the item count.
    public func requestDeletion(of board: Pinboard) {
        pinboardPendingDeletion = board
    }

    public func confirmDeletion() {
        guard let board = pinboardPendingDeletion else { return }
        pinboardPendingDeletion = nil
        if tab == .pinboard(board.id) { switchTo(.clipboard) }
        Task { try? await store.deletePinboard(board.id) }
    }

    public func movePinboard(_ boardID: UUID, before targetID: UUID?) {
        var order = pinboards.map(\.id)
        guard let from = order.firstIndex(of: boardID) else { return }
        order.remove(at: from)
        let to = targetID.flatMap { order.firstIndex(of: $0) } ?? order.count
        order.insert(boardID, at: to)
        pinboards = order.compactMap { id in pinboards.first { $0.id == id } }
        Task { try? await store.reorderPinboards(order) }
    }

    // MARK: Pinning

    /// Cmd+P: opens the pinboard menu for the selected card.
    public func requestPinSelected() {
        guard let item = selectedItem else { return }
        if pinboards.isEmpty {
            Task { await createPinboard(pinning: item) }
        } else {
            pinPickerItemID = item.id
        }
    }

    public func pin(_ item: ClipItem, to board: Pinboard) async {
        pinPickerItemID = nil
        // Pinning one card of a multi-selection pins them all.
        let batch = multiSelection.contains(item.id) || item.id == selectedID ? selectedItems : [item]
        do {
            for member in batch {
                try await store.pin(member.id, to: board.id)
            }
            hooks.playSound(.pin)
            if board.itemCount + batch.count > Pinboard.softLimitItems {
                show(Toast(message: String(localized: "\(board.name) has more than 2,000 items. Search may slow down."), isWarning: true))
            } else if batch.count > 1 {
                show(Toast(message: String(localized: "Pinned \(batch.count) items to \(board.name)")))
            } else {
                show(Toast(message: String(localized: "Pinned to \(board.name)")))
            }
        } catch {
            show(Toast(message: String(localized: "Could not pin this item."), isWarning: true))
        }
    }

    public func pin(itemID: UUID, toBoardID boardID: UUID, at index: Int? = nil) {
        Task {
            if let index {
                try? await store.pin(itemID, to: boardID, at: index)
                return
            }
            var item = items.first { $0.id == itemID }
            if item == nil { item = try? await store.item(itemID) }
            if let item, let board = pinboards.first(where: { $0.id == boardID }) {
                await pin(item, to: board)
            }
        }
    }

    /// Drag-reordering cards on a pinboard.
    public func movePinnedItem(_ itemID: UUID, before targetID: UUID?) {
        guard case .pinboard(let boardID) = tab, let from = items.firstIndex(where: { $0.id == itemID }) else { return }
        var reordered = items
        let moved = reordered.remove(at: from)
        let to = targetID.flatMap { id in reordered.firstIndex { $0.id == id } } ?? reordered.count
        reordered.insert(moved, at: to)
        items = reordered
        Task { try? await store.reorderPins(on: boardID, itemIDs: reordered.map(\.id)) }
    }

    // MARK: Rename

    /// ⌘R: the selected card's header turns into a text field.
    public func requestRenameSelected() {
        guard let item = selectedItem else { return }
        renamingItemID = item.id
    }

    /// Commits a title; an empty one clears it. Called on Return and when the field loses focus.
    public func rename(_ item: ClipItem, to title: String?) {
        guard renamingItemID == item.id else { return }
        renamingItemID = nil
        focusRequest += 1
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let newTitle = trimmed.isEmpty ? nil : trimmed
        guard newTitle != item.title else { return }
        if let index = items.firstIndex(where: { $0.id == item.id }) { items[index].title = newTitle }
        Task { try? await store.setTitle(item.id, title: newTitle) }
    }

    // MARK: Jump to history

    /// Where a card can be shown in context: the Clipboard tab, or a pinboard it is on.
    public enum RevealTarget: Hashable, Sendable {
        case clipboard
        case pinboard(Pinboard)

        public var title: String {
            switch self {
            case .clipboard: String(localized: "Show in Clipboard")
            case .pinboard(let board): String(localized: "Show in \(board.name)")
            }
        }
    }

    /// Offered only when the card lives somewhere other than the list shown now.
    public func revealTargets(for item: ClipItem) -> [RevealTarget] {
        let searching = !query.isEmpty || searchEverywhere
        var targets: [RevealTarget] = []
        if item.inHistory, searching || tab != .clipboard {
            targets.append(.clipboard)
        }
        let names = Set(boardNames[item.id] ?? [])
        for board in pinboards {
            // The current board only while searching; any other board the card is on.
            let offered = tab == .pinboard(board.id) ? searching : names.contains(board.name)
            if offered { targets.append(.pinboard(board)) }
        }
        return targets
    }

    /// ⌘G: shows the selected card in its first target.
    public func revealSelected() async {
        guard let item = selectedItem, let target = revealTargets(for: item).first else { return }
        await reveal(item, in: target)
    }

    /// Clears the search, switches tabs, and scrolls to the card with its
    /// neighbors around it. Older history is paged in until the card is found.
    public func reveal(_ item: ClipItem, in target: RevealTarget) async {
        commitPendingRemoval()
        searchEverywhere = false
        clearSearchState()
        renamingPinboardID = nil
        renamingItemID = nil
        multiSelection = []
        switch target {
        case .clipboard: tab = .clipboard
        case .pinboard(let board): tab = .pinboard(board.id)
        }
        await reloadItems()
        var pages = 0
        while !items.contains(where: { $0.id == item.id }), canLoadMore, pages < 10 {
            let more = (try? await store.history(limit: Self.pageSize, offset: items.count)) ?? []
            let known = Set(items.map(\.id))
            items.append(contentsOf: more.filter { !known.contains($0.id) })
            canLoadMore = more.count == Self.pageSize
            pages += 1
        }
        guard items.contains(where: { $0.id == item.id }) else {
            selectFirst()
            return
        }
        selectedID = item.id
        scrollTarget = item.id
        focusRequest += 1
    }

    // MARK: Copy for AI

    /// The card, or the whole multi-selection when the card is part of it.
    public func copyForAI(_ item: ClipItem) {
        let batch = multiSelection.contains(item.id) || item.id == selectedID ? selectedItems : [item]
        let hooks = self.hooks
        Task { await hooks.copyForAI(batch) }
    }

    /// Every card on a pinboard, oldest first.
    public func copyBoardForAI(_ board: Pinboard) {
        let hooks = self.hooks
        let store = self.store
        Task {
            let items = (try? await store.items(onPinboard: board.id)) ?? []
            await hooks.copyForAI(items)
        }
    }

    // MARK: Other actions

    public func addSelectedToPasteStack() {
        guard let item = selectedItem, let add = hooks.addToPasteStack else { return }
        add(item)
        show(Toast(message: String(localized: "Added to Paste Stack")))
    }

    /// Space: opens Quick Look for the selected card, or closes it.
    public func quickLookSelected() {
        if hooks.isQuickLookVisible() {
            hooks.quickLook(nil)
        } else if let item = selectedItem {
            hooks.quickLook(item)
        }
    }

    /// The card menu's Quick Look: selects the card and previews it, open or not.
    public func quickLook(_ item: ClipItem) {
        select(item)
        hooks.quickLook(item)
    }

    /// Backspace in an empty search field takes off the last filter chip.
    public func removeLastFilter() {
        guard !filterChips.isEmpty else { return }
        filterChips.removeLast()
        focusRequest += 1
        scheduleSearch(immediately: true)
    }

    /// The clear button in the search field: removes text and chips.
    public func escapeSearch() {
        clearSearchState()
        focusRequest += 1
        scheduleSearch(immediately: true)
    }

    /// Empties the field, chips, suggestions and query without running a search.
    /// Clearing the text schedules a debounced search; cancelling after it keeps
    /// the selection where the caller puts it.
    private func clearSearchState() {
        filterChips = []
        suggestions = []
        searchText = ""
        searchTask?.cancel()
        query = SearchQuery()
    }

    /// Escape: cancels a confirmation, closes Quick Look and menus, then clears the search, then closes the shelf.
    public func escape() {
        if pinboardPendingDeletion != nil {
            // The shelf holds Escape as a hot key, so the alert never sees it: Escape is its Cancel.
            pinboardPendingDeletion = nil
        } else if hooks.isQuickLookVisible() {
            hooks.quickLook(nil)
        } else if pinPickerItemID != nil {
            pinPickerItemID = nil
        } else if renamingPinboardID != nil {
            renamingPinboardID = nil
        } else if renamingItemID != nil {
            renamingItemID = nil
            focusRequest += 1
        } else if !suggestions.isEmpty {
            suggestions = []
        } else if !multiSelection.isEmpty {
            multiSelection = []
        } else if !searchText.isEmpty || !filterChips.isEmpty || searchEverywhere || !query.isEmpty {
            searchEverywhere = false
            escapeSearch()
        } else {
            hooks.close()
        }
    }

    public func show(_ toast: Toast, for duration: Duration = .seconds(2)) {
        self.toast = toast
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            if self.toast?.id == toast.id { self.toast = nil }
        }
    }

    /// The count at the right of the top rail.
    public var countLabel: String {
        let selected = selectedItems.count
        if selected > 1 {
            return String(localized: "\(selected) selected")
        }
        if !query.isEmpty || searchEverywhere {
            return String(localized: "\(items.count) results")
        }
        switch tab {
        case .clipboard: return String(localized: "\(historyCount) items")
        case .pinboard: return String(localized: "\(items.count) items")
        }
    }
}
