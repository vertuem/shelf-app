import AppKit
import Carbon.HIToolbox
import KeyboardShortcuts
import ShelfCore
import SwiftUI

/// The shelf window: a borderless, non-activating panel across the bottom of
/// the screen. Non-activating means the app the user is pasting into stays
/// frontmost the whole time.
public final class ShelfPanel: NSPanel {
    /// The bottom shelf: full width, this tall.
    public static let height: CGFloat = 300
    /// The left and right shelves: full height, this wide.
    public static let columnWidth: CGFloat = 256
    /// The centered panel: three cards across, two rows and a peek of the third.
    public static let centerSize = CGSize(width: 680, height: 600)
    /// One above the Dock, so the edge shelves cover it. Not the pop-up menu
    /// level: windows there are treated like menus, and Escape and the other
    /// keys stopped reaching the shelf.
    public static let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)

    public init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: Self.height),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        isFloatingPanel = true
        // After isFloatingPanel, which resets the level to .floating: below the
        // Dock, so the bottom shelf would sit behind it.
        level = Self.level
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        animationBehavior = .none
        isReleasedWhenClosed = false
    }

    /// A non-activating panel refuses key status by default; without it the
    /// search field could not take typing.
    override public var canBecomeKey: Bool { true }
    override public var canBecomeMain: Bool { false }
}

/// Shows, hides and positions the shelf and turns key presses into actions.
@MainActor
public final class ShelfPanelController {
    public let panel = ShelfPanel()
    public let model: ShelfViewModel
    private let presentation = ShelfPresentation()
    private let preferences: Preferences
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    /// False from opening until every modifier is up. The shortcut that opened
    /// the shelf (⇧⌘V) is usually still held then, and the quick-paste numbers
    /// flashed on every card for a moment.
    private var hintsArmed = false
    /// The numbers appear only once the modifier has been held this long, so a
    /// quick ⌘F or ⌘P does not flash them either.
    var hintDelay: Duration = .milliseconds(350)
    private var hintTask: Task<Void, Never>?
    private var escapeTask: Task<Void, Never>?
    private var isTrackingMenu = false
    /// When the shelf last opened: app switches caused by the opening itself
    /// (a click on the menu bar icon) must not close it again.
    private var shownAt = Date.distantPast
    private var systemObservers: [NSObjectProtocol] = []
    public private(set) var isVisible = false
    /// The app that was frontmost when the shelf opened: the paste target.
    public private(set) var targetBundleID: String?

    public init(model: ShelfViewModel, preferences: Preferences) {
        self.model = model
        self.preferences = preferences
        let hosting = NSHostingView(rootView: ShelfView(model: model, presentation: presentation))
        hosting.sizingOptions = []
        panel.contentView = hosting
        panel.setAccessibilityLabel(String(localized: "Clipboard history"))
        observeSystem()
    }

