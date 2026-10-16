import Foundation
import GRDB

/// Reads Paste's database (pasteapp.io, by WIHEADS). Paste keeps a Core Data
/// store named `db.sqlite`: `ZITEMENTITY` has one row per clip, `ZITEMDATAENTITY`
/// its pasteboard payload, `ZLISTENTITY` the Clipboard and the pinboards, and
/// `ZAPPLICATIONENTITY` the source apps. Dates are seconds since 2001.
///
/// The payload is a property list: an array with one dictionary per
/// `NSPasteboardItem`, each holding `types` (the UTIs in declaration order) and
/// `dataByType`. Inline values start with a `0x01` byte before the plist, which is
/// LZFSE-compressed when it starts with `bvx`. Values over Core Data's external
/// storage threshold are a `0x02` byte and a UUID naming a file in
/// `.db_SUPPORT/_EXTERNAL_DATA/` next to the database, which holds the bare
/// payload. Verified against Paste 5.
///
/// Classification happens in ShelfCapture; this file only reads rows.
public enum PasteDatabase {
    public static var candidatePaths: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Library/Containers/com.wiheads.paste/Data/Library/Application Support/Paste/db.sqlite"),
            home.appendingPathComponent("Library/Containers/com.wiheads.paste-setapp/Data/Library/Application Support/Paste/db.sqlite"),
            home.appendingPathComponent("Library/Application Support/com.wiheads.paste-setapp/db.sqlite"),
            home.appendingPathComponent("Library/Application Support/Paste/db.sqlite"),
        ]
    }

    public static var url: URL? {
        candidatePaths.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    public struct Row: Sendable {
        public var firstCopied: Date
        public var lastCopied: Date
        /// Bundle id of the source app, and the name Paste recorded for it.
        public var application: String?
        public var applicationName: String?
        /// The Paste pinboard holding this item; nil for the Clipboard history.
        public var pinboard: String?
        /// A title the user gave the item in Paste.
        public var title: String?
        /// Every type of every pasteboard item, with `itemIndex` set.
        public var representations: [ClipRepresentation]
    }

    static let referenceDate = Date(timeIntervalSinceReferenceDate: 0)
    /// `ZLISTENTITY.ZRAWTYPE`: 1 is the Clipboard, 2 a pinboard.
    static let pinboardListType = 2
    static let inlineMarker: UInt8 = 1
    static let externalMarker: UInt8 = 2
    static let lzfseMagic = Data("bvx".utf8)

    /// Folder with the payloads Core Data keeps outside the database.
    public static func externalDataDirectory(for databaseURL: URL) -> URL {
        databaseURL.deletingLastPathComponent().appendingPathComponent(".db_SUPPORT/_EXTERNAL_DATA")
    }

    /// Copies the store with its WAL to a temporary folder first, so Paste can
    /// keep running and its files are never locked or modified. External payload
    /// files are read in place; they can be large and are never written.
    public static func readRows(from databaseURL: URL) async throws -> [Row] {
        let externalData = externalDataDirectory(for: databaseURL)
        let workDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("paste-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { FileManager.default.removeIfPresent(workDirectory) }
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: databaseURL.path + suffix)
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.copyItem(at: source, to: workDirectory.appendingPathComponent("db.sqlite" + suffix))
            }
        }

        let queue = try DatabaseQueue(path: workDirectory.appendingPathComponent("db.sqlite").path)
        defer { do { try queue.close() } catch {} }
        return try await queue.read { db in
            let columns = Set(try db.columns(in: "ZITEMENTITY").map { $0.name.uppercased() })
            func column(_ name: String) -> String { columns.contains(name) ? "i.\(name)" : "NULL" }
            let hasData = try db.tableExists("ZITEMDATAENTITY")
            let hasApps = try db.tableExists("ZAPPLICATIONENTITY") && columns.contains("ZSOURCEAPPLICATION")
            let hasLists = try db.tableExists("ZLISTENTITY") && columns.contains("ZLIST")
            var sql = """
                SELECT \(column("ZCREATEDAT")) AS created, \(column("ZTIMESTAMP")) AS copied,
                    \(hasApps ? "a.ZBUNDLEIDENTIFIER" : "NULL") AS bundle, \(hasApps ? "a.ZNAME" : "NULL") AS appName,
                    \(hasLists ? "l.ZRAWTYPE" : "NULL") AS listType, \(hasLists ? "l.ZNAME" : "NULL") AS listName,
                    \(hasData ? "d.ZRAWPASTEBOARDITEMS" : "NULL") AS payload, \(column("ZTITLE")) AS title
                FROM ZITEMENTITY i
                """
            if hasData {
                sql += columns.contains("ZDATA") ? " LEFT JOIN ZITEMDATAENTITY d ON d.Z_PK = i.ZDATA" : " LEFT JOIN ZITEMDATAENTITY d ON d.ZITEM = i.Z_PK"
            }
            if hasApps { sql += " LEFT JOIN ZAPPLICATIONENTITY a ON a.Z_PK = i.ZSOURCEAPPLICATION" }
            if hasLists { sql += " LEFT JOIN ZLISTENTITY l ON l.Z_PK = i.ZLIST" }
            sql += " ORDER BY copied"
            return try GRDB.Row.fetchAll(db, sql: sql).map { row in
                let created = (row["created"] as Double?).map { referenceDate.addingTimeInterval($0) }
                let copied = (row["copied"] as Double?).map { referenceDate.addingTimeInterval($0) }
                let onPinboard = (row["listType"] as Int?) == pinboardListType
                return Row(
                    firstCopied: created ?? copied ?? Date(),
                    lastCopied: copied ?? created ?? Date(),
                    application: row["bundle"],
                    applicationName: row["appName"],
                    pinboard: onPinboard ? (row["listName"] as String?) ?? "Paste" : nil,
                    title: (row["title"] as String?).flatMap { $0.isEmpty ? nil : $0 },
                    representations: (row["payload"] as Data?).map { representations(in: $0, externalDataDirectory: externalData) } ?? []
                )
            }
        }
    }

    /// Number of clips, for the "Import N items from Paste?" prompt.
    public static func itemCount(at databaseURL: URL) -> Int? {
        var configuration = Configuration()
        configuration.readonly = true
        guard let queue = try? DatabaseQueue(path: databaseURL.path, configuration: configuration) else { return nil }
        defer { do { try queue.close() } catch {} }
        return try? queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ZITEMENTITY") }
    }

    /// The pasteboard items in one `ZRAWPASTEBOARDITEMS` value. Empty when the
    /// value cannot be read, so the importer counts the row as skipped.
    static func representations(in value: Data, externalDataDirectory: URL) -> [ClipRepresentation] {
        guard let payload = payload(of: value, externalDataDirectory: externalDataDirectory),
              let items = (try? PropertyListSerialization.propertyList(from: payload, format: nil)) as? [[String: Any]]
        else { return [] }
        var result: [ClipRepresentation] = []
        for (index, item) in items.enumerated() {
            guard let dataByType = item["dataByType"] as? [String: Data] else { continue }
            let types = item["types"] as? [String] ?? dataByType.keys.sorted()
            for type in types {
                if let data = dataByType[type] {
                    result.append(ClipRepresentation(itemIndex: index, uti: type, data: data))
                }
            }
        }
        return result
    }

    /// Unwraps the framing byte, follows an external reference and inflates LZFSE.
    static func payload(of value: Data, externalDataDirectory: URL) -> Data? {
        guard let marker = value.first else { return nil }
        var payload: Data
        switch marker {
        case externalMarker:
            // The reference is the file name as ASCII, zero-terminated. Only a
            // UUID is accepted, so a tampered database cannot name another file.
            let name = String(decoding: value.dropFirst().prefix { $0 != 0 }, as: UTF8.self)
            guard UUID(uuidString: name) != nil,
                  let file = try? Data(contentsOf: externalDataDirectory.appendingPathComponent(name))
            else { return nil }
            payload = file
        case inlineMarker:
            payload = Data(value.dropFirst())
        default:
            payload = value
        }
        if payload.starts(with: lzfseMagic) {
            guard let inflated = try? (payload as NSData).decompressed(using: .lzfse) else { return nil }
            payload = inflated as Data
        }
        return payload
    }
}
