import AppKit
import ShelfCore

/// Watches the general pasteboard and records every copy in the `Store`.
///
/// macOS has no pasteboard change notification, so the monitor polls
/// `changeCount` every 250 ms on a utility-QoS timer. Everything runs on the
/// actor's own serial queue; the main thread is never involved.
///
/// The flow for each change:
/// 1. Same count or Shelf's own origin marker: ignore.
/// 2. Wait 120 ms for apps that write several times per copy (Excel, Figma).
/// 3. Reject concealed, transient and auto-generated types (configurable).
/// 4. Reject copies from ignored apps.
/// 5. Reject while the screen is locked, unless capture-while-locked is on.
/// 6. Read every type of every item; above the size limit keep only metadata.
/// 7. Hash; a match moves the existing item to the front (in the Store).
/// 8. Classify, build the preview and thumbnail.
/// 9. Insert, which writes the blobs and publishes the item.
public actor ClipboardMonitor {
    public nonisolated let unownedExecutor: UnownedSerialExecutor
    private let queue: DispatchSerialQueue
    private nonisolated(unsafe) let pasteboard: NSPasteboard
    private let store: Store
    private let preferences: Preferences
    private let frontmostApp: @Sendable () -> SourceApp
    private var timer: DispatchSourceTimer?
    private var lastChangeCount: Int
    /// The frontmost app at the previous poll, before the copy happened. Checked
    /// against the ignore list too, so copying in an ignored app and switching
    /// away before the monitor notices does not get past the filter.
    private var frontmostAtLastTick: SourceApp?
    private var isScreenLocked = false
    private var isBusy = false
    private var isRunning = false
    /// Called after a copy is saved, for the copy sound. Not called for imports.
    private var onCapture: (@Sendable (ClipItem) -> Void)?
    /// Called when a copy is skipped because macOS would ask about the read.
    private var onAccessBlocked: (@Sendable () -> Void)?

    /// Poll interval. Shorter wastes battery; longer makes the shelf feel stale.
    public static let interval: DispatchTimeInterval = .milliseconds(250)
    /// Wait after a change before reading, for apps that write in several steps.
    public static let debounce: Duration = .milliseconds(120)

    /// The last capture decision, for tests.
    public private(set) var lastRejection: CaptureRejection?

    public init(
        store: Store,
        preferences: Preferences,
        pasteboard: NSPasteboard = .general,
        frontmostApp: @escaping @Sendable () -> SourceApp = SourceResolver.frontmost
    ) {
        let queue = DispatchSerialQueue(label: "\(Brand.releaseBundleID).monitor", qos: .utility)
        self.queue = queue
        self.unownedExecutor = queue.asUnownedSerialExecutor()
        self.pasteboard = pasteboard
        self.store = store
        self.preferences = preferences
        self.frontmostApp = frontmostApp
        self.lastChangeCount = pasteboard.changeCount
    }

    /// Starts polling. Whatever is on the pasteboard right now is not recorded:
    /// it was copied while Shelf was not running, or while capture was paused.
    public func start() {
        isRunning = true
        lastChangeCount = pasteboard.changeCount
        resumeTimerIfNeeded()
    }

    public func stop() {
        isRunning = false
        timer?.cancel()
        timer = nil
    }

    public func setOnCapture(_ handler: @escaping @Sendable (ClipItem) -> Void) {
        onCapture = handler
    }

    public func setOnAccessBlocked(_ handler: @escaping @Sendable () -> Void) {
        onAccessBlocked = handler
    }

    /// Locking suspends the timer entirely unless capture-while-locked is on.
    public func setScreenLocked(_ locked: Bool) {
        isScreenLocked = locked
        if locked, !preferences.captureWhileLocked {
            timer?.cancel()
            timer = nil
        } else if !locked {
            // Copies made while locked were not allowed; skip them.
            if !preferences.captureWhileLocked { lastChangeCount = pasteboard.changeCount }
            resumeTimerIfNeeded()
        }
    }

    private func resumeTimerIfNeeded() {
        guard isRunning, timer == nil, !(isScreenLocked && !preferences.captureWhileLocked) else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.interval, repeating: Self.interval, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.tick() }
        }
        timer.resume()
        self.timer = timer
    }

    /// One poll. Public so tests can drive the monitor without waiting for the timer.
    public func tick() async {
        guard !isBusy else { return }
        let count = pasteboard.changeCount
        let frontmostNow = frontmostApp()
        guard count != lastChangeCount else {
            frontmostAtLastTick = frontmostNow
            return
        }
        isBusy = true
        defer {
            isBusy = false
            frontmostAtLastTick = frontmostApp()
        }
        let appsDuringCopy = [frontmostAtLastTick, frontmostNow].compactMap(\.self)

        var stableCount = count
        for _ in 0..<5 {
            try? await Task.sleep(for: Self.debounce)
            let latest = pasteboard.changeCount
            if latest == stableCount { break }
            stableCount = latest
        }
        lastChangeCount = stableCount
        await capture(expectedChangeCount: stableCount, appsDuringCopy: appsDuringCopy)
    }

    /// The order matters: nothing on the pasteboard is touched while paused or
    /// while macOS would ask about every read; then only the list of types is
    /// read for the filters, then the app the pasteboard names, and the content
    /// last, once every filter has passed.
    private func capture(expectedChangeCount: Int, appsDuringCopy: [SourceApp]) async {
        if preferences.isPaused() {
            reject(.paused)
            return
        }
        if !clipboardAccessAllowed() {
            reject(.clipboardAccessNotAllowed)
            return
        }
        let types = Set(pasteboard.types?.map(\.rawValue) ?? [])
        let settings = CaptureSettings(preferences)
        let appsAround = (appsDuringCopy + [frontmostApp()]).map(\.bundleID)
        if let rejection = filter(types: types, apps: appsAround, settings: settings) {
            reject(rejection)
            return
        }
        let declaredSource = pasteboard.string(forType: NSPasteboard.PasteboardType(PasteboardTypes.source))
        if let rejection = filter(types: types, apps: [declaredSource] + appsAround, settings: settings) {
            reject(rejection)
            return
        }
        let frontmost = appsDuringCopy.last ?? frontmostApp()
        let source = SourceResolver.resolve(types: types, declaredSource: declaredSource, frontmost: frontmost)

        let snapshot = PasteboardSnapshot.read(from: pasteboard, maxBytes: settings.maxItemBytes)
        // Changed again while reading: the next tick records the newer content.
        guard pasteboard.changeCount == expectedChangeCount else { return }
        guard !snapshot.isEmpty else {
            reject(.empty)
            return
        }
        if settings.detectSecrets, let text = snapshot.plainText, SecretDetector.looksLikeSecret(text) {
            reject(.looksLikeSecret)
            return
        }

        let captured = ItemBuilder.build(from: snapshot, source: source, maxItemBytes: settings.maxItemBytes)
        lastRejection = nil
        do {
            let item = try await store.insert(captured)
            onCapture?(item)
            if item.kind == .file, !item.hasThumbnail, item.filePaths.count == 1,
               let thumbnail = await Thumbnailer.thumbnail(ofFileAt: URL(fileURLWithPath: item.filePaths[0])) {
                try await store.setThumbnail(item.id, data: thumbnail)
            }
        } catch {
            Log.capture.error("Insert failed: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    private func filter(types: Set<String>, apps: [String?], settings: CaptureSettings) -> CaptureRejection? {
        CaptureFilter.evaluate(types: types, sourceBundleIDs: Array(Set(apps.compactMap { $0 })),
                               isScreenLocked: isScreenLocked, settings: settings)
    }

    /// Since macOS 15.4, reading the general pasteboard by itself makes macOS
    /// alert, unless the user chose Always Allow. Before the first alert the
    /// state is "default": one read lets macOS ask. After that only Always
    /// Allow is read; otherwise an alert would appear on every copy.
    private func clipboardAccessAllowed() -> Bool {
        guard #available(macOS 15.4, *) else { return true }
        switch pasteboard.accessBehavior {
        case .ask, .alwaysDeny:
            onAccessBlocked?()
            return false
        default:
            return true
        }
    }

    private func reject(_ rejection: CaptureRejection) {
        lastRejection = rejection
        Log.capture.debug("Skipped a copy: \(String(describing: rejection), privacy: .public)")
    }
}