    public func toggle() {
        reconcile()
        if isVisible, !panel.isKeyWindow {
            // Open but the keyboard went elsewhere: the press means "let me type here".
            panel.makeKey()
            if panel.isKeyWindow { return }
        }
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    /// The system can take the panel off screen behind the controller's back
    /// (Hide Others, a full-screen Space closing). AppKit may even still call
    /// it visible while the window server has it on no Space. Without this the
    /// shelf counted as open, so ⇧⌘V and `shelf-app://open` did nothing.
    public func reconcile() {
        guard isVisible, !(panel.isVisible && panel.isOnActiveSpace) else { return }
        Log.ui.notice("The shelf was off screen while marked open")
        hide(animated: false)
    }

    /// `takeFocus: false` shows the shelf without taking the keyboard, for review captures.
    public func show(takeFocus: Bool = true) {
        reconcile()
        guard !isVisible else { return }
        isVisible = true
        shownAt = Date()
        // No menu can be open while the shelf opens; a missed end-of-tracking
        // notification must not keep Escape released for good.
        isTrackingMenu = false
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        targetBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let layout = position()
        model.layout = layout
        panel.sharingType = preferences.showDuringScreenSharing ? .readOnly : .none
        model.prepareForShow()

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let (offset, horizontal, scale) = Self.hiddenTransform(for: layout.position, reduceMotion: reduceMotion)
        presentation.offset = offset
        presentation.horizontalOffset = horizontal
        presentation.scale = scale
        presentation.opacity = 0
        // A panel AppKit still counts as ordered in (a fade that never finished,
        // a lost Space) would ignore orderFront; take it out first.
        if panel.isVisible { panel.orderOut(nil) }
        panel.orderFrontRegardless()
        if takeFocus { panel.makeKey() }
        withAnimation(reduceMotion ? .easeOut(duration: 0.16) : .spring(duration: 0.16, bounce: 0.2)) {
            presentation.offset = 0
            presentation.horizontalOffset = 0
            presentation.scale = 1
            presentation.opacity = 1
        }
        armHints(currentModifiers: NSEvent.modifierFlags)
        installMonitors()
        if takeFocus {
            claimEscape()
            ensureKey()
        }
    }

    /// Over a full-screen app the panel is still joining that space when
    /// `makeKey()` runs, and the keyboard stayed with the app underneath. Ask
    /// again once it is on screen.
    private func ensureKey() {
        Task { [weak self] in
            for delay in [Duration.milliseconds(50), .milliseconds(200)] {
                try? await Task.sleep(for: delay)
                guard let self, self.isVisible else { return }
                if self.panel.isKeyWindow { return }
                self.panel.makeKey()
            }
            guard let self, self.isVisible, !self.panel.isKeyWindow else { return }
            Log.ui.notice("The shelf opened without the keyboard")
        }
    }

    /// Where the content sits before it slides in: 24 points off its screen edge,
    /// or slightly shrunk for the centered panel.
    static func hiddenTransform(for position: ShelfPosition, reduceMotion: Bool) -> (offset: CGFloat, horizontal: CGFloat, scale: Double) {
        guard !reduceMotion else { return (0, 0, 1) }
        switch position {
        case .bottom: return (24, 0, 1)
        case .left: return (0, -24, 1)
        case .right: return (0, 24, 1)
        case .center: return (0, 0, 0.96)
        }
    }

    /// Hides with the reverse animation. Pasting hides instantly so the
    /// keystroke reaches the target app without waiting.
    public func hide(animated: Bool = true) {
        guard isVisible else { return }
        isVisible = false
        hintTask?.cancel()
        removeMonitors()
        releaseEscape()
        model.didHide()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if animated {
            let (offset, horizontal, scale) = Self.hiddenTransform(for: model.layout.position, reduceMotion: reduceMotion)
            withAnimation(.easeIn(duration: 0.12)) {
                presentation.offset = offset
                presentation.horizontalOffset = horizontal
                presentation.scale = scale
                presentation.opacity = 0
            } completion: { [weak self] in
                guard let self, !self.isVisible else { return }
                self.panel.orderOut(nil)
            }
            // SwiftUI may never call the completion for a window that is not
            // being drawn; the panel must still leave the screen.
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard let self, !self.isVisible, self.panel.isVisible else { return }
                self.panel.orderOut(nil)
            }
        } else {
            presentation.opacity = 0
            panel.orderOut(nil)
        }
    }

    /// Places the panel on the screen under the cursor for the position in
    /// Settings: the full width of the bottom edge, the full height of the left
    /// or right edge under the menu bar, or centered a little above the middle
    /// like Spotlight. Returns the layout for that position.
    @discardableResult
    private func position() -> ShelfLayout {
        let position = preferences.shelfPosition
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else {
            return ShelfLayout(position: position)
        }
        panel.setFrame(Self.frame(for: position, screen: screen.frame, visible: screen.visibleFrame), display: false)
        return ShelfLayout(position: position)
    }

