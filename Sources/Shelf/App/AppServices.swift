import AppKit
import Observation
import ServiceManagement
import ShelfCapture
import ShelfCore
import ShelfPaste
import ShelfUI
import SwiftUI
import UniformTypeIdentifiers

/// Builds every component once and wires them together. The only place that
/// knows about all six modules.
///
/// ```
/// NSPasteboard → ClipboardMonitor → Store → ShelfViewModel → ShelfPanel
///                                        ↘ PasteStack ↘
///                                              Paster → NSPasteboard, Cmd+V
/// ```
@MainActor
@Observable
final class AppServices {
    @ObservationIgnored let preferences: Preferences
    @ObservationIgnored let paths: AppPaths
    @ObservationIgnored let store: Store
    @ObservationIgnored let monitor: ClipboardMonitor
    @ObservationIgnored let paster: Paster
    @ObservationIgnored let pasteStack: PasteStack
    @ObservationIgnored let shelfModel: ShelfViewModel
    @ObservationIgnored let shelf: ShelfPanelController
    @ObservationIgnored let stackPanel: PasteStackPanelController
    @ObservationIgnored let hud = ToastHUD()
    @ObservationIgnored let linkPreviewer: LinkPreviewer
    @ObservationIgnored let imageText: ImageTextRecognizer
    @ObservationIgnored let cheatSheet = CheatSheetWindowController()
    @ObservationIgnored private(set) var quickLook: QuickLookPresenter?
    @ObservationIgnored lazy var settingsWindow = SettingsWindowController(backend: self)
    @ObservationIgnored lazy var onboardingWindow = OnboardingWindowController(backend: self)
    @ObservationIgnored lazy var updateWindow = UpdateWindowController(updater: updater, paths: paths)
    let updater: Updater

    /// When capture resumes; `distantFuture` until resumed by hand. Drives the gray menu-bar icon.
    private(set) var pausedUntil: Date?

    @ObservationIgnored private var resumeTask: Task<Void, Never>?
    @ObservationIgnored private var sounds: [SoundEffect: NSSound] = [:]
    @ObservationIgnored private var explainedBlockedAccess = false
    @ObservationIgnored private var retentionScheduler: NSBackgroundActivityScheduler?
    @ObservationIgnored private var lastAppliedRetention: RetentionPeriod?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var isLaunched = false

    /// `SHELF_EPHEMERAL=1` runs on a throwaway folder with an in-memory key:
    /// for demos, screenshots and UI tests. Nothing touches the real history.
    let isEphemeral: Bool
    /// `SHELF_SHOW=shelf|settings[:pane]|onboarding|stack`, ephemeral only: opens
    /// that surface with sample data and prints the window numbers, so a UI change
    /// can be checked in real Liquid Glass with `screencapture -l <number>`.
    @ObservationIgnored private let reviewSurface: String?
    @ObservationIgnored private let environment: [String: String]

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        isEphemeral = environment["SHELF_EPHEMERAL"] == "1"
        reviewSurface = isEphemeral ? environment["SHELF_SHOW"] : nil
        self.environment = environment
        let bundleID = Bundle.main.bundleIdentifier ?? Brand.devBundleID
        preferences = Preferences(defaults: .standard)
        paths = isEphemeral ? AppPaths.temporary() : AppPaths.standard(bundleIdentifier: bundleID)
        let keys: any BlobKeyProviding = if isEphemeral {
            InMemoryBlobKeyProvider()
        } else if bundleID.hasSuffix(".dev") {
            FileBlobKeyProvider(directory: paths.root)
        } else {
            KeychainBlobKeyProvider()
        }
        store = Store(paths: paths, keyProvider: keys, preferences: preferences)
        monitor = ClipboardMonitor(store: store, preferences: preferences)
        paster = Paster(store: store, preferences: preferences)
        pasteStack = PasteStack(store: store, paster: paster)
        linkPreviewer = LinkPreviewer(store: store, preferences: preferences)
        imageText = ImageTextRecognizer(store: store, preferences: preferences)
        updater = Updater(preferences: preferences)
        let model = ShelfViewModel(store: store, hooks: ShelfHooks(perform: { _, _, _ in }, close: {}))
        shelfModel = model
        shelf = ShelfPanelController(model: model, preferences: preferences)
        stackPanel = PasteStackPanelController(stack: pasteStack, preferences: preferences, thumbnails: model.thumbnails)
        pausedUntil = preferences.pausedUntil.flatMap { $0 > Date() ? $0 : nil }

