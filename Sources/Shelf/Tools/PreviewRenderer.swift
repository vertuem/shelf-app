import AppKit
import ImageIO
import ShelfCapture
import ShelfCore
import ShelfPaste
import ShelfUI
import SwiftUI

/// Renders the main surfaces offscreen, in light and dark, with sample data.
/// Used for the README screenshots and for reviewing UI changes in pull
/// requests without screen recording permission.
///
/// Offscreen rendering cannot draw Liquid Glass or live materials, so renders
/// use the opaque Reduce Transparency look for the panel background, and the
/// settings sidebar (system glass on macOS 26) comes out empty. For the real
/// look, see "Checking the real window" in the README.
@MainActor
enum PreviewRenderer {
    static func renderAll(to folder: URL) async {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        UserDefaults.standard.set(true, forKey: "debugForceLegacyChrome")
        defer { UserDefaults.standard.removeObject(forKey: "debugForceLegacyChrome") }

        let paths = AppPaths.temporary()
        defer { FileManager.default.removeIfPresent(paths.root) }
        let defaults = UserDefaults(suiteName: "shelf-previews")!
        defaults.removePersistentDomain(forName: "shelf-previews")
        let preferences = Preferences(defaults: defaults)
        let store = Store(paths: paths, keyProvider: InMemoryBlobKeyProvider(), preferences: preferences)
        try? await store.open()
        await SampleData.populate(store)

        let model = ShelfViewModel(store: store, hooks: ShelfHooks(perform: { _, _, _ in }, close: {}))
        await model.start()
        model.prepareForShow()
        await model.thumbnails.preload(model.items.map(\.id))
        for item in model.items where item.kind == .richText { _ = await model.richText.text(for: item.id) }
        let presentation = ShelfPresentation()
        presentation.offset = 0
        presentation.opacity = 1

        let emptyStore = Store(paths: AppPaths.temporary(), keyProvider: InMemoryBlobKeyProvider(), preferences: preferences)
        let emptyModel = ShelfViewModel(store: emptyStore, hooks: ShelfHooks(perform: { _, _, _ in }, close: {}))
        await emptyModel.start()

        let backend = PreviewBackend()
        for (scheme, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            render(ShelfView(model: model, presentation: presentation).background(Desktop()),
                   size: CGSize(width: 1_440, height: 300), appearance: scheme, to: folder.appendingPathComponent("shelf-\(suffix).png"))
            render(ShelfView(model: emptyModel, presentation: presentation).background(Desktop()),
                   size: CGSize(width: 1_000, height: 300), appearance: scheme, to: folder.appendingPathComponent("shelf-empty-\(suffix).png"))
            // The other shelf positions: a column up the left edge and the centered grid.
            model.layout = ShelfLayout(position: .left)
            render(ShelfView(model: model, presentation: presentation).background(Desktop()),
                   size: CGSize(width: ShelfPanel.columnWidth, height: 900), appearance: scheme, to: folder.appendingPathComponent("shelf-left-\(suffix).png"))
            model.layout = ShelfLayout(position: .center)
            render(ShelfView(model: model, presentation: presentation).background(Desktop()),
                   size: ShelfPanel.centerSize, appearance: scheme, to: folder.appendingPathComponent("shelf-center-\(suffix).png"))
            model.layout = .bottom
            // A search, to show the highlighted matches and the filter suggestions.
            model.searchText = "type:"
            render(ShelfView(model: model, presentation: presentation).background(Desktop()),
                   size: CGSize(width: 1_440, height: 300), appearance: scheme, to: folder.appendingPathComponent("shelf-suggestions-\(suffix).png"))
            model.prepareForShow()
            for pane in SettingsView.Pane.allCases {
                render(SettingsView(backend: backend, initialPane: pane), size: CGSize(width: 760, height: 620), appearance: scheme,
                       to: folder.appendingPathComponent("settings-\(pane.rawValue)-\(suffix).png"))
            }
            render(OnboardingView(backend: backend), size: CGSize(width: 660, height: 700), appearance: scheme,
                   to: folder.appendingPathComponent("onboarding-\(suffix).png"))
            render(CheatSheetView().background(Color(nsColor: .windowBackgroundColor)), size: CGSize(width: 560, height: 640),
                   appearance: scheme, to: folder.appendingPathComponent("cheatsheet-\(suffix).png"))
            render(MenuBarContent(backend: backend).background(Color(nsColor: .windowBackgroundColor)),
                   size: CGSize(width: 260, height: 400), appearance: scheme, to: folder.appendingPathComponent("menubar-\(suffix).png"))
        }

        // Paste Stack with a few items.
        let paster = Paster(store: store, preferences: preferences)
        let stack = PasteStack(store: store, paster: paster) { _ in NoTap() }
        stack.open()
        for item in model.items.prefix(4) { stack.append(item) }
        await stack.waitUntilPrefetched()
        stack.simulateCommandV()
        render(PasteStackPreview(stack: stack, thumbnails: model.thumbnails), size: CGSize(width: 300, height: 460),
               appearance: .aqua, to: folder.appendingPathComponent("pastestack-light.png"))
        print("Rendered previews to \(folder.path)")
    }

