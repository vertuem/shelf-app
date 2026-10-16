import Foundation
import ShelfCore

/// Imports Maccy's history (v1.1). Offered once on first launch when Maccy's
/// database is found, and from Settings at any time. Every row goes through the
/// same filters, secrets check and classifier as a live copy; pinned rows land on
/// a "Maccy" pinboard.
public enum MaccyImporter {
    public typealias Result = HistoryImportResult

    static let ignoredTypes: Set<String> = [PasteboardTypes.remoteClipboard, "org.p0deje.Maccy", Brand.originMarkerType]

    public static func importHistory(from databaseURL: URL, into store: Store, preferences: Preferences) async throws -> Result {
        try await importRows(MaccyDatabase.readRows(from: databaseURL), into: store, preferences: preferences)
    }

    static func importRows(_ rows: [MaccyDatabase.Row], into store: Store, preferences: Preferences) async throws -> Result {
        let imported = rows.map { row in
            ImportedRow(
                firstCopied: row.firstCopied,
                lastCopied: row.lastCopied,
                source: HistoryImporter.source(bundleID: row.application),
                pinboard: row.pinned ? "Maccy" : nil,
                representations: row.representations
            )
        }
        return try await HistoryImporter.importRows(imported, into: store, preferences: preferences, ignoredTypes: ignoredTypes)
    }
}