        model.hooks = makeShelfHooks()
        quickLook = QuickLookPresenter { [weak self] item in await self?.temporaryFile(for: item) }
        stackPanel.onClose = { [weak self] in self?.togglePasteStack() }
        updater.onUpdateAvailable = { [weak self] release in self?.updateWindow.show(release) }
    }

    // MARK: Launch

    /// Sent by a second copy of the app to the one already running.
    static var showSettingsNotification: Notification.Name {
        Notification.Name("\(Bundle.main.bundleIdentifier ?? Brand.releaseBundleID).showSettings")
    }

    /// The menu-bar icon is already visible when this runs. The store and its
    /// migrations open right after, off the launch path.
    func launch(arguments: [String] = CommandLine.arguments) {
        guard !isLaunched else { return }
        isLaunched = true
        // One copy at a time: a second one (another build, or the login item
        // plus a manual launch) would answer the same shortcuts and show its
        // messages on top of the first one's. The updater waits for the old
        // copy to exit before opening the new one, so updates are unaffected.
        if !isEphemeral, let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains(where: { $0 != .current }) {
            // Not a silent quit: the running copy shows Settings, as opening
            // Shelf again from Spotlight does.
            DistributedNotificationCenter.default().postNotificationName(Self.showSettingsNotification, object: nil,
                                                                         userInfo: nil, deliverImmediately: true)
            NSApp.terminate(nil)
            return
        }
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Self.showSettingsNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.openSettings() }
        })
        Updater.cleanUpAfterUpdate(arguments: arguments, preferences: preferences,
                                   previousVersions: Updater.previousVersions(in: paths))
        removePreviewFiles()
        // Review copies run next to the real app and must not take its shortcuts.
        if reviewSurface == nil {
            Hotkeys.register(onShelf: { [weak self] in self?.toggleShelf() },
                             onPasteStack: { [weak self] in self?.togglePasteStack() },
                             onPause: { [weak self] in self?.togglePause() })
        }
        observeScreenLock()
        let playCopySound: @Sendable (ClipItem) -> Void = { [weak self] _ in
            Task { @MainActor in self?.play(.copy) }
        }
        let explainBlockedAccess: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.explainBlockedClipboardAccess() }
        }

        Task {
            guard await openStore() else { return }
            if let reviewSurface {
                await showForReview(reviewSurface)
                return
            }
            await shelfModel.start()
            await monitor.setOnCapture(playCopySound)
            await monitor.setOnAccessBlocked(explainBlockedAccess)
            if let pausedUntil {
                scheduleResume(at: pausedUntil)
            } else {
                await monitor.start()
            }
            linkPreviewer.start()
            imageText.start()
            runRetention()
            scheduleNightlyRetention()
            updater.start()

            if !preferences.defaults.bool(forKey: PrefKey.onboardingCompleted) {
                onboardingWindow.show()
            } else {
                registerLoginItemOnce(announce: true)
                launchMaccyOffer()
                AccessibilityRecovery.run(defaults: preferences.defaults, build: appBuild, isTrusted: SystemAccessibility().isTrusted)
            }
        }
    }

    private func showForReview(_ surface: String) async {
        await SampleData.populate(store)
        await shelfModel.start()
        let parts = surface.split(separator: ":").map(String.init)
        if environment["SHELF_APPEARANCE"] == "dark" { NSApp.appearance = NSAppearance(named: .darkAqua) }
        switch parts[0] {
        case "shelf":
            shelf.show(takeFocus: false)
            Self.addReviewBackdrop(to: shelf.panel)
        case "stack":
            togglePasteStack()
            for item in shelfModel.items.prefix(4) { pasteStack.append(item) }
            if let panel = NSApp.windows.first(where: { $0 is ShelfPanel && $0 !== shelf.panel }) { Self.addReviewBackdrop(to: panel) }
        case "onboarding":
            let step = parts.count > 1 ? OnboardingFlow.Step(rawValue: Int(parts[1]) ?? 0) : nil
            onboardingWindow.show(step: step ?? .welcome, activate: false)
        default: settingsWindow.show(pane: parts.count > 1 ? SettingsView.Pane(rawValue: parts[1]) : nil, activate: false)
        }
        try? await Task.sleep(for: .seconds(1))
        for window in NSApp.windows where window.isVisible {
            print("window \(window.windowNumber) \(type(of: window)) \(window.title)")
        }
        fflush(stdout)
    }

    /// A window capture has no desktop behind it, so glass would look flat gray.
    /// Review renders put a colorful picture behind the panel's content instead.
    private static func addReviewBackdrop(to panel: NSWindow) {
        guard let content = panel.contentView else { return }
        let container = NSView(frame: content.frame)
        let backdrop = NSView(frame: container.bounds)
        backdrop.wantsLayer = true
        let gradient = CAGradientLayer()
        gradient.colors = [NSColor.systemIndigo, NSColor.systemPink, NSColor.systemOrange, NSColor.systemTeal].map(\.cgColor)
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        backdrop.layer = gradient
        backdrop.autoresizingMask = [.width, .height]
        content.frame = container.bounds
        content.autoresizingMask = [.width, .height]
        panel.contentView = container
        container.addSubview(backdrop)
        container.addSubview(content)
    }

    private func openStore() async -> Bool {
        do {
            try await store.open()
            return true
        } catch let error as SchemaError {
            Log.store.error("Refusing a newer schema: \(String(describing: error), privacy: .public)")
            return await offerFreshStart()
        } catch {
            Log.store.error("Could not open the store: \(String(describing: error), privacy: .public)")
            let alert = NSAlert()
            alert.messageText = String(localized: "\(Brand.name) could not open its history")
            alert.informativeText = error.localizedDescription
            NSApp.activate()
            alert.runModal()
            return false
        }
    }

    /// A newer Shelf wrote this database. Downgrades are unsupported: offer
    /// to move the folder aside and start fresh, or quit.
    private func offerFreshStart() async -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "This history was saved by a newer version of \(Brand.name)")
        alert.informativeText = String(localized: "Install the newer version again, or back up the history and start with an empty one.")
        alert.addButton(withTitle: String(localized: "Back Up and Start Fresh"))
        alert.addButton(withTitle: String(localized: "Quit"))
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else {
            NSApp.terminate(nil)
            return false
        }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backup = paths.root.deletingLastPathComponent().appendingPathComponent("\(paths.root.lastPathComponent) Backup \(stamp)")
        do {
            try FileManager.default.moveItem(at: paths.root, to: backup)
            try await store.open()
            NSWorkspace.shared.activateFileViewerSelecting([backup])
            return true
        } catch {
            return false
        }
    }

    // MARK: Shelf and stack

    func toggleShelf() {
        if !shelf.isVisible, lastAppliedRetention != preferences.keepHistory {
            runRetention()
        }
        shelf.toggle()
    }

    func togglePasteStack() {
        if pasteStack.isOpen {
            pasteStack.close()
            stackPanel.hide()
        } else {
            pasteStack.open()
            stackPanel.show()
        }
    }

    /// Shelf has no Dock or menu bar presence by default, so it opens at
    /// login by itself. Done once, so turning it off in Settings sticks.
    /// Development builds are skipped: a login item pointing into a build folder
    /// would launch stale builds forever.
    /// `announce` is for existing installs updating to this version: the menu
    /// bar icon is now off by default, so say where the app went.
    func registerLoginItemOnce(announce: Bool = false) {
        guard !isEphemeral, !preferences.defaults.bool(forKey: PrefKey.loginItemRegistered) else { return }
        preferences.defaults.set(true, forKey: PrefKey.loginItemRegistered)
        if announce, !preferences.showInMenuBar {
            hud.show(String(localized: "\(Brand.name) now runs without a menu bar icon and opens at login. Press \(Hotkeys.display(.activateShelf)) to open it; the icon is in Settings."),
                     symbol: "rectangle.bottomthird.inset.filled", duration: .seconds(6))
        }
        guard !(Bundle.main.bundleIdentifier ?? "").hasSuffix(".dev") else { return }
        launchAtLogin = true
    }

    private func makeShelfHooks() -> ShelfHooks {
        ShelfHooks(
            perform: { [weak self] item, request, _ in
                await self?.perform(request, item: item)
            },
            performMany: { [weak self] items, request, _ in
                await self?.perform(request, items: items)
            },
            close: { [weak self] in self?.shelf.hide() },
            openSettings: { [weak self] in
                self?.shelf.hide(animated: false)
                self?.openSettings()
            },
            addToPasteStack: { [weak self] item in
                guard let self else { return }
                if !pasteStack.isOpen { togglePasteStack() }
                pasteStack.append(item)
            },
            quickLook: { [weak self] item in
                guard let self, let quickLook else { return }
                if let item {
                    quickLook.show(item, above: shelf.panel.level)
                } else {
                    quickLook.close()
                }
            },
            isQuickLookVisible: { [weak self] in self?.quickLook?.isOpen ?? false },
            showCheatSheet: { [weak self] in
                self?.shelf.hide(animated: false)
                self?.cheatSheet.show()
            },
            dragProvider: { [weak self] item in
                self?.dragProvider(for: item) ?? NSItemProvider()
            },
            playSound: { [weak self] sound in
                switch sound {
                case .pin: self?.play("Tink")
                case .delete: self?.play("Bottle")
                }
            },
            copyForAI: { [weak self] items in await self?.copyForAI(items) }
        )
    }

    private func perform(_ request: PasteRequest, item: ClipItem) async {
        await perform(request, items: [item])
    }

    /// One card, or several: files as separate files, text as lines of plain text,
    /// and with images among them, one card after another.
    private func perform(_ request: PasteRequest, items: [ClipItem]) async {
        let resolved = await resolvingPromises(items)
        let outcome = await paster.perform(Self.pasterRequest(request), items: resolved, targetBundleID: shelf.targetBundleID) { [weak self] in
            self?.shelf.hide(animated: false)
        }
        report(outcome)
    }

    /// Promised files are received on first use, so every path that reads payloads resolves them first.
    private func resolvingPromises(_ items: [ClipItem]) async -> [ClipItem] {
        var resolved: [ClipItem] = []
        for item in items { resolved.append(await PromiseResolver.resolveIfPossible(item, store: store)) }
        return resolved
    }

    private static func pasterRequest(_ request: PasteRequest) -> Paster.Request {
        switch request {
        case .paste: .paste
        case .pastePlain: .pastePlain
        case .copy: .copy
        case .transformed(let transform): .transformed(transform)
        }
    }

    /// "Copy for AI": the cards as one text document on the clipboard.
    private func copyForAI(_ items: [ClipItem]) async {
        guard !items.isEmpty else { return }
        var entries: [ContextBlock.Entry] = []
        for item in await resolvingPromises(items) {
            let representations = (try? await paster.payload(for: item)) ?? []
            entries.append(ContextBlock.Entry(item: item, text: PasteboardWriter.plainText(for: item, representations: representations)))
        }
        PasteboardWriter.writePlainText(ContextBlock.make(entries), to: .general)
        hud.show(String(localized: "Copied \(items.count) items for AI"), symbol: "sparkles")
    }

    /// "0.1.1 (12)": the version and build, which change with every release.
    private var appBuild: String {
        "\(updater.currentVersion) (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"))"
    }

    private func report(_ outcome: Paster.Outcome) {
        switch outcome {
        case .pasted:
            play(.paste)
            // A paste proves Accessibility, also when it was granted after launch.
            AccessibilityRecovery.recordGranted(defaults: preferences.defaults, build: appBuild)
        case .copied(.requested):
            play(.paste)
            hud.show(String(localized: "Copied"))
        case .copied(.accessibilityMissing):
            // Says why Return copied instead of pasting. An ad-hoc build loses its
            // grant on every rebuild while System Settings still shows it on.
            play(.paste)
            hud.show(String(localized: "Copied. \(Brand.name) needs Accessibility to paste for you."),
                     symbol: "lock.shield", duration: .seconds(3))
        case .copied(.manualPasteApp(let bundleID)):
            play(.paste)
            let name = SourceResolver.appName(for: bundleID) ?? bundleID
            hud.show(String(localized: "Copied. Press ⌘V to paste in \(name)."))
        case .copied:
            play(.paste)
            hud.show(String(localized: "Copied. Press ⌘V to paste."))
        case .failed:
            hud.show(String(localized: "This item could not be pasted"), symbol: "exclamationmark.triangle")
        }
    }

    /// The shelf's pin and remove sounds: system sounds, with the paste sound setting.
    private func play(_ name: String) {
        guard preferences.pasteSound, let sound = NSSound(named: NSSound.Name(name)) else { return }
        sound.volume = 0.4
        sound.play()
    }

    /// Shelf's own copy and paste sounds, when their setting is on.
    func play(_ effect: SoundEffect) {
        let enabled = switch effect {
        case .copy: preferences.copySound
        case .paste: preferences.pasteSound
        }
        if enabled { playSound(effect) }
    }

    /// Plays regardless of the setting: also the preview button in Settings.
    /// Loaded once from the bundle and kept, so a sound is never released mid-play.
    func playSound(_ effect: SoundEffect) {
        let sound = sounds[effect] ?? Bundle.main.url(forResource: effect.resourceName, withExtension: "wav")
            .flatMap { NSSound(contentsOf: $0, byReference: true) }
        guard let sound else {
            Log.ui.error("Sound \(effect.rawValue, privacy: .public) is missing from the app bundle")
            return
        }
        sounds[effect] = sound
        sound.stop()
        sound.volume = 0.8
        sound.play()
    }

    /// Dragging a card into another app (v1.1): every stored type, loaded on demand.
    private func dragProvider(for item: ClipItem) -> NSItemProvider {
        if item.kind == .file, !item.missingFiles, let path = item.filePaths.first,
           let provider = NSItemProvider(contentsOf: URL(fileURLWithPath: path)) {
            return provider
        }
        let provider = NSItemProvider()
        let store = self.store
        if item.kind == .image {
            // File-upload fields and Finder want a file, not image bytes: offer a PNG on disk too.
            provider.registerFileRepresentation(forTypeIdentifier: UTType.png.identifier, fileOptions: [], visibility: .all) { [weak self] completion in
                Task { @MainActor in
                    completion(await self?.temporaryPNG(for: item), false, nil)
                }
                return nil
            }
        }
        let types = (try? store.storedTypes(for: item.id)) ?? []
        for uti in types where !uti.hasPrefix("dyn.") && uti != Brand.originMarkerType {
            provider.registerDataRepresentation(forTypeIdentifier: uti, visibility: .all) { completion in
                Task {
                    let data = try? await store.representations(for: item.id).first { $0.uti == uti }?.data
                    completion(data, nil)
                }
                return nil
            }
        }
        provider.suggestedName = item.kind == .link ? (item.linkTitle ?? item.host) : nil
        return provider
    }

    /// Decrypted copies for Quick Look live under one folder, emptied at launch,
    /// on quit and on "Erase history", so a crash cannot strand one.
    static var previewRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(Brand.slug)-previews", isDirectory: true)
    }

    func removePreviewFiles() {
        FileManager.default.removeIfPresent(Self.previewRoot)
    }

    /// Writes an item to a private temporary file for Quick Look.
    private func temporaryFile(for item: ClipItem) async -> URL? {
        let directory = Self.previewRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let representations = (try? await paster.payload(for: item)) ?? []
        func data(_ uti: String) -> Data? { representations.first { $0.uti == uti }?.data }

        let (fileData, fileExtension): (Data?, String) = switch item.kind {
        case .image:
            ([PasteboardTypes.png, PasteboardTypes.jpeg, PasteboardTypes.heic, PasteboardTypes.tiff]
                .lazy.compactMap { uti in data(uti).map { ($0, UTType(uti)?.preferredFilenameExtension ?? "png") } }
                .first ?? (store.thumbnail(for: item.id), "heic"))
        case .richText:
            data(PasteboardTypes.rtf).map { ($0, "rtf") } ?? data(PasteboardTypes.html).map { ($0, "html") }
                ?? (Data(item.preview.utf8), "txt")
        case .link:
            (Data(Self.linkPage(for: item).utf8), "html")
        case .color:
            (Self.swatchPNG(hex: item.colorHex ?? "#808080"), "png")
        case .audio:
            representations.first { UTType($0.uti)?.conforms(to: .audio) == true }
                .map { ($0.data, UTType($0.uti)?.preferredFilenameExtension ?? "m4a") } ?? (nil, "m4a")
        case .text, .file, .other:
            (PasteboardWriter.plainText(for: item, representations: representations).map { Data($0.utf8) }, "txt")
        }
        guard let fileData else { return nil }
        let url = directory.appendingPathComponent("\(item.kind.displayName).\(fileExtension)")
        try? fileData.write(to: url)
        return url
    }

    /// A PNG file of an image item for drag-out, under the preview folder.
    /// Oversized items that kept only their thumbnail drag that out, as Quick Look shows it.
    private func temporaryPNG(for item: ClipItem) async -> URL? {
        let representations = (try? await paster.payload(for: item)) ?? []
        let png = representations.first { $0.uti == PasteboardTypes.png }?.data
            ?? representations.first { UTType($0.uti)?.conforms(to: .image) == true }
            .flatMap { PasteboardWriter.pngRepresentation(ofThumbnail: $0.data)?.data }
            ?? store.thumbnail(for: item.id).flatMap { PasteboardWriter.pngRepresentation(ofThumbnail: $0)?.data }
        guard let png else { return nil }
        let directory = Self.previewRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(Self.fileName(for: item.title, fallback: String(localized: "Image")) + ".png")
        try? png.write(to: url)
        return url
    }

    /// A title as a single file name component: no path separators, no leading
    /// dot, at most 80 characters, so a title can never name a path outside the folder.
    static func fileName(for title: String?, fallback: String) -> String {
        let cleaned = (title ?? "")
            .map { $0 == "/" || $0 == ":" || $0 == "\0" ? "-" : $0 }
            .reduce(into: "") { $0.append($1) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .drop { $0 == "." }
        let name = String(cleaned.prefix(80))
        return name.isEmpty ? fallback : name
    }

    private static func linkPage(for item: ClipItem) -> String {
        let url = (item.url ?? "").replacingOccurrences(of: "\"", with: "&quot;")
        let title = (item.linkTitle ?? item.host ?? item.url ?? "").replacingOccurrences(of: "<", with: "&lt;")
        return """
            <html><body style="font: 15px -apple-system; padding: 40px">
            <h2>\(title)</h2><p><a href="\(url)">\(url.replacingOccurrences(of: "<", with: "&lt;"))</a></p>
            </body></html>
            """
    }

    private static func swatchPNG(hex: String) -> Data? {
        let image = NSImage(size: NSSize(width: 512, height: 512), flipped: false) { rect in
            (NSColor(Color(hex: hex) ?? .gray)).setFill()
            rect.fill()
            return true
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    /// A copy was skipped because macOS asks before every clipboard read. Said
    /// once per launch; Settings, General keeps showing it.
    private func explainBlockedClipboardAccess() {
        guard !explainedBlockedAccess else { return }
        explainedBlockedAccess = true
        hud.show(String(localized: "\(Brand.name) is not recording copies. Allow it under Privacy & Security, Paste from Other Apps."),
                 symbol: "hand.raised", duration: .seconds(6))
    }

    // MARK: Pause

    func pause(minutes: Int?) {
        let until = minutes.map { Date().addingTimeInterval(Double($0) * 60) } ?? .distantFuture
        preferences.pausedUntil = until
        pausedUntil = until
        Task { await monitor.stop() }
        scheduleResume(at: until)
    }

    /// The pause hotkey: pause until resumed, or resume. Says which in a HUD,
    /// since the menu bar icon may be hidden.
    func togglePause() {
        if let pausedUntil, pausedUntil > Date() {
            resume()
            hud.show(String(localized: "Resumed: new copies are saved again"), symbol: "play.fill")
        } else {
            pause(minutes: nil)
            hud.show(String(localized: "Paused: new copies are not saved"), symbol: "pause.fill")
        }
    }

    func resume() {
        resumeTask?.cancel()
        resumeTask = nil
        preferences.pausedUntil = nil
        pausedUntil = nil
        Task { await monitor.start() }
    }

    private func scheduleResume(at date: Date) {
        resumeTask?.cancel()
        guard date != .distantFuture else { return }
        resumeTask = Task { [weak self] in
            let delay = max(0, date.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.resume()
        }
    }

    // MARK: URL scheme

    /// `shelf-app://pause?minutes=15`, `shelf-app://pause`, `shelf-app://resume`,
    /// `shelf-app://open`, `shelf-app://stack`, `shelf-app://settings`. For Shortcuts automations.
    func handle(_ url: URL) {
        guard url.scheme?.lowercased() == Brand.urlScheme else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        switch url.host?.lowercased() {
        case "pause":
            let minutes = components?.queryItems?.first { $0.name == "minutes" }?.value.flatMap(Int.init)
            pause(minutes: minutes.flatMap { $0 > 0 ? $0 : nil })
        case "resume":
            resume()
        case "open", "shelf":
            shelf.reconcile()
            if !shelf.isVisible { toggleShelf() }
        case "stack":
            if !pasteStack.isOpen { togglePasteStack() }
        case "settings":
            openSettings()
        default:
            break
        }
    }

    // MARK: Retention

    func runRetention() {
        let policy = preferences.keepHistory
        lastAppliedRetention = policy
        Task {
            _ = try? await store.purge(retention: policy)
            preferences.defaults.set(Date().timeIntervalSince1970, forKey: PrefKey.lastRetentionRun)
        }
    }

    /// The nightly purge. The system picks a quiet moment within the hour.
    private func scheduleNightlyRetention() {
        let scheduler = NSBackgroundActivityScheduler(identifier: "\(Brand.releaseBundleID).retention")
        scheduler.repeats = true
        scheduler.interval = 24 * 3_600
        scheduler.tolerance = 3_600
        scheduler.qualityOfService = .utility
        scheduler.schedule { [weak self] completion in
            Task { @MainActor in
                self?.runRetention()
                completion(.finished)
            }
        }
        retentionScheduler = scheduler
    }

    // MARK: Screen lock

    private func observeScreenLock() {
        let center = DistributedNotificationCenter.default()
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            observers.append(center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [monitor] _ in
                Task { await monitor.setScreenLocked(locked) }
            })
        }
    }

    // MARK: Windows

    func openSettings() {
        settingsWindow.show()
    }

    /// Maccy users get one offer to bring their history along (v1.1).
    func launchMaccyOffer() {
        guard !isEphemeral, !preferences.defaults.bool(forKey: PrefKey.maccyImportOffered), let url = MaccyDatabase.url else { return }
        preferences.defaults.set(true, forKey: PrefKey.maccyImportOffered)
        let count = MaccyDatabase.itemCount(at: url) ?? 0
        guard count > 0 else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Import your Maccy history?")
        alert.informativeText = String(localized: "\(Brand.name) found \(count) items from Maccy. Importing copies them; Maccy keeps its own history. You can also do this later in Settings.")
        alert.addButton(withTitle: String(localized: "Import"))
        alert.addButton(withTitle: String(localized: "Not Now"))
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await runMaccyImport(from: url) }
    }

    func runMaccyImport(from url: URL) async {
        do {
            let result = try await MaccyImporter.importHistory(from: url, into: store, preferences: preferences)
            hud.show(String(localized: "Imported \(result.imported) items from Maccy"), symbol: "tray.and.arrow.down")
        } catch {
            hud.show(String(localized: "Maccy history could not be read"), symbol: "exclamationmark.triangle")
        }
    }

    func runPasteImport(from url: URL) async {
        do {
            let result = try await PasteImporter.importHistory(from: url, into: store, preferences: preferences)
            hud.show(String(localized: "Imported \(result.imported) items from Paste"), symbol: "tray.and.arrow.down")
        } catch {
            hud.show(String(localized: "Paste history could not be read"), symbol: "exclamationmark.triangle")
        }
    }

    var versionString: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return String(localized: "Version \(short) (\(build))")
    }
}

extension PasteStack: PasteStackPresenting {}
