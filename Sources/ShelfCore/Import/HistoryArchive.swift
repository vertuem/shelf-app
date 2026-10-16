import Foundation
import GRDB

/// Export and import of the whole history as one zip (v1.1).
///
/// The zip holds a consistent copy of the database (`VACUUM INTO`), every blob
/// and thumbnail decrypted, and a `manifest.json`. It is deliberately
/// unencrypted so it can be opened anywhere; the export dialog says so.
///
/// ```
/// manifest.json
/// shelf.sqlite
/// blobs/<item-id>/<n>-<ordinal>-<type>.bin   raw bytes, no envelope
/// thumbs/<item-id>.heic
/// ```
public enum HistoryArchive {
    public static let formatVersion = 1

    public struct Manifest: Codable, Sendable, Equatable {
        public var format: Int
        public var app: String
        public var appVersion: String
        public var exportedAt: Date
        public var itemCount: Int
        public var encrypted: Bool
    }

    public struct ImportResult: Sendable, Equatable {
        public var imported = 0
        public var duplicates = 0
        public var pinboards = 0
    }

    public enum ArchiveError: Error, Equatable {
        case unreadable
        case newerFormat(Int)
        case zipFailed(Int32)
    }

    // MARK: Export

    public static func export(store: Store, to zipURL: URL, appVersion: String) async throws -> Manifest {
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { FileManager.default.removeIfPresent(staging) }

        let databaseCopy = staging.appendingPathComponent("\(Brand.slug).sqlite")
        try await store.copyDatabase(to: databaseCopy)
        let rows = try await store.read { db -> [(String, String)] in
            try GRDB.Row.fetchAll(db, sql: "SELECT item_id, blob_path FROM item_type").map { ($0["item_id"], $0["blob_path"]) }
        }
        let itemIDs = try await store.read { db in try String.fetchAll(db, sql: "SELECT id FROM item WHERE has_thumbnail = 1") }
        let count = try await store.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item") ?? 0 }

        for (_, relativePath) in rows {
            let target = staging.appendingPathComponent("blobs").appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try store.blobs.read(relativePath: relativePath).write(to: target)
        }
        let thumbs = staging.appendingPathComponent("thumbs", isDirectory: true)
        try FileManager.default.createDirectory(at: thumbs, withIntermediateDirectories: true)
        for key in itemIDs {
            guard let id = UUID(uuidString: key), let data = store.blobs.readThumbnail(for: id) else { continue }
            try data.write(to: thumbs.appendingPathComponent("\(key).heic"))
        }

        let manifest = Manifest(format: formatVersion, app: Brand.name, appVersion: appVersion,
                                exportedAt: Date(), itemCount: count, encrypted: false)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: staging.appendingPathComponent("manifest.json"))

