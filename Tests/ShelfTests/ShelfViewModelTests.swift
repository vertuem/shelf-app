import AppKit
import Carbon.HIToolbox
import ShelfCore
@testable import ShelfUI
import XCTest

@MainActor
final class ShelfViewModelTests: XCTestCase {
    var env: TestEnvironment!
    var model: ShelfViewModel!
    var performed: [(UUID, PasteRequest)] = []
    var performedMany: [([UUID], PasteRequest)] = []
    var closeCount = 0

    override func setUp() async throws {
        env = TestEnvironment()
        try await env.store.open()
        performed = []
        performedMany = []
        closeCount = 0
        model = ShelfViewModel(store: env.store, hooks: ShelfHooks(
            perform: { [weak self] item, request, close in
                self?.performed.append((item.id, request))
                close()
            },
            performMany: { [weak self] items, request, close in
                self?.performedMany.append((items.map(\.id), request))
                close()
            },
            close: { [weak self] in self?.closeCount += 1 }
        ))
        model.searchDebounce = .milliseconds(1)
        model.undoWindow = .milliseconds(100)
    }

    override func tearDown() async throws {
        model.stop()
        env.cleanUp()
    }

    func populate(_ texts: [String]) async throws {
        let start = Date(timeIntervalSinceNow: -1_000)
        for (index, text) in texts.enumerated() {
            _ = try await env.store.insert(Make.text(text, at: start.addingTimeInterval(Double(index))))
        }
    }

    func testFreshInstallIsEmpty() async {
        await model.start()
        XCTAssertTrue(model.hasLoaded)
        XCTAssertTrue(model.items.isEmpty, "the empty state is a message, not a sample card")
        XCTAssertEqual(model.countLabel, "0 items")
    }

    func testLoadsNewestFirstAndSelectsFirst() async throws {
        try await populate(["a", "b", "c"])
        await model.start()
        model.prepareForShow()
        XCTAssertEqual(model.items.map(\.preview), ["c", "b", "a"])
        XCTAssertEqual(model.selectedItem?.preview, "c")
    }

    func testNewCopiesAppearAtTheFront() async throws {
        await model.start()
        _ = try await env.store.insert(Make.text("live"))
        let arrived = await wait { self.model.items.first?.preview == "live" }
        XCTAssertTrue(arrived)
    }

    func testArrowKeysClampAndFollowReadingDirection() async throws {
        try await populate(["a", "b", "c"])
        await model.start()
        model.prepareForShow()
        model.moveSelection(by: -1)
        XCTAssertEqual(model.selectedItem?.preview, "c")
        model.moveSelection(by: 1)
        model.moveSelection(by: 1)
        model.moveSelection(by: 1)
        XCTAssertEqual(model.selectedItem?.preview, "a")
        model.isRightToLeft = true
        model.moveSelection(by: 1)
        XCTAssertEqual(model.selectedItem?.preview, "b")
    }

    func testEnterPastesSelectedAndCloses() async throws {
        try await populate(["a", "b"])
        await model.start()
        model.prepareForShow()
        model.pasteSelected(.paste)
        let done = await wait { self.performed.count == 1 }
        XCTAssertTrue(done)
        XCTAssertEqual(performed.first?.1, .paste)
        XCTAssertEqual(closeCount, 1)
    }

    func testQuickPasteNumbers() async throws {
        try await populate(["a", "b", "c"])
        await model.start()
        model.quickPaste(number: 2, plain: true)
        let done = await wait { self.performed.count == 1 }
        XCTAssertTrue(done)
        XCTAssertEqual(performed.first?.0, model.items[1].id)
        XCTAssertEqual(performed.first?.1, .pastePlain)
        model.quickPaste(number: 9, plain: false) // beyond the strip: ignored
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(performed.count, 1)
    }

    func testSearchFiltersAndEscapeClearsThenCloses() async throws {
        try await populate(["apple pie", "banana bread"])
        await model.start()
        model.prepareForShow()
        model.searchText = "banana"
        let filtered = await wait { self.model.items.map(\.preview) == ["banana bread"] }
        XCTAssertTrue(filtered)
        XCTAssertEqual(model.countLabel, "1 results")
        model.escape()
        XCTAssertEqual(model.searchText, "")
        XCTAssertEqual(closeCount, 0)
        model.escape()
        XCTAssertEqual(closeCount, 1)
    }

