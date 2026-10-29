import AppKit
@testable import Shelf
import ShelfCore
@testable import ShelfUI
import SwiftUI
import XCTest

/// UI tests, kept to a handful. They drive the models the
/// views bind to and render every screen offscreen; XCUITest needs an Xcode
/// UI-testing target that a Swift package cannot declare.
@MainActor
final class UIFlowTests: XCTestCase {
    final class Backend: OnboardingBackend {
        var isAccessibilityGranted = false
        var requested = 0
        var snippets = 0
        var finished: [Bool] = []
        var runningClipboardManagers = ["Maccy"]
        var clipboardAccess = ClipboardAccess.notAskedYet
        var clipboardSettingsOpened = 0
        var loginItemState = LoginItemState.afterSetup
        func turnOnLoginItem() { loginItemState = .on }
        func requestAccessibility() { requested += 1 }
        /// macOS shows its alert; here the user chooses Allow.
        func requestClipboardAccess() { clipboardAccess = .allowed }
        func openClipboardSettings() { clipboardSettingsOpened += 1 }
        func createSnippetsPinboard() async { snippets += 1 }
        func finishOnboarding(accessibilitySkipped: Bool) { finished.append(accessibilitySkipped) }
    }

    func testOnboardingWithAccessibilitySkipped() async {
        let backend = Backend()
        let flow = OnboardingFlow(backend: backend)
        XCTAssertEqual(flow.step, .welcome)
        XCTAssertFalse(flow.canGoBack)
        flow.next()
        XCTAssertEqual(flow.step, .permissions)
        XCTAssertTrue(flow.canSkip)
        flow.requestAccessibility()
        XCTAssertEqual(backend.requested, 1)
        flow.skipAccessibility()
        XCTAssertEqual(flow.step, .hotkey)
        await flow.finish()
        await flow.finish() // a second Done does nothing
        XCTAssertEqual(backend.snippets, 1)
        XCTAssertEqual(backend.finished, [true])
    }

    func testOnboardingWithAccessibilityGranted() async {
        let backend = Backend()
        let flow = OnboardingFlow(backend: backend)
        flow.next()
        backend.isAccessibilityGranted = true
        flow.refreshAccessibility()
        XCTAssertTrue(flow.canSkip, "reading the clipboard is still to do")
        flow.requestClipboardAccess()
        XCTAssertEqual(flow.clipboardAccess, .allowed)
        XCTAssertTrue(flow.permissionsDone)
        XCTAssertFalse(flow.canSkip)
        flow.next()
        flow.createSnippets = false
        flow.back()
        XCTAssertEqual(flow.step, .permissions)
        flow.next()
        await flow.finish()
        XCTAssertEqual(backend.snippets, 0)
        XCTAssertEqual(backend.finished, [false])
    }

    func testFinishingOnboardingInTheAppAppliesDefaults() async throws {
        let services = AppServices(environment: ["SHELF_EPHEMERAL": "1"])
        let defaults = services.preferences.defaults
        let keys = [PrefKey.onboardingCompleted, PrefKey.pasteMode]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }
        defaults.set(false, forKey: PrefKey.onboardingCompleted)
        defaults.removeObject(forKey: PrefKey.pasteMode)

