import Foundation

/// Changes published by the `Store`. The view model and the Paste Stack each
/// subscribe with `Store.events()` and apply them on the main actor.
public enum StoreEvent: Sendable {
    /// A copy was recorded. `isNew` is false when it matched an existing item by hash,
    /// which moves that item to the front instead of adding a duplicate.
    case captured(ClipItem, isNew: Bool)
    /// An item was pasted from Shelf and moved to the front.
    case used(ClipItem)
    /// Metadata changed: a link title arrived or a promised file was resolved.
    case updated(ClipItem)
    /// Items left the Clipboard tab. Pinned copies may still exist.
    case removed(Set<UUID>)
    /// Pins were added, removed or reordered.
    case pinsChanged
    /// Pinboards were created, renamed, recolored, reordered or deleted.
    case pinboardsChanged
    /// Bulk change (erase, import, retention purge). Reload everything.
    case reloaded
}

/// Fans one stream of events out to any number of subscribers.
final class EventBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<StoreEvent>.Continuation] = [:]

    func stream() -> AsyncStream<StoreEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<StoreEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        continuation.onTermination = { [weak self] _ in
            self?.remove(id)
        }
        lock.lock()
        continuations[id] = continuation
        lock.unlock()
        return stream
    }

    func send(_ event: StoreEvent) {
        lock.lock()
        let targets = Array(continuations.values)
        lock.unlock()
        for continuation in targets {
            continuation.yield(event)
        }
    }

    private func remove(_ id: UUID) {
        lock.lock()
        continuations[id] = nil
        lock.unlock()
    }
}
