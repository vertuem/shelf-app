import AppKit
import ShelfCore

/// Every type of every item on a pasteboard at one moment, with its bytes.
///
/// Reading happens once per change, off the main thread. Promised types are
/// listed but not read, because asking for them makes the source app produce
/// the file, which can block for seconds.
public struct PasteboardSnapshot: Sendable {
    /// One array per `NSPasteboardItem`, types in the order the source app declared them.
    public var items: [[ClipRepresentation]]
    /// Promised types seen but not read.
    public var promisedTypes: [String]
    /// Types not read because the copy was already over the size limit.
    public var skippedTypes: [String]

    public init(items: [[ClipRepresentation]], promisedTypes: [String] = [], skippedTypes: [String] = []) {
        self.items = items
        self.promisedTypes = promisedTypes
        self.skippedTypes = skippedTypes
    }

    public var representations: [ClipRepresentation] { items.flatMap { $0 } }

    public var allTypes: Set<String> {
        Set(representations.map(\.uti)).union(promisedTypes)
    }

    public var byteSize: Int { representations.reduce(0) { $0 + $1.data.count } }

    public var isEmpty: Bool { representations.isEmpty && promisedTypes.isEmpty }

    /// Data for a type from the first item that has it.
    public func data(for type: String) -> Data? {
        representations.first { $0.uti == type }?.data
    }

    /// Data for a type from every item that has it, in item order.
    public func allData(for type: String) -> [Data] {
        items.compactMap { item in item.first { $0.uti == type }?.data }
    }

    /// The plain text, from UTF-8, UTF-16 or the legacy string type.
    public var plainText: String? {
        if let data = data(for: PasteboardTypes.plainText) {
            return String(data: data, encoding: .utf8)
        }
        if let data = data(for: PasteboardTypes.utf16PlainText) {
            return String(data: data, encoding: .utf16)
        }
        if let data = data(for: PasteboardTypes.legacyString) {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }
}

extension PasteboardSnapshot {
    /// Reads every pasteboard item. Called on the monitor's queue.
    ///
    /// Once the running total passes `maxBytes`, remaining types are listed in
    /// `skippedTypes` instead of read, so a multi-gigabyte copy does not force
    /// every flavor of it into memory. (The pasteboard has no size query, so the
    /// type that crosses the limit is still read.)
    public static func read(from pasteboard: NSPasteboard, maxBytes: Int = .max) -> PasteboardSnapshot {
        var items: [[ClipRepresentation]] = []
        var promised: [String] = []
        var skipped: [String] = []
        var total = 0
        for (index, item) in (pasteboard.pasteboardItems ?? []).enumerated() {
            var representations: [ClipRepresentation] = []
            let itemTypes = Set(item.types.map(\.rawValue))
            for type in item.types where !PasteboardTypes.isSynthesizedAlias(type.rawValue, itemTypes: itemTypes) {
                if PasteboardTypes.isPromise(type.rawValue), type.rawValue != PasteboardTypes.promisedFileContentType,
                   type.rawValue != PasteboardTypes.promisedSuggestedName {
                    promised.append(type.rawValue)
                    continue
                }
                guard total <= maxBytes else {
                    skipped.append(type.rawValue)
                    continue
                }
                guard let data = item.data(forType: type) else { continue }
                total += data.count
                representations.append(ClipRepresentation(itemIndex: index, uti: type.rawValue, data: data))
            }
            items.append(representations)
        }
        return PasteboardSnapshot(items: items, promisedTypes: promised, skippedTypes: skipped)
    }
}