        try await services.store.open()
        await services.createSnippetsPinboard()
        await services.createSnippetsPinboard()
        let boards = try await services.store.pinboards()
        XCTAssertEqual(boards.map(\.name), ["Snippets"], "one click, one board")
        services.finishOnboarding(accessibilitySkipped: true)
        XCTAssertTrue(defaults.bool(forKey: PrefKey.onboardingCompleted))
        XCTAssertEqual(services.preferences.pasteMode, .toActiveApp, "granting Accessibility later must be enough to paste")
    }

    /// Every setting: its key, its default, and that a change persists.
    func testEverySettingHasItsDefaultAndPersists() {
        let suite = "settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)

        XCTAssertFalse(preferences.copySound)
        XCTAssertTrue(preferences.pasteSound)
        XCTAssertFalse(defaults.bool(forKey: PrefKey.showInMenuBar), "invisible by default: no menu bar icon until turned on")
        XCTAssertEqual(preferences.shelfPosition, .bottom)
        XCTAssertEqual(preferences.pasteMode, .toActiveApp)
        XCTAssertFalse(preferences.restorePreviousClipboard)
        XCTAssertFalse(preferences.alwaysPastePlainText)
        XCTAssertEqual(preferences.keepHistory, .month)
        XCTAssertFalse(preferences.showDuringScreenSharing)
        XCTAssertFalse(preferences.generateLinkPreviews)
        XCTAssertTrue(preferences.recognizeTextInImages, "on by default: recognition runs on this Mac and nothing leaves it")
        XCTAssertTrue(preferences.ignoreConfidential)
        XCTAssertTrue(preferences.ignoreTransient)
        XCTAssertFalse(preferences.captureWhileLocked)
        XCTAssertEqual(preferences.maxItemBytes, 10 * 1_024 * 1_024)
        XCTAssertTrue(preferences.ignoredApps.isSuperset(of: ["com.apple.keychainaccess", "com.apple.Passwords", "com.1password.1password", "com.bitwarden.desktop"]))
        XCTAssertTrue(preferences.encryptAtRest)
        XCTAssertFalse(preferences.detectSecrets)
        XCTAssertEqual(preferences.quickPasteModifier, .command)
        XCTAssertEqual(preferences.plainTextModifier, .shift)

        defaults.set(PasteMode.toClipboard.rawValue, forKey: PrefKey.pasteMode)
        defaults.set(RetentionPeriod.forever.rawValue, forKey: PrefKey.keepHistory)
        defaults.set(25, forKey: PrefKey.maxItemMegabytes)
        defaults.set(QuickPasteModifier.option.rawValue, forKey: PrefKey.quickPasteModifier)
        defaults.set(ShelfPosition.center.rawValue, forKey: PrefKey.shelfPosition)
        let reread = Preferences(defaults: UserDefaults(suiteName: suite)!)
        XCTAssertEqual(reread.shelfPosition, .center)
        XCTAssertEqual(reread.pasteMode, .toClipboard)
        XCTAssertEqual(reread.keepHistory, .forever)
        XCTAssertEqual(reread.maxItemBytes, 25 * 1_024 * 1_024)
        XCTAssertEqual(reread.quickPasteModifier, .option)
    }

    func testPausingAndResumingCapture() async throws {
        let services = AppServices(environment: ["SHELF_EPHEMERAL": "1"])
        let saved = services.preferences.pausedUntil
        defer { services.preferences.pausedUntil = saved }
        services.handle(URL(string: "shelf-app://pause?minutes=15")!)
        let until = try XCTUnwrap(services.pausedUntil)
        XCTAssertEqual(until.timeIntervalSinceNow, 900, accuracy: 5)
        XCTAssertTrue(services.preferences.isPaused())
        services.handle(URL(string: "shelf-app://resume")!)
        XCTAssertNil(services.pausedUntil)
        services.handle(URL(string: "shelf-app://pause")!)
        XCTAssertEqual(services.pausedUntil, .distantFuture)
        services.resume()
        XCTAssertNil(services.pausedUntil)
        // The pause hotkey toggles.
        services.togglePause()
        XCTAssertEqual(services.pausedUntil, .distantFuture)
        services.togglePause()
        XCTAssertNil(services.pausedUntil)
    }

    /// Each screen renders in light and dark without crashing and draws something.
    func testShelfRenders() async throws {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        try await env.store.open()
        _ = try await env.store.insert(Make.text("rendered"))
        let model = ShelfViewModel(store: env.store, hooks: ShelfHooks(perform: { _, _, _ in }, close: {}))
        await model.start()
        let presentation = ShelfPresentation()
        presentation.opacity = 1
        presentation.offset = 0
        assertRenders("shelf", AnyView(ShelfView(model: model, presentation: presentation)), CGSize(width: 1_200, height: 300))
        model.layout = ShelfLayout(position: .left)
        assertRenders("left shelf", AnyView(ShelfView(model: model, presentation: presentation)), CGSize(width: ShelfPanel.columnWidth, height: 800))
        model.layout = ShelfLayout(position: .center)
        assertRenders("centered shelf", AnyView(ShelfView(model: model, presentation: presentation)), ShelfPanel.centerSize)
    }

    /// The edge shelves cover the Dock, so the panel must sit above it.
    func testShelfPanelIsAboveTheDock() {
        let panel = ShelfPanel()
        XCTAssertGreaterThan(panel.level.rawValue, Int(CGWindowLevelForKey(.dockWindow)))
        XCTAssertLessThan(panel.level, .popUpMenu, "menu-level windows did not get key presses")
    }

    /// Where the panel goes for each position, on a 1440 by 900 screen with a bottom Dock.
    func testShelfFramePerPosition() {
        let screen = NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let visible = NSRect(x: 0, y: 70, width: 1_440, height: 805)
        XCTAssertEqual(ShelfPanelController.frame(for: .bottom, screen: screen, visible: visible),
                       NSRect(x: 0, y: 0, width: 1_440, height: ShelfPanel.height), "on the screen edge, over the Dock")
        XCTAssertEqual(ShelfPanelController.frame(for: .left, screen: screen, visible: visible),
                       NSRect(x: 0, y: 0, width: ShelfPanel.columnWidth, height: 875), "down to the edge, under the menu bar")
        XCTAssertEqual(ShelfPanelController.frame(for: .right, screen: screen, visible: visible).maxX, 1_440)
        // A Dock on the left: the left column covers it instead of starting at its edge.
        let dockLeft = NSRect(x: 80, y: 0, width: 1_360, height: 875)
        XCTAssertEqual(ShelfPanelController.frame(for: .left, screen: screen, visible: dockLeft).minX, 0)
        let center = ShelfPanelController.frame(for: .center, screen: screen, visible: visible)
        XCTAssertEqual(center.size, ShelfPanel.centerSize)
        XCTAssertEqual(center.midX, 720)
        XCTAssertGreaterThan(center.midY, visible.midY, "a little above the middle, like Spotlight")
        let small = ShelfPanelController.frame(for: .center, screen: NSRect(x: 0, y: 0, width: 600, height: 500), visible: NSRect(x: 0, y: 0, width: 600, height: 475))
        XCTAssertEqual(small.width, 560)
        XCTAssertEqual(small.height, 395)
    }

    func testHiddenTransformPerPosition() {
        XCTAssertEqual(ShelfPanelController.hiddenTransform(for: .bottom, reduceMotion: false).offset, 24)
        XCTAssertEqual(ShelfPanelController.hiddenTransform(for: .left, reduceMotion: false).horizontal, -24)
        XCTAssertEqual(ShelfPanelController.hiddenTransform(for: .right, reduceMotion: false).horizontal, 24)
        XCTAssertEqual(ShelfPanelController.hiddenTransform(for: .center, reduceMotion: false).scale, 0.96)
        XCTAssertEqual(ShelfPanelController.hiddenTransform(for: .center, reduceMotion: true).scale, 1)
    }

    func testOnboardingRenders() {
        assertRenders("onboarding", AnyView(OnboardingView(backend: Backend())), CGSize(width: 600, height: 500))
    }

    func testCheatSheetRenders() {
        assertRenders("cheat sheet", AnyView(CheatSheetView()), CGSize(width: 560, height: 640))
    }

    private func assertRenders(_ name: String, _ view: AnyView, _ size: CGSize, file: StaticString = #filePath, line: UInt = #line) {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let image = Self.render(view, size: size, appearance: appearance)
            XCTAssertGreaterThan(Self.drawnFraction(in: image), 0.01, "\(name) drew nothing in \(appearance.rawValue)", file: file, line: line)
        }
    }

    static func render(_ view: AnyView, size: CGSize, appearance: NSAppearance.Name) -> NSBitmapImageRep {
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)!
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return bitmap
    }

    /// The share of pixels that differ from the background in the corner.
    static func drawnFraction(in bitmap: NSBitmapImageRep) -> Double {
        let background = bitmap.colorAt(x: 0, y: 0)
        var drawn = 0
        var total = 0
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 3) {
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 3) {
                total += 1
                if bitmap.colorAt(x: x, y: y) != background { drawn += 1 }
            }
        }
        return Double(drawn) / Double(max(total, 1))
    }

    /// A card title becomes a drag-out file name; it can never name a path.
    func testDragOutFileNamesAreSingleComponents() {
        XCTAssertEqual(AppServices.fileName(for: "Invoice October", fallback: "Image"), "Invoice October")
        XCTAssertEqual(AppServices.fileName(for: "../../../Users/me/.zshrc", fallback: "Image"), "-..-..-Users-me-.zshrc", "no separators, no leading dot")
        XCTAssertEqual(AppServices.fileName(for: "a/b:c", fallback: "Image"), "a-b-c")
        XCTAssertEqual(AppServices.fileName(for: " .hidden ", fallback: "Image"), "hidden")
        XCTAssertEqual(AppServices.fileName(for: "...", fallback: "Image"), "Image")
        XCTAssertEqual(AppServices.fileName(for: nil, fallback: "Image"), "Image")
        XCTAssertEqual(AppServices.fileName(for: String(repeating: "x", count: 200), fallback: "Image").count, 80)
    }
}