    /// The README's animated demo: the shelf slides up, the selection moves,
    /// a search narrows the cards, and the shelf slides away after "pasting".
    static func renderDemo(to file: URL) async {
        UserDefaults.standard.set(true, forKey: "debugForceLegacyChrome")
        defer { UserDefaults.standard.removeObject(forKey: "debugForceLegacyChrome") }
        let paths = AppPaths.temporary()
        defer { FileManager.default.removeIfPresent(paths.root) }
        let defaults = UserDefaults(suiteName: "shelf-demo")!
        defaults.removePersistentDomain(forName: "shelf-demo")
        let store = Store(paths: paths, keyProvider: InMemoryBlobKeyProvider(), preferences: Preferences(defaults: defaults))
        try? await store.open()
        await SampleData.populate(store)
        let model = ShelfViewModel(store: store, hooks: ShelfHooks(perform: { _, _, _ in }, close: {}))
        model.searchDebounce = .milliseconds(1)
        await model.start()
        model.prepareForShow()
        await model.thumbnails.preload(model.items.map(\.id))
        for item in model.items where item.kind == .richText { _ = await model.richText.text(for: item.id) }
        let presentation = ShelfPresentation()
        let size = CGSize(width: 1_200, height: 300)

        var frames: [(CGImage, Double)] = []
        func capture(_ delay: Double) {
            if let image = renderImage(ShelfView(model: model, presentation: presentation).background(Desktop()), size: size) {
                frames.append((image, delay))
            }
        }

        presentation.opacity = 0
        presentation.offset = 300
        capture(1.0)
        for step in 1...6 {
            let progress = Double(step) / 6
            presentation.offset = 300 * (1 - progress) * (1 - progress)
            presentation.opacity = progress
            capture(0.05)
        }
        capture(0.8)
        for _ in 0..<3 {
            model.moveSelection(by: 1)
            capture(0.8)
        }
        model.moveSelection(by: -3)
        capture(0.6)
        for prefix in ["t", "ty", "typ", "type", "type:", "type:i", "type:im", "type:ima", "type:imag", "type:image", "type:image "] {
            model.searchText = prefix
            try? await Task.sleep(for: .milliseconds(60))
            capture(0.08)
        }
        try? await Task.sleep(for: .milliseconds(200))
        capture(1.6)
        model.escapeSearch()
        try? await Task.sleep(for: .milliseconds(200))
        model.selectFirst()
        model.moveSelection(by: 1)
        capture(1.0)
        for step in 1...5 {
            let progress = Double(step) / 5
            presentation.offset = 300 * progress * progress
            presentation.opacity = 1 - progress
            capture(0.04)
        }
        capture(1.0)

        let output = NSMutableData()
        guard let gif = CGImageDestinationCreateWithData(output, "com.compuserve.gif" as CFString, frames.count, nil) else { return }
        CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for (image, delay) in frames {
            let properties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay]]
            CGImageDestinationAddImage(gif, image, properties as CFDictionary)
        }
        if CGImageDestinationFinalize(gif) {
            try? (output as Data).write(to: file)
            print("Rendered \(frames.count) frames to \(file.path)")
        }
    }

    /// One frame at 1x, for small GIFs.
    static func renderImage<V: View>(_ view: V, size: CGSize) -> CGImage? {
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        bitmap.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return bitmap.cgImage
    }

    static func render<V: View>(_ view: V, size: CGSize, appearance: NSAppearance.Name, to url: URL) {
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
}

/// A desktop-like backdrop behind the shelf renders.
private struct Desktop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        LinearGradient(
            colors: colorScheme == .dark ? [Color(white: 0.15), Color(red: 0.1, green: 0.12, blue: 0.2)]
                : [Color(red: 0.85, green: 0.9, blue: 0.97), Color(red: 0.95, green: 0.9, blue: 0.95)],
            startPoint: .top, endPoint: .bottom
        )
    }
}

private struct PasteStackPreview: View {
    let stack: PasteStack
    let thumbnails: ThumbnailCache

    var body: some View {
        PasteStackPanelPreview(stack: stack, thumbnails: thumbnails)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}

@MainActor
private final class NoTap: CommandVTapping {
    var isInstalled = true
    func install() -> Bool { true }
    func remove() {}
}

/// Stub backends with plausible values for renders.
@MainActor
private final class PreviewBackend: SettingsBackend, OnboardingBackend, MenuBarBackend {
    var loginItemState: LoginItemState { .afterSetup }
    func turnOnLoginItem() {}
    var clipboardAccess: ClipboardAccess { .notAskedYet }
    func requestClipboardAccess() {}
    func openClipboardSettings() {}
    func playSound(_ effect: SoundEffect) {}
    var launchAtLogin = true
    var isAccessibilityGranted = true
    func openAccessibilitySettings() {}
    func statistics() async -> Store.Statistics? {
        Store.Statistics(historyCount: 1_284, pinnedCount: 23, databaseBytes: 6_400_000, blobBytes: 182_000_000, imageCount: 140, oldImageCount: 37)
    }
    func eraseHistory(keepPinned: Bool) async {}
    func removeOldImages() async -> Int { 0 }
    func exportHistory() async {}
    func importHistory() async {}
    var maccyDatabaseFound = true
    func importFromMaccy() async {}
    var pasteDatabaseFound = true
    func importFromPaste() async {}
    var versionString = "Version 1.0.0 (412)"
    var isDevelopmentBuild = false
    var updatesInstallByHand = false
    var updateStatus = "\(Brand.name) is up to date."
    var isCheckingForUpdates = false
    func checkForUpdates() {}
    func rerunOnboarding() {}
    func reportCrash() {}
    func requestAccessibility() {}
    var runningClipboardManagers: [String] = []
    func createSnippetsPinboard() async {}
    func finishOnboarding(accessibilitySkipped: Bool) {}
    var pausedUntil: Date?
    func openShelf() {}
    func togglePasteStack() {}
    func pause(minutes: Int?) {}
    func resume() {}
    func openSettings() {}
    func showCheatSheet() {}
    func quit() {}
}