    /// The edge positions sit on the screen edge itself and cover the Dock while
    /// open: stopping at the Dock left the shelf hovering in the
    /// middle of the screen. Only the menu bar is kept clear.
    static func frame(for position: ShelfPosition, screen frame: NSRect, visible: NSRect) -> NSRect {
        let columnHeight = visible.maxY - frame.minY
        switch position {
        case .bottom:
            return NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: ShelfPanel.height)
        case .left:
            return NSRect(x: frame.minX, y: frame.minY, width: ShelfPanel.columnWidth, height: columnHeight)
        case .right:
            return NSRect(x: frame.maxX - ShelfPanel.columnWidth, y: frame.minY, width: ShelfPanel.columnWidth, height: columnHeight)
        case .center:
            let width = min(ShelfPanel.centerSize.width, visible.width - 40)
            let height = min(ShelfPanel.centerSize.height, visible.height - 80)
            // Spotlight sits in the upper part of the screen; keep the panel above
            // the middle even when it is tall by capping the top margin.
            let topMargin = min(visible.height * 0.16, (visible.height - height) * 0.4)
            let top = visible.maxY - topMargin
            return NSRect(x: (visible.midX - width / 2).rounded(), y: (top - height).rounded(), width: width, height: height)
        }
    }

    // MARK: Event monitors

    private func installMonitors() {
        removeMonitors()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .scrollWheel]) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            switch event.type {
            case .flagsChanged: return self.handleFlags(event)
            case .scrollWheel: return self.handleScroll(event)
            default: return self.handleKey(event)
            }
        }
        // Clicks in other apps close the shelf; clicks inside it never reach this monitor.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    private func removeMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        keyMonitor = nil
        clickMonitor = nil
    }

    // MARK: Escape

    /// While the shelf is open, Escape is a system hot key. The panel does not
    /// always hold the keyboard (over a full-screen app, after ⌘-Tab or a drag
    /// out), and a plain Escape then reached the app underneath, where it left
    /// full screen. Released while a menu is open, so Escape still closes the menu.
    private func claimEscape() {
        guard escapeTask == nil, !isTrackingMenu else { return }
        escapeTask = Task { [weak self] in
            for await _ in KeyboardShortcuts.events(.keyDown, for: KeyboardShortcuts.Shortcut(.escape)) {
                self?.handleEscape()
            }
        }
    }

    private func releaseEscape() {
        escapeTask?.cancel()
        escapeTask = nil
    }

    private func handleEscape() {
        guard panel.isVisible else {
            reconcile()
            return
        }
        // Another Shelf window has the keyboard (the delete alert, the Paste Stack,
        // Quick Look): the hot key took Escape from it, so pass it on.
        if let window = NSApp.keyWindow, window !== panel, window.isVisible,
           let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                         context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                         isARepeat: false, keyCode: UInt16(kVK_Escape)) {
            NSApp.postEvent(escape, atStart: false)
            return
        }
        // Escape cancels a Japanese, Chinese or Korean composition before anything else.
        if let editor = fieldEditor, editor.hasMarkedText() {
            editor.inputContext?.discardMarkedText()
            editor.unmarkText()
            return
        }
        model.escape()
    }

    private func observeSystem() {
        let center = NotificationCenter.default
        systemObservers = [
            center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isTrackingMenu = true
                    self?.releaseEscape()
                }
            },
            center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isTrackingMenu = false
                    if self.isVisible { self.claimEscape() }
                }
            },
            // Hide Others hides the shelf too; keep the controller in step.
            center.addObserver(forName: NSApplication.didHideNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.hide(animated: false) }
            },
            // Another app becoming active (⌘-Tab, Open Link) takes the keyboard; close
            // the shelf as a click outside does, rather than leave it open and deaf.
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                MainActor.assumeIsolated {
                    // The app being pasted into coming back to the front is not a switch.
                    guard let self, app?.bundleIdentifier != self.targetBundleID,
                          Date().timeIntervalSince(self.shownAt) > 0.5 else { return }
                    self.hide()
                }
            },
        ]
    }

    /// Armed straight away when no modifier is down as the shelf opens (the menu
    /// bar, `shelf-app://open`); otherwise once the opening shortcut is let go.
    func armHints(currentModifiers: NSEvent.ModifierFlags) {
        hintsArmed = currentModifiers.isDisjoint(with: [.command, .shift, .option, .control])
    }

    func handleFlags(_ event: NSEvent) -> NSEvent? {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard hintsArmed else {
            if flags.isEmpty { hintsArmed = true }
            return event
        }
        hintTask?.cancel()
        guard flags.contains(quickPasteFlag), flags.subtracting([quickPasteFlag, plainTextFlag]).isEmpty else {
            model.showsQuickPasteHints = false
            return event
        }
        let delay = hintDelay
        hintTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.model.showsQuickPasteHints = true
        }
        return event
    }

    /// A mouse wheel only scrolls up and down. On the horizontal strip that
    /// would do nothing, so its ticks are turned sideways. Trackpads already
    /// scroll sideways and pass through untouched.
    private func handleScroll(_ event: NSEvent) -> NSEvent? {
        guard model.layout.isHorizontal, !event.hasPreciseScrollingDeltas,
              event.scrollingDeltaX == 0, event.scrollingDeltaY != 0 else { return event }
        guard let turned = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2,
                                   wheel1: 0, wheel2: Int32(event.scrollingDeltaY.rounded()), wheel3: 0) else { return event }
        turned.location = event.cgEvent?.location ?? turned.location
        return NSEvent(cgEvent: turned)
    }

    private var quickPasteFlag: NSEvent.ModifierFlags {
        switch preferences.quickPasteModifier {
        case .command: .command
        case .option: .option
        case .control: .control
        }
    }

    private var plainTextFlag: NSEvent.ModifierFlags {
        preferences.plainTextModifier == .shift ? .shift : .option
    }

    private var isEditingText: Bool {
        model.renamingPinboardID != nil || model.renamingItemID != nil
    }

    /// The field editor, when the search field or a rename field has focus.
    private var fieldEditor: NSTextView? {
        panel.firstResponder as? NSTextView
    }

    /// The keyboard map (the README lists it). Returns nil for keys the shelf handled.
    func handleKey(_ event: NSEvent) -> NSEvent? {
        // Japanese, Chinese and Korean input methods use Return, Space, Escape,
        // arrows and Delete while composing; those keys belong to the field then.
        if fieldEditor?.hasMarkedText() == true {
            return event
        }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let command = flags.contains(.command)
        // A key pressed with ⌘ is a shortcut, not a request for the numbers.
        hintTask?.cancel()
        let keyCode = Int(event.keyCode)

        if Hotkeys.matches(event, .nextPinboard) {
            withAnimation(.smooth(duration: 0.3)) { model.nextTab() }
            return nil
        }
        if Hotkeys.matches(event, .previousPinboard) {
            withAnimation(.smooth(duration: 0.3)) { model.previousTab() }
            return nil
        }

        switch keyCode {
        case kVK_Escape:
            model.escape()
            return nil
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if isEditingText { return event }
            if flags.isEmpty, model.hasSuggestions {
                model.acceptSuggestion()
                return nil
            }
            if flags == .command {
                model.pasteSelected(.pastePlain)
            } else if flags == .shift {
                model.pasteSelected(.copy)
            } else if flags == .option, preferences.plainTextModifier == .option {
                model.pasteSelected(.pastePlain)
            } else {
                model.pasteSelected(.paste)
            }
            return nil
        case kVK_LeftArrow, kVK_RightArrow:
            // Shift extends the selection to the cards passed over.
            if isEditingText || !flags.subtracting(.shift).isEmpty { return event }
            model.moveSelection(by: keyCode == kVK_LeftArrow ? -1 : 1, extending: flags.contains(.shift))
            return nil
        case kVK_UpArrow, kVK_DownArrow:
            if isEditingText { return event }
            if model.hasSuggestions, flags.isEmpty {
                model.moveSuggestion(by: keyCode == kVK_UpArrow ? -1 : 1)
                return nil
            }
            // A row in the grid, a card in the column; nothing on the horizontal strip.
            guard !model.layout.isHorizontal, flags.subtracting(.shift).isEmpty else { return event }
            model.moveSelectionVertically(by: keyCode == kVK_UpArrow ? -1 : 1, extending: flags.contains(.shift))
            return nil
        case kVK_PageUp, kVK_PageDown:
            if isEditingText || !flags.isEmpty { return event }
            model.moveSelectionByPage(keyCode == kVK_PageUp ? -1 : 1)
            return nil
        case kVK_Home, kVK_End:
            if isEditingText || !flags.isEmpty { return event }
            if keyCode == kVK_Home { model.selectFirst() } else { model.selectLast() }
            return nil
        case kVK_Tab:
            // Without this, Tab moves focus out of the search field and typing stops working.
            if isEditingText || !flags.subtracting(.shift).isEmpty { return event }
            if model.hasSuggestions, flags.isEmpty {
                model.acceptSuggestion()
                return nil
            }
            withAnimation(.smooth(duration: 0.3)) {
                if flags.contains(.shift) { model.previousTab() } else { model.nextTab() }
            }
            return nil
        case kVK_Space where flags.isEmpty && !isEditingText && (model.searchText.isEmpty || model.hooks.isQuickLookVisible()):
            model.quickLookSelected()
            return nil
        case kVK_Delete, kVK_ForwardDelete:
            if isEditingText { return event }
            if flags == .command {
                model.removeSelected()
                return nil
            }
            guard flags.isEmpty, model.searchText.isEmpty else { return event }
            if keyCode == kVK_Delete, !model.filterChips.isEmpty {
                model.removeLastFilter()
            } else {
                model.removeSelected()
            }
            return nil
        default:
            break
        }

        if !isEditingText, let number = Self.digit(for: keyCode), flags.contains(quickPasteFlag),
           flags.subtracting([quickPasteFlag, plainTextFlag]).isEmpty {
            model.quickPaste(number: number, plain: flags.contains(plainTextFlag) && plainTextFlag != quickPasteFlag)
            return nil
        }

        guard command, let key = event.charactersIgnoringModifiers?.lowercased() else { return event }
        let shift = flags.contains(.shift)
        switch (key, shift) {
        case ("p", false) where !isEditingText:
            model.requestPinSelected()
        case ("r", false) where !isEditingText:
            model.requestRenameSelected()
        case ("g", false) where !isEditingText:
            Task { await model.revealSelected() }
        case ("f", false):
            model.focusSearch()
        case ("f", true):
            model.toggleSearchEverywhere()
        case ("z", false) where model.canUndo:
            model.undoRemoval()
        case (",", false):
            hide(animated: false)
            model.hooks.openSettings()
        case ("/", _), ("?", _):
            model.hooks.showCheatSheet()
        case ("w", false):
            hide()
        case ("c", false) where (fieldEditor?.selectedRange().length ?? 0) == 0:
            model.pasteSelected(.copy)
        case ("v", false), ("c", false), ("x", false), ("a", false), ("z", _):
            // No Edit menu while the app is inactive; route text editing by hand.
            return editText(key: key, shift: shift) ? nil : event
        default:
            return event
        }
        return nil
    }

    private func editText(key: String, shift: Bool) -> Bool {
        guard let editor = fieldEditor else { return false }
        switch key {
        case "v": editor.paste(nil)
        case "c": editor.copy(nil)
        case "x": editor.cut(nil)
        case "a": editor.selectAll(nil)
        case "z" where shift: editor.undoManager?.redo()
        case "z": editor.undoManager?.undo()
        default: return false
        }
        return true
    }

    static func digit(for keyCode: Int) -> Int? {
        let codes = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        return codes.firstIndex(of: keyCode).map { $0 + 1 }
    }
}
