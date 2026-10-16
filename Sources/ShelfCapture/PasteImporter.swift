import Foundation
import ShelfCore

/// Imports Paste's history and pinboards (pasteapp.io). Offered in Settings
/// whenever Paste's database is found. Every row goes through the same filters,
/// secrets check and classifier as a live copy; items on a Paste pinboard land
/// on a pinboard of the same name.
public enum PasteImporter {
    public typealias Result = HistoryImportResult

    /// Markers that carry no content.
    static let ignoredTypes: Set<String> = [PasteboardTypes.remoteClipboard, Brand.originMarkerType]

    public static func importHistory(from databaseURL: URL, into store: Store, preferences: Preferences) async throws -> Result {
        try await importRows(PasteDatabase.readRows(from: databaseURL), into: store, preferences: preferences)
    }

    static func importRows(_ rows: [PasteDatabase.Row], into store: Store, preferences: Preferences) async throws -> Result {
        let imported = rows.map { row in
            ImportedRow(
                firstCopied: row.firstCopied,
                lastCopied: row.lastCopied,
                source: HistoryImporter.source(bundleID: row.application, name: row.applicationName),
                pinboard: row.pinboard,
                title: row.title,
                representations: row.representations
            )
        }
        return try await HistoryImporter.importRows(imported, into: store, preferences: preferences, ignoredTypes: ignoredTypes)
    }
}
