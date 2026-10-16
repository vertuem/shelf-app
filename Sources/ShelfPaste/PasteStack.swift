import AppKit
import Observation
import ShelfCore

/// The sequential paste queue.
///
/// While the stack is open, every copy is appended and every Cmd+V in any app
/// pastes the next item, oldest first (or newest first with `reversed`), then
/// advances. Cmd+V is caught by a `CommandVTap` that exists only while the
/// stack is open. Without Accessibility the tap cannot be installed; the panel
/// then shows the queue and a click copies the item instead.
@MainActor
@Observable
public final class PasteStack {
    public private(set) var items: [ClipItem] = []
    /// Ids already pasted, shown dimmed.
    public private(set) var pasted: Set<UUID> = []
    public private(set) var isOpen = false
    public private(set) var isTapActive = false
    public var reversed = false

    @ObservationIgnored private let store: Store
    @ObservationIgnored private let paster: Paster
    @ObservationIgnored private let pasteboard: NSPasteboard
    @ObservationIgnored private var tap: (any CommandVTapping)?
    @ObservationIgnored private let makeTap: (@escaping () -> Void) -> any CommandVTapping
    /// Payloads loaded ahead of time; the tap has no time to read the disk.
    private var cache: [UUID: [ClipRepresentation]] = [:]
    @ObservationIgnored private var eventsTask: Task<Void, Never>?

    public init(
        store: Store,
        paster: Paster,
        pasteboard: NSPasteboard = .general,
        makeTap: @escaping (@escaping () -> Void) -> any CommandVTapping = { CommandVTap(onCommandV: $0) }
    ) {
        self.store = store
        self.paster = paster
        self.pasteboard = pasteboard
        self.makeTap = makeTap
    }

    /// The item the next Cmd+V will paste.
    public var next: ClipItem? {
        let pending = items.filter { !pasted.contains($0.id) }
        return reversed ? pending.last : pending.first
    }

    /// Items in display order: the order they will be pasted in.
    public var ordered: [ClipItem] { reversed ? items.reversed() : items }

    public var remainingCount: Int { items.count - pasted.count }

    /// False while the next item's payload is still loading. A ⌘V in that moment
    /// passes through untouched, so the panel says so.
    public var isNextReady: Bool {
        guard let next else { return true }
        return cache[next.id] != nil
    }

    public func open() {
        guard !isOpen else { return }
        isOpen = true
        items = []
        pasted = []
        cache = [:]
        let tap = makeTap { [weak self] in self?.handleCommandV() }
        isTapActive = tap.install()
        self.tap = tap
        eventsTask = Task { [weak self, store] in
            for await event in store.events() {
                guard case .captured(let item, _) = event else { continue }
                self?.append(item)
            }
        }
    }

    public func close() {
        guard isOpen else { return }
        isOpen = false
        tap?.remove()
        tap = nil
        isTapActive = false
        eventsTask?.cancel()
        eventsTask = nil
        cache = [:]
    }

    public func toggle() {
        if isOpen {
            close()
        } else {
            open()
        }
    }

    /// Adds an item: every copy while open, or "Add to Paste Stack" on a card.
    public func append(_ item: ClipItem) {
        guard isOpen else { return }
        // Copying an item again moves it to the end, pasted or not; an id appears once.
        items.removeAll { $0.id == item.id }
        pasted.remove(item.id)
        items.append(item)
        prefetch(item)
    }

    public func remove(_ item: ClipItem) {
        items.removeAll { $0.id == item.id }
        pasted.remove(item.id)
        cache[item.id] = nil
    }

    public func clear() {
        items = []
        pasted = []
        cache = [:]
    }

    /// Called from the event tap, synchronously, before the target app sees Cmd+V.
    /// The payload must already be in memory: there is no time to read the disk.
    func handleCommandV() {
        guard let item = next, let representations = cache[item.id] else { return }
        paster.copyToClipboard(item, representations: representations)
        pasted.insert(item.id)
    }

    /// The fallback without Accessibility: clicking an item puts it on the clipboard.
    public func copyByClick(_ item: ClipItem) async {
        let representations: [ClipRepresentation]
        if let cached = cache[item.id] {
            representations = cached
        } else {
            guard let loaded = try? await paster.payload(for: item) else { return }
            representations = loaded
        }
        paster.copyToClipboard(item, representations: representations)
        pasted.insert(item.id)
    }

    private func prefetch(_ item: ClipItem) {
        Task { [weak self, paster] in
            guard let representations = try? await paster.payload(for: item) else { return }
            self?.cache[item.id] = representations
        }
    }

    /// Test hook: simulate the tap seeing Cmd+V.
    public func simulateCommandV() {
        handleCommandV()
    }

    /// Test hook: wait until every queued item's payload is in memory.
    public func waitUntilPrefetched() async {
        for _ in 0..<200 where items.contains(where: { cache[$0.id] == nil }) {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}