    func testCompletedFiltersBecomeChips() async throws {
        try await populate(["text item"])
        _ = try await env.store.insert(Make.image())
        await model.start()
        model.searchText = "type:image "
        XCTAssertEqual(model.filterChips, ["type:image"])
        XCTAssertEqual(model.searchText, "")
        let filtered = await wait { self.model.items.map(\.kind) == [.image] }
        XCTAssertTrue(filtered)
        XCTAssertEqual(model.chipFilters.map(\.key), ["type"])
        model.removeFilter(model.chipFilters[0])
        XCTAssertTrue(model.filterChips.isEmpty)
        let restored = await wait { self.model.items.count == 2 }
        XCTAssertTrue(restored)
        model.searchText = "app:notes text"
        XCTAssertTrue(model.filterChips.isEmpty, "a token is absorbed only once a space follows it")
        model.escape()
        XCTAssertEqual(model.searchText, "")
    }

    func testEscapeWithOnlyChipsClearsTheFilter() async throws {
        try await populate(["text item"])
        _ = try await env.store.insert(Make.image())
        await model.start()
        model.prepareForShow()
        model.searchText = "type:image "
        let filtered = await wait { self.model.items.count == 1 }
        XCTAssertTrue(filtered)
        model.escape()
        let cleared = await wait { self.model.items.count == 2 && self.model.query.isEmpty }
        XCTAssertTrue(cleared)
        XCTAssertEqual(closeCount, 0)
    }

    func testBackgroundCopyKeepsTheSearchSelection() async throws {
        try await populate(["note 1", "note 2", "note 3"])
        await model.start()
        model.searchText = "note"
        let searched = await wait { !self.model.query.isEmpty && self.model.items.count == 3 }
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(searched)
        model.moveSelection(by: 2)
        let selected = model.selectedID
        _ = try await env.store.insert(Make.text("note 4, copied in the background"))
        let refreshed = await wait { self.model.items.count == 4 }
        XCTAssertTrue(refreshed)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(model.selectedID, selected)
    }

    func testCopyingAgainDuringUndoWindowKeepsTheItem() async throws {
        try await populate(["keep me"])
        await model.start()
        model.prepareForShow()
        model.removeSelected()
        _ = try await env.store.insert(Make.text("keep me"))
        try? await Task.sleep(for: .milliseconds(250)) // past the undo window
        let count = try await env.store.historyCount()
        XCTAssertEqual(count, 1)
    }

    func testEmptySearchMessage() async throws {
        try await populate(["a"])
        await model.start()
        model.searchText = "zzz"
        let empty = await wait { self.model.items.isEmpty && !self.model.query.isEmpty }
        XCTAssertTrue(empty)
    }

    func testDeleteOffersUndoThenCommits() async throws {
        try await populate(["keep", "remove"])
        await model.start()
        model.prepareForShow()
        model.removeSelected()
        XCTAssertEqual(model.items.map(\.preview), ["keep"])
        XCTAssertEqual(model.toast?.canUndo, true)
        model.undoRemoval()
        let restored = await wait { self.model.items.count == 2 }
        XCTAssertTrue(restored)

        model.removeSelected()
        let committed = await wait { (try? await self.env.store.historyCount()) == 1 }
        XCTAssertTrue(committed)
    }

    func testPinboardsTabsAndPinning() async throws {
        try await populate(["a", "b"])
        await model.start()
        model.prepareForShow()
        let board = await model.createPinboard()
        XCTAssertNotNil(board)
        XCTAssertEqual(model.renamingPinboardID, board?.id)
        model.rename(board!, to: "Snippets")
        let item = model.items[0]
        await model.pin(item, to: model.pinboards[0])
        XCTAssertEqual(model.toast?.message, "Pinned to Snippets")

        model.nextTab()
        let switched = await wait { self.model.tab == .pinboard(board!.id) && self.model.items.count == 1 }
        XCTAssertTrue(switched)
        model.previousTab()
        let back = await wait { self.model.tab == .clipboard }
        XCTAssertTrue(back)
    }

    func testCmdPWithoutBoardsCreatesOneAndPins() async throws {
        try await populate(["a"])
        await model.start()
        model.prepareForShow()
        model.requestPinSelected()
        let pinned = await wait { self.model.pinboards.first?.itemCount == 1 }
        XCTAssertTrue(pinned)
    }

