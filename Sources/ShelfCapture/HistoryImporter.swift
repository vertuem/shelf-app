import Foundation
import ShelfCore

/// What an import from another clipboard manager reports.
public struct HistoryImportResult: Sendable, Equatable {
    public var imported: Int
    public var skipped: Int
    public var pinned: Int

    public init(imported: Int = 0, skipped: Int = 0, pinned: Int = 0) {
        self.imported = imported
        self.skipped = skipped
        self.pinned = pinned
    }
}

/// One copy read from another manager's database, before the capture pipeline.
struct ImportedRow: Sendable {
    var firstCopied: Date
    var lastCopied: Date
    var source: SourceApp
    /// Name of the pinboard to put the item on; nil for history only.
    var pinboard: String?
    /// A title the user gave the item in the other app.
    var title: String?
    /// Every type of every pasteboard item; `itemIndex` groups multi-item copies.
    var representations: [ClipRepresentation]
}

/// The steps every importer shares, so an imported row is treated like a live
/// copy: the capture filter, the secrets check, `ItemBuilder` and the store.
enum HistoryImporter {
    static func importRows(
        _ rows: [ImportedRow],
        into store: Store,
        preferences: Preferences,
        ignoredTypes: Set<String>
    ) async throws -> HistoryImportResult {
        let settings = CaptureSettings(preferences)
        var result = HistoryImportResult()
        var pinboards: [String: Pinboard] = [:]
        for row in rows {
            let representations = row.representations.filter { !ignoredTypes.contains($0.uti) }
            let rejection = CaptureFilter.evaluate(
                types: Set(representations.map(\.uti)),
                sourceBundleIDs: [row.source.bundleID].compactMap { $0 },
                isScreenLocked: false,
                settings: settings
            )
            guard !representations.isEmpty, rejection == nil else {
                result.skipped += 1
                continue
            }
            let snapshot = PasteboardSnapshot(items: items(grouping: representations))
            if settings.detectSecrets, let text = snapshot.plainText, SecretDetector.looksLikeSecret(text) {
                result.skipped += 1
                continue
            }
            let captured = ItemBuilder.build(from: snapshot, source: row.source, maxItemBytes: settings.maxItemBytes, now: row.firstCopied)
            let item = try await store.insert(captured, lastUsedAt: row.lastCopied)
            result.imported += 1
            if let title = row.title {
                try await store.setTitle(item.id, title: title)
            }
            if let name = row.pinboard {
                if pinboards[name] == nil {
                    pinboards[name] = try await store.createPinboard(name: name)
                }
                if let pinboard = pinboards[name] {
                    try await store.pin(item.id, to: pinboard.id)
                    result.pinned += 1
                }
            }
        }
        return result
    }

    /// The source app for a bundle id, named from the installed app when possible.
    static func source(bundleID: String?, name: String? = nil) -> SourceApp {
        guard let bundleID else { return SourceApp(bundleID: nil, name: nil) }
        return SourceApp(bundleID: bundleID, name: SourceResolver.appName(for: bundleID) ?? name)
    }

    /// One array per pasteboard item, in the order the items were first seen.
    static func items(grouping representations: [ClipRepresentation]) -> [[ClipRepresentation]] {
        var items: [[ClipRepresentation]] = []
        var positions: [Int: Int] = [:]
        for representation in representations {
            if let position = positions[representation.itemIndex] {
                items[position].append(representation)
            } else {
                positions[representation.itemIndex] = items.count
                items.append([representation])
            }
        }
        return items
    }
}
