import Foundation
import GRDB

/// The clipboard history: metadata in SQLite, payloads in the `BlobStore`.
///
/// Writes are serialized by the actor. Reads (`history`, `search`, …) are
/// `nonisolated` and run on GRDB's reader pool, so typing in the search field
/// never waits behind a large image being sealed and written.
public actor Store {
    public nonisolated let paths: AppPaths
    public nonisolated let blobs: BlobStore
    private let preferences: Preferences
    private let broadcaster = EventBroadcaster()
    private let lazyPool = LazyPool()
    private var insertsSinceCapCheck = 0
    private let hardCap: Int

    public init(
        paths: AppPaths,
        keyProvider: any BlobKeyProviding,
        preferences: Preferences,
        hardCap: Int = RetentionPeriod.hardCapUnpinnedItems
    ) {
        self.paths = paths
        self.preferences = preferences
        self.hardCap = hardCap
        self.blobs = BlobStore(paths: paths, keyProvider: keyProvider, shouldEncrypt: { preferences.encryptAtRest })
    }

    // MARK: Opening

    /// Opens the database and runs migrations. Called once after the menu-bar icon
    /// shows; every other method also opens lazily, so the order is not critical.
    public func open() throws {
        _ = try pool()
        try blobs.finishInterruptedRotation()
    }

    private nonisolated func pool() throws -> DatabasePool {
        try lazyPool.get(paths: paths)
    }

    /// Subscribes to changes. Each call returns an independent stream.
    public nonisolated func events() -> AsyncStream<StoreEvent> {
        broadcaster.stream()
    }

    // MARK: Capture

    /// Records a copy. Returns the stored item; when the content hash matches an
    /// existing item, that item is moved to the front instead of duplicated.
    ///
    /// `returnToHistory` is false for imports of items that were only pinned: a
    /// match then keeps whatever history state it already had.
    @discardableResult
    public func insert(_ captured: CapturedItem, lastUsedAt: Date? = nil, returnToHistory: Bool = true) throws -> ClipItem {
        let db = try pool()
        let now = lastUsedAt ?? captured.capturedAt

        if let existing = try db.read({ db in
            try Row.fetchOne(db, sql: "SELECT * FROM item WHERE hash = ? ORDER BY last_used_at DESC LIMIT 1",
                             arguments: [captured.hash])
        }).map(Rows.item) {
            var item = existing
            item.lastUsedAt = max(existing.lastUsedAt, now)
            item.inHistory = existing.inHistory || returnToHistory
            try db.write { db in
                try db.execute(sql: "UPDATE item SET last_used_at = ?, in_history = ? WHERE id = ?",
                               arguments: [Rows.millis(item.lastUsedAt), item.inHistory, Rows.key(item.id)])
            }
            broadcaster.send(.captured(item, isNew: false))
            return item
        }

        let id = UUIDv7.make(at: captured.capturedAt)
        let relativePaths = try blobs.write(captured.representations, for: id)
        if let thumbnail = captured.thumbnail {
            try blobs.writeThumbnail(thumbnail, for: id)
        }

        let item = ClipItem(
            id: id,
            createdAt: captured.capturedAt,
            lastUsedAt: now,
            kind: captured.kind,
            sourceBundleID: captured.sourceBundleID,
            sourceAppName: captured.sourceAppName,
            hash: captured.hash,
            byteSize: captured.byteSize,
            oversized: captured.oversized,
            preview: captured.preview,
            width: captured.width,
            height: captured.height,
            filePaths: captured.filePaths,
            url: captured.url,
            colorHex: captured.colorHex,
            promised: captured.promised,
            hasThumbnail: captured.thumbnail != nil
        )

        do {
            try db.write { db in
                try Self.insertRow(item, db: db)
                for (ordinal, representation) in captured.representations.enumerated() {
                    try db.execute(sql: """
                        INSERT INTO item_type(item_id, item_index, uti, blob_path, byte_size, ordinal)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """, arguments: [Rows.key(id), representation.itemIndex, representation.uti,
                                     relativePaths[ordinal], representation.data.count, ordinal])
                }
            }
        } catch {
            blobs.removeFiles(for: id)
            throw error
        }

        broadcaster.send(.captured(item, isNew: true))

        insertsSinceCapCheck += 1
        if insertsSinceCapCheck >= 100 {
            insertsSinceCapCheck = 0
            try enforceHardCap()
        }
        return item
    }

    private static func insertRow(_ item: ClipItem, db: Database) throws {
        try db.execute(sql: """
            INSERT INTO item(id, created_at, last_used_at, kind, source_bundle_id, source_app_name, hash,
                             byte_size, oversized, preview, width, height, file_paths, url, color_hex,
                             in_history, promised, has_thumbnail, link_title)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
            Rows.key(item.id), Rows.millis(item.createdAt), Rows.millis(item.lastUsedAt), item.kind.rawValue,
            item.sourceBundleID, item.sourceAppName, item.hash, item.byteSize, item.oversized, item.preview,
            item.width, item.height, Rows.filePathsJSON(item.filePaths), item.url, item.colorHex,
            item.inHistory, item.promised, item.hasThumbnail, item.linkTitle,
        ])
    }

    /// Fills in the payload of a promised item once the data is available.
    public func resolvePromise(_ id: UUID, representations: [ClipRepresentation], filePaths: [String], preview: String) async throws {
        let db = try pool()
        let relativePaths = try blobs.write(representations, for: id)
        try await db.write { db in
            try db.execute(sql: "DELETE FROM item_type WHERE item_id = ?", arguments: [Rows.key(id)])
            for (ordinal, representation) in representations.enumerated() {
                try db.execute(sql: """
                    INSERT INTO item_type(item_id, item_index, uti, blob_path, byte_size, ordinal)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [Rows.key(id), representation.itemIndex, representation.uti,
                                 relativePaths[ordinal], representation.data.count, ordinal])
            }
            try db.execute(sql: "UPDATE item SET promised = 0, file_paths = ?, preview = ?, byte_size = ? WHERE id = ?",
                           arguments: [Rows.filePathsJSON(filePaths), preview,
                                       representations.reduce(0) { $0 + $1.data.count }, Rows.key(id)])
        }
        if let item = try await self.item(id) {
            broadcaster.send(.updated(item))
        }
    }

    /// Adds a thumbnail generated after insertion (Quick Look thumbnails of copied files).
    public func setThumbnail(_ id: UUID, data: Data) async throws {
        try blobs.writeThumbnail(data, for: id)
        try await pool().write { db in
            try db.execute(sql: "UPDATE item SET has_thumbnail = 1 WHERE id = ?", arguments: [Rows.key(id)])
        }
        if let item = try await self.item(id) {
            broadcaster.send(.updated(item))
        }
    }

    /// Rename: a user-given title, or nil to show the kind again.
    public func setTitle(_ id: UUID, title: String?) async throws {
        try await setText(column: "title", of: id, to: title)
    }

    /// Stores the text recognized inside an image, so screenshots are searchable.
    public func setOCRText(_ id: UUID, text: String?) async throws {
        try await setText(column: "ocr_text", of: id, to: text)
    }

    /// Trims, stores nil for empty, and broadcasts the updated item. The column
    /// name is one of two literals above, never user input.
    private func setText(column: String, of id: UUID, to text: String?) async throws {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        try await pool().write { db in
            try db.execute(sql: "UPDATE item SET \(column) = ? WHERE id = ?",
                           arguments: [trimmed.flatMap { $0.isEmpty ? nil : $0 }, Rows.key(id)])
        }
        if let item = try await self.item(id) {
            broadcaster.send(.updated(item))
        }
    }

    /// Stores the result of an opt-in link preview fetch.
    public func setLinkPreview(_ id: UUID, title: String?, thumbnail: Data?) async throws {
        let db = try pool()
        if let thumbnail {
            try blobs.writeThumbnail(thumbnail, for: id)
        }
        try await db.write { db in
            try db.execute(sql: "UPDATE item SET link_title = ?, has_thumbnail = has_thumbnail OR ? WHERE id = ?",
                           arguments: [title, thumbnail != nil, Rows.key(id)])
        }
        if let item = try await self.item(id) {
            broadcaster.send(.updated(item))
        }
    }

    // MARK: Reading

    /// The Clipboard tab, most recently used first.
    public nonisolated func history(limit: Int = 200, offset: Int = 0) async throws -> [ClipItem] {
        try await pool().read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM item WHERE in_history = 1
                ORDER BY last_used_at DESC, id DESC LIMIT ? OFFSET ?
                """, arguments: [limit, offset]).map(Rows.item)
        }
    }

    public nonisolated func historyCount() async throws -> Int {
        try await pool().read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item WHERE in_history = 1") ?? 0
        }
    }

    /// Distinct source app names in history, most used first, for `app:` suggestions.
    public nonisolated func sourceAppNames(limit: Int = 50) async throws -> [String] {
        try await pool().read { db in
            try String.fetchAll(db, sql: """
                SELECT source_app_name FROM item
                WHERE source_app_name IS NOT NULL AND source_app_name != ''
                GROUP BY source_app_name ORDER BY COUNT(*) DESC, MAX(last_used_at) DESC LIMIT ?
                """, arguments: [limit])
        }
    }

    public nonisolated func item(_ id: UUID) async throws -> ClipItem? {
        try await pool().read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM item WHERE id = ?", arguments: [Rows.key(id)]).map(Rows.item)
        }
    }

    /// Loads and decrypts every stored pasteboard type, in the original order.
    public nonisolated func representations(for id: UUID) async throws -> [ClipRepresentation] {
        let rows = try await pool().read { db in
            try Row.fetchAll(db, sql: "SELECT item_index, uti, blob_path FROM item_type WHERE item_id = ? ORDER BY ordinal",
                             arguments: [Rows.key(id)])
                .map { row -> (index: Int, uti: String, path: String) in (row["item_index"], row["uti"], row["blob_path"]) }
        }
        return try rows.map { row in
            ClipRepresentation(itemIndex: row.index, uti: row.uti, data: try blobs.read(relativePath: row.path))
        }
    }

    /// The type identifiers of the first pasteboard item, synchronously, for drag providers.
    public nonisolated func storedTypes(for id: UUID) throws -> [String] {
        try pool().read { db in
            try String.fetchAll(db, sql: "SELECT uti FROM item_type WHERE item_id = ? AND item_index = 0 ORDER BY ordinal",
                                arguments: [Rows.key(id)])
        }
    }

    public nonisolated func thumbnail(for id: UUID) -> Data? {
        blobs.readThumbnail(for: id)
    }

    /// Moves a pasted item to the front.
    public func markUsed(_ id: UUID, at date: Date = Date()) async throws {
        try await pool().write { db in
            try db.execute(sql: "UPDATE item SET last_used_at = ?, in_history = 1 WHERE id = ?",
                           arguments: [Rows.millis(date), Rows.key(id)])
        }
        if let item = try await self.item(id) {
            broadcaster.send(.used(item))
        }
    }

    // MARK: Removing

    /// Removes items from the Clipboard tab. Pinned items keep their pinned copies;
    /// everything else is deleted together with its files.
    public func removeFromHistory(_ ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        let keys = ids.map(Rows.key)
        let deleted: [String] = try pool().write { db in
            let placeholders = databaseQuestionMarks(count: keys.count)
            try db.execute(sql: """
                UPDATE item SET in_history = 0
                WHERE id IN (\(placeholders)) AND id IN (SELECT item_id FROM pin)
                """, arguments: StatementArguments(keys))
            let unpinned = try String.fetchAll(db, sql: """
                SELECT id FROM item WHERE id IN (\(placeholders)) AND id NOT IN (SELECT item_id FROM pin)
                """, arguments: StatementArguments(keys))
            try Self.deleteRows(unpinned, db: db)
            return unpinned
        }
        deleted.forEach { blobs.removeFiles(for: Rows.uuid($0)) }
        broadcaster.send(.removed(Set(ids)))
    }

    private static func deleteRows(_ keys: [String], db: Database) throws {
        for chunk in stride(from: 0, to: keys.count, by: 500).map({ Array(keys[$0..<min($0 + 500, keys.count)]) }) {
            try db.execute(sql: "DELETE FROM item WHERE id IN (\(databaseQuestionMarks(count: chunk.count)))",
                           arguments: StatementArguments(chunk))
        }
    }

    /// Deletes items that are neither in history nor on any pinboard.
    private func deleteOrphans(db: Database) throws -> [String] {
        let orphans = try String.fetchAll(db, sql: """
            SELECT id FROM item WHERE in_history = 0 AND id NOT IN (SELECT item_id FROM pin)
            """)
        try Self.deleteRows(orphans, db: db)
        return orphans
    }

    // MARK: Retention

    public struct PurgeResult: Sendable, Equatable {
        public var deleted = 0
        public var keptBecausePinned = 0
    }

    /// Deletes unpinned items last used before the retention cutoff, then their
    /// files, then reclaims free pages. Pinned items leave the Clipboard tab but
    /// stay on their pinboards. "Forever" skips the age rule; the hard cap of
    /// 50,000 unpinned items applies regardless, oldest first.
    @discardableResult
    public func purge(retention: RetentionPeriod, now: Date = Date()) throws -> PurgeResult {
        let db = try pool()
        var result = PurgeResult()
        var deletedKeys: [String] = []
        if let cutoff = retention.cutoff(now: now) {
            let cutoffMillis = Rows.millis(cutoff)
            try db.write { db in
                let expiredPinned = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM item WHERE in_history = 1 AND last_used_at < ? AND id IN (SELECT item_id FROM pin)
                    """, arguments: [cutoffMillis]) ?? 0
                try db.execute(sql: """
                    UPDATE item SET in_history = 0 WHERE last_used_at < ? AND id IN (SELECT item_id FROM pin)
                    """, arguments: [cutoffMillis])
                let expired = try String.fetchAll(db, sql: """
                    SELECT id FROM item WHERE last_used_at < ? AND id NOT IN (SELECT item_id FROM pin)
                    """, arguments: [cutoffMillis])
                try Self.deleteRows(expired, db: db)
                deletedKeys = expired
                result.keptBecausePinned = expiredPinned
            }
        }
        deletedKeys.forEach { blobs.removeFiles(for: Rows.uuid($0)) }
        result.deleted = deletedKeys.count
        result.deleted += try enforceHardCap(notify: false)
        try db.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA incremental_vacuum")
        }
        if result.deleted > 0 || result.keptBecausePinned > 0 {
            broadcaster.send(.reloaded)
        }
        return result
    }

    @discardableResult
    private func enforceHardCap(notify: Bool = true) throws -> Int {
        let cap = hardCap
        let overflow: [String] = try pool().write { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item WHERE id NOT IN (SELECT item_id FROM pin)") ?? 0
            guard count > cap else { return [] }
            let keys = try String.fetchAll(db, sql: """
                SELECT id FROM item WHERE id NOT IN (SELECT item_id FROM pin)
                ORDER BY last_used_at ASC LIMIT ?
                """, arguments: [count - cap])
            try Self.deleteRows(keys, db: db)
            return keys
        }
        overflow.forEach { blobs.removeFiles(for: Rows.uuid($0)) }
        if notify, !overflow.isEmpty {
            broadcaster.send(.reloaded)
        }
        return overflow.count
    }

    /// "Remove images older than a month" in Settings. Pinned images are kept.
    @discardableResult
    public func removeImages(olderThan cutoff: Date) throws -> Int {
        let keys: [String] = try pool().write { db in
            let keys = try String.fetchAll(db, sql: """
                SELECT id FROM item WHERE kind = 'image' AND last_used_at < ? AND id NOT IN (SELECT item_id FROM pin)
                """, arguments: [Rows.millis(cutoff)])
            try Self.deleteRows(keys, db: db)
            return keys
        }
        keys.forEach { blobs.removeFiles(for: Rows.uuid($0)) }
        try pool().writeWithoutTransaction { db in try db.execute(sql: "PRAGMA incremental_vacuum") }
        if !keys.isEmpty { broadcaster.send(.reloaded) }
        return keys.count
    }

    /// "Erase history". Deletes every item, or every unpinned item when
    /// `keepPinned` is true, empties the blob folders, vacuums the database and
    /// rotates the encryption key so any copy of old ciphertext is useless.
    public func eraseHistory(keepPinned: Bool) throws {
        let db = try pool()
        if keepPinned {
            let deleted: [String] = try db.write { db in
                try db.execute(sql: "UPDATE item SET in_history = 0")
                return try deleteOrphans(db: db)
            }
            deleted.forEach { blobs.removeFiles(for: Rows.uuid($0)) }
            try blobs.rotateKey()
        } else {
            try db.write { db in
                try db.execute(sql: "DELETE FROM pin")
                try db.execute(sql: "DELETE FROM item")
            }
            try blobs.removeAll()
            try blobs.rotateKey()
        }
        try db.writeWithoutTransaction { db in
            try db.execute(sql: "INSERT INTO item_fts(item_fts) VALUES ('rebuild')")
            try db.execute(sql: "VACUUM")
        }
        broadcaster.send(.reloaded)
    }

    // MARK: Pinboards

    public nonisolated func pinboards() async throws -> [Pinboard] {
        try await pool().read { db in
            try Row.fetchAll(db, sql: """
                SELECT pinboard.*, (SELECT COUNT(*) FROM pin WHERE pin.pinboard_id = pinboard.id) AS item_count
                FROM pinboard ORDER BY ordinal, created_at
                """).map(Rows.pinboard)
        }
    }

    @discardableResult
    public func createPinboard(name: String, color: PinboardColor? = nil, icon: String? = nil) throws -> Pinboard {
        let board: Pinboard = try pool().write { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pinboard") ?? 0
            let ordinal = (try Int.fetchOne(db, sql: "SELECT MAX(ordinal) FROM pinboard") ?? -1) + 1
            let board = Pinboard(name: name, color: color ?? PinboardColor.next(after: count), icon: icon, ordinal: ordinal)
            try db.execute(sql: "INSERT INTO pinboard(id, name, color, icon, ordinal, created_at) VALUES (?, ?, ?, ?, ?, ?)",
                           arguments: [Rows.key(board.id), board.name, board.color.rawValue, board.icon,
                                       board.ordinal, Rows.millis(board.createdAt)])
            return board
        }
        broadcaster.send(.pinboardsChanged)
        return board
    }

    public func updatePinboard(_ id: UUID, name: String? = nil, color: PinboardColor? = nil, icon: String?? = nil) throws {
        try pool().write { db in
            if let name {
                try db.execute(sql: "UPDATE pinboard SET name = ? WHERE id = ?", arguments: [name, Rows.key(id)])
            }
            if let color {
                try db.execute(sql: "UPDATE pinboard SET color = ? WHERE id = ?", arguments: [color.rawValue, Rows.key(id)])
            }
            if let icon {
                try db.execute(sql: "UPDATE pinboard SET icon = ? WHERE id = ?", arguments: [icon, Rows.key(id)])
            }
        }
        broadcaster.send(.pinboardsChanged)
    }

    /// Deletes a pinboard. Items that were only on this board and are no longer in history go too.
    public func deletePinboard(_ id: UUID) throws {
        let orphans: [String] = try pool().write { db in
            try db.execute(sql: "DELETE FROM pinboard WHERE id = ?", arguments: [Rows.key(id)])
            return try deleteOrphans(db: db)
        }
        orphans.forEach { blobs.removeFiles(for: Rows.uuid($0)) }
        broadcaster.send(.pinboardsChanged)
        broadcaster.send(.pinsChanged)
    }

    /// Persists a new pinboard order (drag-reordering the chips).
    public func reorderPinboards(_ ids: [UUID]) throws {
        try pool().write { db in
            for (ordinal, id) in ids.enumerated() {
                try db.execute(sql: "UPDATE pinboard SET ordinal = ? WHERE id = ?", arguments: [ordinal, Rows.key(id)])
            }
        }
        broadcaster.send(.pinboardsChanged)
    }

    /// Items on a pinboard, in the board's order.
    public nonisolated func items(onPinboard id: UUID) async throws -> [ClipItem] {
        try await pool().read { db in
            try Row.fetchAll(db, sql: """
                SELECT item.* FROM pin JOIN item ON item.id = pin.item_id
                WHERE pin.pinboard_id = ? ORDER BY pin.ordinal, pin.pinned_at DESC
                """, arguments: [Rows.key(id)]).map(Rows.item)
        }
    }

    /// Pins an item. New pins go first; pinning an item already on the board is a no-op.
    public func pin(_ itemID: UUID, to pinboardID: UUID, at index: Int? = nil) throws {
        try pool().write { db in
            let exists = try Bool.fetchOne(db, sql: "SELECT 1 FROM pin WHERE pinboard_id = ? AND item_id = ?",
                                           arguments: [Rows.key(pinboardID), Rows.key(itemID)]) ?? false
            guard !exists else { return }
            let ordinal = (try Int.fetchOne(db, sql: "SELECT MIN(ordinal) FROM pin WHERE pinboard_id = ?",
                                            arguments: [Rows.key(pinboardID)]) ?? 1) - 1
            try db.execute(sql: "INSERT INTO pin(pinboard_id, item_id, ordinal, pinned_at) VALUES (?, ?, ?, ?)",
                           arguments: [Rows.key(pinboardID), Rows.key(itemID), ordinal, Rows.millis(Date())])
            if let index {
                var order = try String.fetchAll(db, sql: "SELECT item_id FROM pin WHERE pinboard_id = ? ORDER BY ordinal",
                                                arguments: [Rows.key(pinboardID)])
                order.removeAll { $0 == Rows.key(itemID) }
                order.insert(Rows.key(itemID), at: min(max(0, index), order.count))
                try Self.writePinOrder(order, pinboard: Rows.key(pinboardID), db: db)
            }
        }
        broadcaster.send(.pinsChanged)
        broadcaster.send(.pinboardsChanged)
    }

    /// Unpins an item. If it already left history and has no other pin, it is deleted.
    public func unpin(_ itemID: UUID, from pinboardID: UUID) throws {
        let orphans: [String] = try pool().write { db in
            try db.execute(sql: "DELETE FROM pin WHERE pinboard_id = ? AND item_id = ?",
                           arguments: [Rows.key(pinboardID), Rows.key(itemID)])
            return try deleteOrphans(db: db)
        }
        orphans.forEach { blobs.removeFiles(for: Rows.uuid($0)) }
        broadcaster.send(.pinsChanged)
        broadcaster.send(.pinboardsChanged)
    }

    /// Persists the order of cards on a pinboard after a drag.
    public func reorderPins(on pinboardID: UUID, itemIDs: [UUID]) throws {
        try pool().write { db in
            try Self.writePinOrder(itemIDs.map(Rows.key), pinboard: Rows.key(pinboardID), db: db)
        }
        broadcaster.send(.pinsChanged)
    }

    private static func writePinOrder(_ itemKeys: [String], pinboard: String, db: Database) throws {
        for (ordinal, key) in itemKeys.enumerated() {
            try db.execute(sql: "UPDATE pin SET ordinal = ? WHERE pinboard_id = ? AND item_id = ?",
                           arguments: [ordinal, pinboard, key])
        }
    }

    /// The names of the pinboards each item is on, for global search results.
    public nonisolated func pinboardNames(for itemIDs: [UUID]) async throws -> [UUID: [String]] {
        guard !itemIDs.isEmpty else { return [:] }
        let keys = itemIDs.map(Rows.key)
        return try await pool().read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT pin.item_id, pinboard.name FROM pin JOIN pinboard ON pinboard.id = pin.pinboard_id
                WHERE pin.item_id IN (\(databaseQuestionMarks(count: keys.count))) ORDER BY pinboard.ordinal
                """, arguments: StatementArguments(keys))
            var names: [UUID: [String]] = [:]
            for row in rows {
                names[Rows.uuid(row["item_id"]), default: []].append(row["name"])
            }
            return names
        }
    }

    // MARK: Search

    public enum Scope: Sendable, Equatable {
        case history
        case pinboard(UUID)
        case everywhere
    }

    /// Runs a parsed query. Substring matches come from the FTS5 trigram index
    /// (terms of three characters or more) or a LIKE scan (shorter terms), then
    /// are ranked by the fuzzy scorer with a recency tiebreak. When nothing
    /// matches as a substring, a subsequence scan runs as a fuzzy fallback.
    public nonisolated func search(_ query: SearchQuery, scope: Scope, limit: Int = 200, now: Date = Date()) async throws -> [ClipItem] {
        let pool = try pool()
        let (filterSQL, filterArguments) = Self.filterClause(for: query, scope: scope)

        var termSQL: [String] = []
        var termArguments: [DatabaseValue] = []
        for term in query.terms {
            if term.count >= 3 {
                termSQL.append("item.rowid IN (SELECT rowid FROM item_fts WHERE item_fts MATCH ?)")
                termArguments.append(("\"" + term.replacingOccurrences(of: "\"", with: "\"\"") + "\"").databaseValue)
            } else {
                let pattern = "%" + Self.escapeLike(term) + "%"
                termSQL.append("""
                    (item.preview LIKE ? ESCAPE '\\' OR item.source_app_name LIKE ? ESCAPE '\\'
                     OR item.url LIKE ? ESCAPE '\\' OR item.file_paths LIKE ? ESCAPE '\\'
                     OR item.title LIKE ? ESCAPE '\\' OR item.ocr_text LIKE ? ESCAPE '\\')
                    """)
                termArguments.append(contentsOf: Array(repeating: pattern.databaseValue, count: 6))
            }
        }

        let candidateLimit = limit * 2
        let order = Self.orderClause(for: scope)
        let conditions = (filterSQL.conditions + termSQL).joined(separator: " AND ")
        let sql = "SELECT item.* FROM item \(filterSQL.join) WHERE \(conditions) ORDER BY \(order) LIMIT \(candidateLimit)"
        let arguments = StatementArguments(filterArguments + termArguments)
        var candidates = try await pool.read { db in
            try Row.fetchAll(db, sql: sql, arguments: arguments).map(Rows.item)
        }

        let freeText = query.freeText
        if candidates.isEmpty, !freeText.isEmpty {
            // Fuzzy fallback: the query as a subsequence. `LIKE '%k%b%s%'` is exactly a
            // subsequence match, and SQLite runs it far faster than a scan in Swift.
            let letters = freeText.filter { !$0.isWhitespace }.map { Self.escapeLike(String($0)) }
            let pattern = ("%" + letters.joined(separator: "%") + "%").databaseValue
            let fuzzySQL = """
                SELECT item.* FROM item \(filterSQL.join)
                WHERE \(filterSQL.conditions.joined(separator: " AND "))
                AND (item.preview LIKE ? ESCAPE '\\' OR item.source_app_name LIKE ? ESCAPE '\\' OR item.url LIKE ? ESCAPE '\\'
                     OR item.title LIKE ? ESCAPE '\\' OR item.ocr_text LIKE ? ESCAPE '\\')
                ORDER BY \(order) LIMIT \(candidateLimit)
                """
            let fuzzyArguments = StatementArguments(filterArguments + [pattern, pattern, pattern, pattern, pattern])
            candidates = try await pool.read { db in
                try Row.fetchAll(db, sql: fuzzySQL, arguments: fuzzyArguments).map(Rows.item)
            }
        }

        guard !freeText.isEmpty else { return Array(candidates.prefix(limit)) }
        let ranked = candidates.map { item -> (ClipItem, Double) in
            let match = Self.bestScore(freeText, in: item) ?? 0.55
            let ageDays = max(0, now.timeIntervalSince(item.lastUsedAt) / 86_400)
            let recency = 1.0 / (1.0 + ageDays / 7.0)
            return (item, match * 0.75 + recency * 0.25)
        }
        return ranked.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    private static func bestScore(_ text: String, in item: ClipItem) -> Double? {
        let fields = [item.preview, item.sourceAppName ?? "", item.url ?? "", item.linkTitle ?? "", item.title ?? "", item.ocrText ?? ""]
            + item.filePaths.map { ($0 as NSString).lastPathComponent }
        return fields.compactMap { FuzzyScorer.score(text, in: $0) }.max()
    }

    private struct FilterSQL {
        var join = ""
        var conditions: [String] = []
    }

    private static func orderClause(for scope: Scope) -> String {
        if case .pinboard = scope { return "pin.ordinal, item.last_used_at DESC" }
        return "item.last_used_at DESC, item.id DESC"
    }

    private static func filterClause(for query: SearchQuery, scope: Scope) -> (FilterSQL, [DatabaseValue]) {
        var sql = FilterSQL()
        var arguments: [DatabaseValue] = []
        switch scope {
        case .history:
            sql.conditions.append("item.in_history = 1")
        case .pinboard(let id):
            sql.join = "JOIN pin ON pin.item_id = item.id AND pin.pinboard_id = ?"
            arguments.append(Rows.key(id).databaseValue)
        case .everywhere:
            sql.conditions.append("(item.in_history = 1 OR item.id IN (SELECT item_id FROM pin))")
        }
        if !query.kinds.isEmpty {
            sql.conditions.append("item.kind IN (\(databaseQuestionMarks(count: query.kinds.count)))")
            arguments.append(contentsOf: query.kinds.map(\.rawValue).sorted().map(\.databaseValue))
        }
        if !query.apps.isEmpty {
            let clauses = query.apps.map { _ in "(item.source_app_name LIKE ? ESCAPE '\\' OR item.source_bundle_id LIKE ? ESCAPE '\\')" }
            sql.conditions.append("(" + clauses.joined(separator: " OR ") + ")")
            for app in query.apps {
                let pattern = ("%" + escapeLike(app) + "%").databaseValue
                arguments.append(contentsOf: [pattern, pattern])
            }
        }
        if let after = query.after {
            sql.conditions.append("item.last_used_at >= ?")
            arguments.append(Rows.millis(after).databaseValue)
        }
        if let before = query.before {
            sql.conditions.append("item.last_used_at < ?")
            arguments.append(Rows.millis(before).databaseValue)
        }
        switch query.pinned {
        case .anyBoard:
            sql.conditions.append("item.id IN (SELECT item_id FROM pin)")
        case .board(let name):
            sql.conditions.append("item.id IN (SELECT pin.item_id FROM pin JOIN pinboard ON pinboard.id = pin.pinboard_id WHERE pinboard.name LIKE ? ESCAPE '\\')")
            arguments.append(escapeLike(name).databaseValue)
        case nil:
            break
        }
        if sql.conditions.isEmpty { sql.conditions.append("1") }
        return (sql, arguments)
    }

    private static func escapeLike(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    // MARK: Statistics

    public struct Statistics: Sendable, Equatable {
        public var historyCount: Int
        public var pinnedCount: Int
        public var databaseBytes: Int64
        public var blobBytes: Int64
        public var imageCount: Int
        public var oldImageCount: Int

        public init(historyCount: Int, pinnedCount: Int, databaseBytes: Int64, blobBytes: Int64, imageCount: Int, oldImageCount: Int) {
            self.historyCount = historyCount
            self.pinnedCount = pinnedCount
            self.databaseBytes = databaseBytes
            self.blobBytes = blobBytes
            self.imageCount = imageCount
            self.oldImageCount = oldImageCount
        }
    }

    public nonisolated func statistics(now: Date = Date()) async throws -> Statistics {
        let monthAgo = Rows.millis(now.addingTimeInterval(-30 * 86_400))
        let counts = try await pool().read { db -> (Int, Int, Int, Int) in
            let history = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item WHERE in_history = 1") ?? 0
            let pinned = try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT item_id) FROM pin") ?? 0
            let images = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item WHERE kind = 'image'") ?? 0
            let oldImages = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM item WHERE kind = 'image' AND last_used_at < ? AND id NOT IN (SELECT item_id FROM pin)
                """, arguments: [monthAgo]) ?? 0
            return (history, pinned, images, oldImages)
        }
        let databaseBytes = ["", "-wal", "-shm"].reduce(Int64(0)) { total, suffix in
            let path = paths.database.path + suffix
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            return total + ((attributes?[.size] as? Int64) ?? 0)
        }
        return Statistics(historyCount: counts.0, pinnedCount: counts.1, databaseBytes: databaseBytes,
                          blobBytes: blobs.diskUsage(), imageCount: counts.2, oldImageCount: counts.3)
    }

    /// A compact, consistent copy of the database (`VACUUM INTO`), for exports.
    public nonisolated func copyDatabase(to url: URL) async throws {
        try await pool().writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM INTO ?", arguments: [url.path])
        }
    }

    /// Direct read access for the exporter and tests.
    public nonisolated func read<T: Sendable>(_ block: @Sendable @escaping (Database) throws -> T) async throws -> T {
        try await pool().read(block)
    }
}

/// Opens the database on first use. Opening is cheap but runs migrations,
/// which must not delay the menu-bar icon at launch.
private final class LazyPool: @unchecked Sendable {
    private let lock = NSLock()
    private var pool: DatabasePool?

    func get(paths: AppPaths) throws -> DatabasePool {
        lock.lock()
        defer { lock.unlock() }
        if let pool { return pool }
        try paths.prepare()
        var configuration = Configuration()
        configuration.label = "Shelf"
        configuration.prepareDatabase { db in
            // Must precede table creation to take effect on a new file. Readers skip it.
            if !db.configuration.readonly {
                try db.execute(sql: "PRAGMA auto_vacuum = INCREMENTAL")
            }
        }
        let pool = try DatabasePool(path: paths.database.path, configuration: configuration)
        try Schema.migrate(pool)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.database.path)
        self.pool = pool
        return pool
    }
}