    func testDeletingAPinboardAsksFirst() async throws {
        await model.start()
        let board = try await env.store.createPinboard(name: "Temp")
        await model.reloadAll()
        model.requestDeletion(of: board)
        XCTAssertEqual(model.pinboardPendingDeletion?.id, board.id)
        model.confirmDeletion()
        let gone = await wait { self.model.pinboards.isEmpty }
        XCTAssertTrue(gone)
    }

    func testGlobalSearchShowsBoardNames() async throws {
        try await populate(["shared item"])
        await model.start()
        let board = try await env.store.createPinboard(name: "Board")
        try await env.store.pin(model.items[0].id, to: board.id)
        model.searchText = "shared"
        model.toggleSearchEverywhere()
        let named = await wait { self.model.boardNames[self.model.items.first?.id ?? UUID()] == ["Board"] }
        XCTAssertTrue(named)
    }

    func testOpeningResetsToClipboardTab() async throws {
        try await populate(["a"])
        await model.start()
        let board = try await env.store.createPinboard(name: "B")
        await model.reloadAll()
        model.switchTo(.pinboard(board.id))
        model.searchText = "x"
        model.prepareForShow()
        XCTAssertEqual(model.tab, .clipboard)
        XCTAssertEqual(model.searchText, "")
    }

    func testQuickLookFollowsTheSelectionAndClosesBeforeEscapeCloses() async throws {
        try await populate(["a", "b", "c"])
        await model.start()
        model.prepareForShow()
        var previewing: ClipItem?
        var isOpen = false
        model.hooks.quickLook = { item in
            previewing = item
            isOpen = item != nil
        }
        model.hooks.isQuickLookVisible = { isOpen }

        model.quickLookSelected()
        XCTAssertEqual(previewing?.preview, "c")
        model.moveSelection(by: 1)
        XCTAssertEqual(previewing?.preview, "b", "the preview follows the arrows")
        model.selectLast()
        XCTAssertEqual(previewing?.preview, "a")
        model.quickLookSelected()
        XCTAssertFalse(isOpen, "Space again closes it")

        model.quickLookSelected()
        model.escape()
        XCTAssertFalse(isOpen)
        XCTAssertEqual(closeCount, 0, "the first Escape only closes the preview")

        model.quickLookSelected()
        model.didHide()
        XCTAssertFalse(isOpen, "closing the shelf closes the preview")
    }

    // MARK: Keys