        if FileManager.default.fileExists(atPath: zipURL.path) {
            try FileManager.default.removeItem(at: zipURL)
        }
        try runDitto(["-c", "-k", "--sequesterRsrc", staging.path, zipURL.path])
        return manifest
    }

    // MARK: Import

    /// Adds every item of an archive. Items already present (same content hash)
    /// are moved to their archived position in time instead of duplicated, and
    /// pinboards are matched by name.
    public static func importArchive(from zipURL: URL, into store: Store) async throws -> ImportResult {
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { FileManager.default.removeIfPresent(staging) }
        try runDitto(["-x", "-k", zipURL.path, staging.path])

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifestData = try? Data(contentsOf: staging.appendingPathComponent("manifest.json")),
              let manifest = try? decoder.decode(Manifest.self, from: manifestData) else { throw ArchiveError.unreadable }
        guard manifest.format <= formatVersion else { throw ArchiveError.newerFormat(manifest.format) }

        var configuration = Configuration()
        configuration.readonly = true
        let source = try DatabaseQueue(path: staging.appendingPathComponent("\(Brand.slug).sqlite").path, configuration: configuration)
        defer { do { try source.close() } catch {} }

        let (items, types, boards, pins) = try await source.read { db in
            (
                try GRDB.Row.fetchAll(db, sql: "SELECT * FROM item ORDER BY created_at").map(Rows.item),
                try GRDB.Row.fetchAll(db, sql: "SELECT item_id, item_index, uti, blob_path FROM item_type ORDER BY item_id, ordinal")
                    .map { ArchivedType(itemID: $0["item_id"], itemIndex: $0["item_index"], uti: $0["uti"], path: $0["blob_path"]) },
                try GRDB.Row.fetchAll(db, sql: "SELECT *, 0 AS item_count FROM pinboard ORDER BY ordinal").map(Rows.pinboard),
                try GRDB.Row.fetchAll(db, sql: "SELECT pinboard_id, item_id FROM pin ORDER BY ordinal DESC")
                    .map { (board: $0["pinboard_id"] as String, item: $0["item_id"] as String) }
            )
        }

        let typesByItem = Dictionary(grouping: types, by: \.itemID)
        var result = ImportResult()
        var newIDs: [String: UUID] = [:]
        var freshKeys: Set<String> = []
        let existingHashes = try await store.read { db in Set(try Data.fetchAll(db, sql: "SELECT hash FROM item")) }

        let blobRoot = staging.appendingPathComponent("blobs", isDirectory: true).standardizedFileURL
        for item in items {
            let key = Rows.key(item.id)
            let representations = try (typesByItem[key] ?? []).map { type in
                ClipRepresentation(itemIndex: type.itemIndex, uti: type.uti,
                                   data: try Data(contentsOf: Self.contained(type.path, in: blobRoot)))
            }
            let thumbnail = try? Data(contentsOf: staging.appendingPathComponent("thumbs/\(key).heic"))
            let captured = CapturedItem(
                capturedAt: item.createdAt, kind: item.kind, sourceBundleID: item.sourceBundleID,
                sourceAppName: item.sourceAppName, hash: item.hash, byteSize: item.byteSize, oversized: item.oversized,
                preview: item.preview, width: item.width, height: item.height, filePaths: item.filePaths, url: item.url,
                colorHex: item.colorHex, promised: item.promised, representations: representations, thumbnail: thumbnail
            )
            if existingHashes.contains(item.hash) {
                result.duplicates += 1
            } else {
                result.imported += 1
                freshKeys.insert(key)
            }
            let stored = try await store.insert(captured, lastUsedAt: item.lastUsedAt, returnToHistory: item.inHistory)
            newIDs[key] = stored.id
        }

        var existingBoards = Dictionary(try await store.pinboards().map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        var boardIDs: [String: UUID] = [:]
        for board in boards {
            if let existing = existingBoards[board.name.lowercased()] {
                boardIDs[Rows.key(board.id)] = existing.id
            } else {
                let created = try await store.createPinboard(name: board.name, color: board.color, icon: board.icon)
                existingBoards[board.name.lowercased()] = created
                boardIDs[Rows.key(board.id)] = created.id
                result.pinboards += 1
            }
        }
        for pin in pins {
            guard let boardID = boardIDs[pin.board], let itemID = newIDs[pin.item] else { continue }
            try await store.pin(itemID, to: boardID)
        }
        // Items that were pinned-only in the archive leave history once their pins exist.
        for item in items where !item.inHistory && freshKeys.contains(Rows.key(item.id)) {
            if let id = newIDs[Rows.key(item.id)] { try await store.removeFromHistory([id]) }
        }
        return result
    }

    /// Resolves a path from the archive and refuses anything that escapes the
    /// archive's blob folder (`../../.ssh/id_ed25519` in a crafted zip).
    static func contained(_ relativePath: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(relativePath).standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = root.resolvingSymlinksInPath().path + "/"
        guard url.path.hasPrefix(rootPath) else { throw ArchiveError.unreadable }
        return url
    }

    struct ArchivedType: Sendable {
        var itemID: String
        var itemIndex: Int
        var uti: String
        var path: String
    }

    static func runDitto(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ArchiveError.zipFailed(process.terminationStatus) }
    }
}
