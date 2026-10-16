import Foundation
import GRDB

/// Reads Maccy's database (v1.1 import). Maccy 0.15 to 2.x keep a Core Data /
/// SwiftData store at the same path: `ZHISTORYITEM` has one row per copy and
/// `ZHISTORYITEMCONTENT` one row per pasteboard type. Dates are seconds since
/// 2001; pinned items have a non-null `ZPIN`.
///
/// Classification happens in ShelfCapture; this file only reads rows.
public enum MaccyDatabase {
    public static var candidatePaths: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Library/Containers/org.p0deje.Maccy/Data/Library/Application Support/Maccy/Storage.sqlite"),
            home.appendingPathComponent("Library/Application Support/Maccy/Storage.sqlite"),
        ]
    }

    public static var url: URL? {
        candidatePaths.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    public struct Row: Sendable {
        public var firstCopied: Date
        public var lastCopied: Date
        public var application: String?
        public var pinned: Bool
        public var representations: [ClipRepresentation]
    }

    static let referenceDate = Date(timeIntervalSinceReferenceDate: 0)

    /// Copies the store with its WAL to a temporary folder first, so Maccy can
    /// keep running and its files are never locked or modified.
    public static func readRows(from databaseURL: URL) async throws -> [Row] {
        let workDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("maccy-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { FileManager.default.removeIfPresent(workDirectory) }
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: databaseURL.path + suffix)
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.copyItem(at: source, to: workDirectory.appendingPathComponent("Storage.sqlite" + suffix))
            }
        }

        let queue = try DatabaseQueue(path: workDirectory.appendingPathComponent("Storage.sqlite").path)
        defer { do { try queue.close() } catch {} }
        return try await queue.read { db in
            let columns = Set(try db.columns(in: "ZHISTORYITEM").map { $0.name.uppercased() })
            let application = columns.contains("ZAPPLICATION") ? "ZAPPLICATION" : "NULL"
            let pin = columns.contains("ZPIN") ? "ZPIN" : "NULL"
            var contents: [Int64: [ClipRepresentation]] = [:]
            for row in try GRDB.Row.fetchAll(db, sql: "SELECT ZITEM, ZTYPE, ZVALUE FROM ZHISTORYITEMCONTENT ORDER BY Z_PK") {
                guard let item: Int64 = row["ZITEM"], let type: String = row["ZTYPE"], let value: Data = row["ZVALUE"] else { continue }
                contents[item, default: []].append(ClipRepresentation(uti: type, data: value))
            }
            return try GRDB.Row.fetchAll(db, sql: """
                SELECT Z_PK, ZFIRSTCOPIEDAT, ZLASTCOPIEDAT, \(application) AS app, \(pin) AS pin
                FROM ZHISTORYITEM ORDER BY ZLASTCOPIEDAT
                """).map { row in
                Row(
                    firstCopied: (row["ZFIRSTCOPIEDAT"] as Double?).map { referenceDate.addingTimeInterval($0) } ?? Date(),
                    lastCopied: (row["ZLASTCOPIEDAT"] as Double?).map { referenceDate.addingTimeInterval($0) } ?? Date(),
                    application: row["app"],
                    pinned: (row["pin"] as String?) != nil,
                    representations: contents[row["Z_PK"]] ?? []
                )
            }
        }
    }

    /// Number of history rows, for the "Import N items from Maccy?" prompt.
    public static func itemCount(at databaseURL: URL) -> Int? {
        var configuration = Configuration()
        configuration.readonly = true
        guard let queue = try? DatabaseQueue(path: databaseURL.path, configuration: configuration) else { return nil }
        defer { do { try queue.close() } catch {} }
        return try? queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ZHISTORYITEM") }
    }
}