    func key(_ keyCode: Int, _ characters: String = "", _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
                         keyCode: UInt16(keyCode))!
    }

    func testBackspaceInAnEmptySearchTakesOffTheLastChip() async throws {
        try await populate(["text item"])
        _ = try await env.store.insert(Make.image())
        await model.start()
        model.prepareForShow()
        let controller = ShelfPanelController(model: model, preferences: env.preferences)
        model.searchText = "type:image "
        let filtered = await wait { self.model.items.count == 1 }
        XCTAssertTrue(filtered)

        XCTAssertNil(controller.handleKey(key(kVK_Delete, "\u{7F}")))
        XCTAssertTrue(model.filterChips.isEmpty)
        let restored = await wait { self.model.items.count == 2 }
        XCTAssertTrue(restored)
        XCTAssertNil(model.toast, "nothing was removed")
    }

    func testTabMovesBetweenTabs() async throws {
        try await populate(["a"])
        await model.start()
        model.prepareForShow()
        let board = try await env.store.createPinboard(name: "Board")
        await model.reloadAll()
        let controller = ShelfPanelController(model: model, preferences: env.preferences)

        XCTAssertNil(controller.handleKey(key(kVK_Tab, "\t")))
        XCTAssertEqual(model.tab, .pinboard(board.id))
        XCTAssertNil(controller.handleKey(key(kVK_Tab, "\u{19}", .shift)))
        XCTAssertEqual(model.tab, .clipboard)
    }

    func testEditingKeysGoToTheRenameField() async throws {
        try await populate(["a", "b"])
        await model.start()
        model.prepareForShow()
        let controller = ShelfPanelController(model: model, preferences: env.preferences)
        let board = try await env.store.createPinboard(name: "Board")
        await model.reloadAll()
        model.renamingPinboardID = board.id
        let selected = model.selectedID

        for event in [key(kVK_Home), key(kVK_End), key(kVK_Tab, "\t"), key(kVK_Delete, "\u{7F}"),
                      key(kVK_Delete, "\u{7F}", .command), key(kVK_LeftArrow), key(kVK_Return, "\r")] {
            XCTAssertNotNil(controller.handleKey(event), "keyCode \(event.keyCode)")
        }
        XCTAssertEqual(model.selectedID, selected)
        XCTAssertEqual(model.items.count, 2)
        XCTAssertEqual(model.tab, .clipboard)
        XCTAssertTrue(performed.isEmpty)

        XCTAssertNil(controller.handleKey(key(kVK_Escape, "\u{1B}")))
        XCTAssertNil(model.renamingPinboardID, "Escape cancels the rename")
        XCTAssertEqual(closeCount, 0)
    }

    func testCommandClickingTheCurrentCardTakesItOutOfARange() async throws {
        try await populate(["a", "b", "c", "d"])
        await model.start()
        model.prepareForShow()
        let d = model.items[0], a = model.items[3]
        model.extendSelection(to: a) // Shift-click: d through a, a is current
        XCTAssertEqual(model.selectedItems.map(\.preview), ["d", "c", "b", "a"])
        model.toggleInSelection(a) // ⌘-click the current card
        XCTAssertEqual(model.selectedItems.map(\.preview), ["d", "c", "b"], "the clicked card leaves the selection")
        XCTAssertEqual(model.selectedID, d.id, "another selected card becomes current")
        model.toggleInSelection(model.items[2]) // b
        model.toggleInSelection(d) // the current card again, leaving only c
        XCTAssertEqual(model.selectedItems.map(\.preview), ["c"])
        XCTAssertTrue(model.multiSelection.isEmpty, "one card left is a plain selection")
        model.toggleInSelection(model.items[1]) // ⌘-clicking the only card keeps it
        XCTAssertEqual(model.selectedItems.map(\.preview), ["c"])
    }

    func flags(_ flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55)!
    }

    func testQuickPasteNumbersWaitUntilTheOpeningShortcutIsReleased() async throws {
        try await populate(["a"])
        await model.start()
        let controller = ShelfPanelController(model: model, preferences: env.preferences)
        controller.hintDelay = .milliseconds(20)
        _ = controller.handleFlags(flags([.command, .shift]))
        _ = controller.handleFlags(flags(.command)) // Shift let go first, ⌘ still held from ⇧⌘V
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertFalse(model.showsQuickPasteHints, "no flash of numbers on opening")
        _ = controller.handleFlags(flags([]))
        _ = controller.handleFlags(flags(.command))
        XCTAssertFalse(model.showsQuickPasteHints, "not on a quick tap of ⌘")
        let shown = await wait { self.model.showsQuickPasteHints }
        XCTAssertTrue(shown, "holding ⌘ afterwards shows them")
        _ = controller.handleFlags(flags([]))
        XCTAssertFalse(model.showsQuickPasteHints)
    }

    func testQuickPasteNumbersShowOnTheFirstHoldWhenOpenedWithoutAModifier() async throws {
        try await populate(["a"])
        await model.start()
        let controller = ShelfPanelController(model: model, preferences: env.preferences)
        controller.hintDelay = .milliseconds(20)
        controller.armHints(currentModifiers: []) // opened from the menu bar or shelf-app://open
        _ = controller.handleFlags(flags(.command))
        let shown = await wait { self.model.showsQuickPasteHints }
        XCTAssertTrue(shown, "the first ⌘ hold shows the numbers")

        controller.armHints(currentModifiers: [.command, .shift]) // opened with ⇧⌘V, still held
        _ = controller.handleFlags(flags([]))
        _ = controller.handleFlags(flags(.command))
        let shownAfterRelease = await wait { self.model.showsQuickPasteHints }
        XCTAssertTrue(shownAfterRelease)
    }

    func testHomeAndEndJumpToTheEnds() async throws {
        try await populate(["a", "b", "c"])
        await model.start()
        model.prepareForShow()
        let controller = ShelfPanelController(model: model, preferences: env.preferences)
        XCTAssertNil(controller.handleKey(key(kVK_End)))
        XCTAssertEqual(model.selectedItem?.preview, "a")
        XCTAssertNil(controller.handleKey(key(kVK_Home)))
        XCTAssertEqual(model.selectedItem?.preview, "c")
    }

    // MARK: Multi-selection

    func testShiftArrowsExtendTheSelectionAndReturnPastesThemAll() async throws {
        try await populate(["a", "b", "c", "d"])
        await model.start()
        model.prepareForShow()
        model.moveSelection(by: 1, extending: true)
        model.moveSelection(by: 1, extending: true)
        XCTAssertEqual(model.selectedItems.map(\.preview), ["d", "c", "b"])
        XCTAssertEqual(model.countLabel, "3 selected")
        XCTAssertTrue(model.isSelected(model.items[0]))
        XCTAssertFalse(model.isSelected(model.items[3]))
        model.pasteSelected(.paste)
        let done = await wait { self.performedMany.count == 1 }
        XCTAssertTrue(done)
        XCTAssertEqual(performedMany[0].0, model.items.prefix(3).map(\.id), "pasted in strip order")
        XCTAssertTrue(performed.isEmpty)
        XCTAssertEqual(closeCount, 1)
    }

    func testPlainArrowDropsTheMultiSelection() async throws {
        try await populate(["a", "b", "c"])
        await model.start()
        model.prepareForShow()
        model.moveSelection(by: 1, extending: true)
        XCTAssertEqual(model.selectedItems.count, 2)
        model.moveSelection(by: 1)
        XCTAssertEqual(model.selectedItems.count, 1)
        XCTAssertEqual(model.selectedItem?.preview, "a")
    }

    func testCommandClickTogglesAndShiftClickSelectsARange() async throws {
        try await populate(["a", "b", "c", "d"])
        await model.start()
        model.prepareForShow()
        model.toggleInSelection(model.items[2])
        XCTAssertEqual(model.selectedItems.map(\.preview), ["d", "b"])
        model.toggleInSelection(model.items[2])
        XCTAssertEqual(model.selectedItems.map(\.preview), ["d"])
        model.extendSelection(to: model.items[3])
        XCTAssertEqual(model.selectedItems.map(\.preview), ["d", "c", "b", "a"])
        XCTAssertEqual(model.selectedItem?.preview, "a", "the clicked card becomes the current one")
        model.select(model.items[1])
        XCTAssertEqual(model.selectedItems.map(\.preview), ["c"], "a plain click selects one card")
    }

    func testEscapeClearsTheMultiSelectionBeforeClosing() async throws {
        try await populate(["a", "b"])
        await model.start()
        model.prepareForShow()
        model.moveSelection(by: 1, extending: true)
        model.escape()
        XCTAssertEqual(model.selectedItems.count, 1)
        XCTAssertEqual(closeCount, 0)
        model.escape()
        XCTAssertEqual(closeCount, 1)
    }

    func testEscapeCancelsThePinboardDeletionInsteadOfClosing() async throws {
        let board = try await env.store.createPinboard(name: "Work", color: .blue, icon: "star")
        await model.start()
        model.prepareForShow()
        model.requestDeletion(of: board)
        model.escape()
        XCTAssertNil(model.pinboardPendingDeletion)
        XCTAssertEqual(closeCount, 0)
        let boards = try await env.store.pinboards()
        XCTAssertEqual(boards.map(\.name), ["Work"], "Escape is Cancel, not Delete")
    }

    func testDeleteRemovesEverySelectedCardWithOneUndo() async throws {
        try await populate(["a", "b", "c"])
        await model.start()
        model.prepareForShow()
        model.moveSelection(by: 1, extending: true)
        model.removeSelected()
        XCTAssertEqual(model.items.map(\.preview), ["a"])
        XCTAssertEqual(model.toast?.message, "Removed 2 items from history")
        model.undoRemoval()
        let back = await wait { self.model.items.count == 3 }
        XCTAssertTrue(back)
    }

    func testOpeningClearsTheMultiSelection() async throws {
        try await populate(["a", "b"])
        await model.start()
        model.prepareForShow()
        model.moveSelection(by: 1, extending: true)
        model.prepareForShow()
        XCTAssertEqual(model.selectedItems.count, 1)
    }

    // MARK: Layouts

    func testVerticalMovesFollowTheLayout() async throws {
        try await populate((1...8).map(String.init))
        await model.start()
        model.prepareForShow()
        model.moveSelectionVertically(by: 1)
        XCTAssertEqual(model.selectedIndex, 0, "the horizontal strip has no rows")
        model.layout = ShelfLayout(position: .center)
        XCTAssertEqual(model.layout.columns, 3)
        model.moveSelectionVertically(by: 1)
        XCTAssertEqual(model.selectedIndex, 3)
        model.moveSelection(by: 1)
        XCTAssertEqual(model.selectedIndex, 4)
        model.moveSelectionVertically(by: -1)
        XCTAssertEqual(model.selectedIndex, 1)
        model.layout = ShelfLayout(position: .left)
        XCTAssertTrue(model.layout.isCompact)
        model.moveSelectionVertically(by: 1)
        XCTAssertEqual(model.selectedIndex, 2, "a column moves one card per row")
    }

    func testPageKeysMoveByTheVisibleCount() async throws {
        try await populate((1...20).map(String.init))
        await model.start()
        model.prepareForShow()
        model.visibleCardCount = 5
        model.moveSelectionByPage(1)
        XCTAssertEqual(model.selectedIndex, 5)
        model.moveSelectionByPage(1)
        model.moveSelectionByPage(1)
        model.moveSelectionByPage(1)
        XCTAssertEqual(model.selectedIndex, 19, "clamped at the end")
        model.moveSelectionByPage(-1)
        XCTAssertEqual(model.selectedIndex, 14)
    }

    func testKeyboardScrollsOneCardPastTheSelection() async throws {
        try await populate(["a", "b", "c", "d"])
        await model.start()
        model.prepareForShow()
        model.moveSelection(by: 1)
        XCTAssertEqual(model.selectedItem?.preview, "c")
        XCTAssertEqual(model.items.first { $0.id == model.scrollTarget }?.preview, "b", "one card of lookahead")
        model.selectLast()
        XCTAssertEqual(model.scrollTarget, model.items.last?.id, "nothing beyond the last card")
    }

    func testCardsThatFitPerLayout() {
        XCTAssertEqual(CardStrip.cardsThatFit(in: CGSize(width: 1_440, height: 244), layout: .bottom), 6)
        XCTAssertEqual(CardStrip.cardsThatFit(in: CGSize(width: 256, height: 900), layout: ShelfLayout(position: .left)), 3)
        XCTAssertEqual(CardStrip.cardsThatFit(in: CGSize(width: 680, height: 540), layout: ShelfLayout(position: .center)), 6)
        XCTAssertEqual(CardStrip.cardsThatFit(in: .zero, layout: .bottom), 1)
    }

    // MARK: Filter suggestions

    func testTypingAFilterKeyOffersSuggestionsAndTabAcceptsOne() async throws {
        try await populate(["from notes"])
        _ = try await env.store.insert(Make.text("from safari", app: "Safari", bundleID: "com.apple.Safari"))
        _ = try await env.store.insert(Make.image())
        await model.start()
        model.prepareForShow()
        XCTAssertFalse(model.hasSuggestions)
        model.searchText = "type:"
        XCTAssertEqual(model.suggestions.map(\.label).prefix(3), ["Text", "Rich Text", "Link"])
        model.searchText = "type:im"
        XCTAssertEqual(model.suggestions.map(\.token), ["type:image"])
        model.acceptSuggestion()
        XCTAssertEqual(model.filterChips, ["type:image"])
        XCTAssertEqual(model.searchText, "")
        XCTAssertFalse(model.hasSuggestions)
        let filtered = await wait { self.model.items.map(\.kind) == [.image] }
        XCTAssertTrue(filtered)

        model.escapeSearch()
        model.searchText = "hello app:"
        XCTAssertEqual(Set(model.suggestions.map(\.label)), ["Notes", "Safari", "Preview"])
        model.moveSuggestion(by: -1)
        XCTAssertEqual(model.suggestionIndex, model.suggestions.count - 1)
        model.moveSuggestion(by: 1)
        XCTAssertEqual(model.suggestionIndex, 0)
        model.searchText = "hello app:saf"
        XCTAssertEqual(model.suggestions.map(\.token), ["app:Safari"])
        model.acceptSuggestion(model.suggestions[0])
        XCTAssertEqual(model.filterChips, ["app:Safari"])
        XCTAssertEqual(model.searchText, "hello ", "the free text before the filter stays, with its space")
        model.searchText += "world"
        XCTAssertEqual(model.searchText, "hello world", "the next word does not join the last one")
    }

    func testEscapeDismissesSuggestionsBeforeClearingTheSearch() async throws {
        try await populate(["a"])
        await model.start()
        model.prepareForShow()
        model.searchText = "type:"
        XCTAssertTrue(model.hasSuggestions)
        model.escape()
        XCTAssertFalse(model.hasSuggestions)
        XCTAssertEqual(model.searchText, "type:")
        model.escape()
        XCTAssertEqual(model.searchText, "")
        XCTAssertEqual(closeCount, 0)
    }

    func testPinnedSuggestionsListTheBoards() async throws {
        try await populate(["a"])
        _ = try await env.store.createPinboard(name: "Work")
        _ = try await env.store.createPinboard(name: "Snippets")
        await model.start()
        model.prepareForShow()
        model.searchText = "pinned:s"
        XCTAssertEqual(model.suggestions.map(\.token), ["pinned:Snippets"])
    }

    // MARK: Rename and jump to history

    func testRenameSetsATitleAndEscapeCancels() async throws {
        try await populate(["a", "b"])
        await model.start()
        model.prepareForShow()
        model.requestRenameSelected()
        XCTAssertEqual(model.renamingItemID, model.items[0].id)
        model.escape()
        XCTAssertNil(model.renamingItemID)
        XCTAssertEqual(closeCount, 0)

        model.requestRenameSelected()
        model.rename(model.items[0], to: "  Invite  ")
        XCTAssertNil(model.renamingItemID)
        XCTAssertEqual(model.items[0].title, "Invite")
        let stored = await wait { (try? await self.env.store.item(self.model.items[0].id))??.title == "Invite" }
        XCTAssertTrue(stored)
        model.requestRenameSelected()
        model.rename(model.items[0], to: "")
        XCTAssertNil(model.items[0].title, "an empty title clears it")
    }

    func testRevealShowsASearchResultInContext() async throws {
        try await populate((1...250).map { "item \($0)" })
        await model.start()
        model.prepareForShow()
        XCTAssertEqual(model.items.count, 200, "the first page")
        model.searchText = "item 12"
        let found = await wait { self.model.items.contains { $0.preview == "item 12" } }
        XCTAssertTrue(found)
        let result = try XCTUnwrap(model.items.first { $0.preview == "item 12" })
        XCTAssertEqual(model.revealTargets(for: result), [.clipboard])
        await model.reveal(result, in: .clipboard)
        XCTAssertEqual(model.searchText, "")
        XCTAssertTrue(model.query.isEmpty)
        XCTAssertEqual(model.selectedItem?.preview, "item 12")
        XCTAssertEqual(model.scrollTarget, result.id)
        XCTAssertGreaterThan(model.items.count, 200, "older pages were loaded until the card was found")
        let index = try XCTUnwrap(model.selectedIndex)
        XCTAssertEqual(model.items[index - 1].preview, "item 13", "neighbors around it")
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(model.selectedItem?.preview, "item 12", "the cleared search did not reset the selection")
    }

    func testRevealTargetsPointAwayFromTheCurrentList() async throws {
        try await populate(["a"])
        let board = try await env.store.createPinboard(name: "Work")
        let stored = try await env.store.history()
        try await env.store.pin(stored[0].id, to: board.id)
        await model.start()
        model.prepareForShow()
        let item = model.items[0]
        XCTAssertTrue(model.revealTargets(for: item).isEmpty, "already in the Clipboard list")
        model.toggleSearchEverywhere()
        model.searchText = "a"
        let searched = await wait { !self.model.boardNames.isEmpty }
        XCTAssertTrue(searched)
        let targets = model.revealTargets(for: model.items[0])
        XCTAssertEqual(targets.map(\.title), ["Show in Clipboard", "Show in Work"])
        await model.reveal(model.items[0], in: .pinboard(board))
        XCTAssertEqual(model.tab, .pinboard(board.id))
        XCTAssertEqual(model.selectedItem?.id, item.id)
    }

    func testCopyForAIUsesTheSelection() async throws {
        var received: [[String]] = []
        model.hooks.copyForAI = { items in received.append(items.map(\.preview)) }
        try await populate(["a", "b", "c"])
        await model.start()
        model.prepareForShow()
        model.moveSelection(by: 1, extending: true)
        model.copyForAI(model.items[0])
        let done = await wait { received.count == 1 }
        XCTAssertTrue(done)
        XCTAssertEqual(received[0], ["c", "b"])
        model.copyForAI(model.items[2])
        let again = await wait { received.count == 2 }
        XCTAssertTrue(again)
        XCTAssertEqual(received[1], ["a"], "a card outside the selection goes alone")
    }
}
