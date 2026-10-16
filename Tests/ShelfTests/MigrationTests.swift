import GRDB
@testable import ShelfCore
import XCTest

final class MigrationTests: XCTestCase {
    func testMigratesFromV1Schema() async throws {
        let paths = AppPaths.temporary()
        defer { FileManager.default.removeIfPresent(paths.root) }
        try paths.prepare()

        // A database as v1.0 shipped it, with one item and one pinboard.
        let queue = try DatabaseQueue(path: paths.database.path)
        try Schema.migrator.migrate(queue, upTo: "v1_initial")
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO item(id, created_at, last_used_at, kind, hash, byte_size, preview)
                VALUES ('0190d1e0-0000-7000-8000-000000000001', 1, 1, 'text', x'00', 5, 'hello')
                """)
            try db.execute(sql: "INSERT INTO pinboard(id, name, color, ordinal, created_at) VALUES ('b', 'Old', 'blue', 0, 1)")
        }
        try queue.close()

        let env = Preferences(defaults: UserDefaults(suiteName: "migration-\(UUID())")!)
        let store = Store(paths: paths, keyProvider: InMemoryBlobKeyProvider(), preferences: env)
        try await store.open()
        let items = try await store.history()
        XCTAssertEqual(items.first?.preview, "hello")
        XCTAssertNil(items.first?.linkTitle)
        let boards = try await store.pinboards()
        XCTAssertEqual(boards.first?.name, "Old")
        XCTAssertNil(boards.first?.icon)

        let version = try await store.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'schema_version'")
        }
        XCTAssertEqual(version, "\(Schema.currentVersion)")
        let installID = try await store.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'install_id'")
        }
        XCTAssertNotNil(installID)
        // FTS index was migrated along.
        let found = try await store.search(SearchQuery.parse("hello"), scope: .history)
        XCTAssertEqual(found.count, 1)
    }

    func testRefusesNewerSchema() async throws {
        let paths = AppPaths.temporary()
        defer { FileManager.default.removeIfPresent(paths.root) }
        try paths.prepare()
        let queue = try DatabaseQueue(path: paths.database.path)
        var future = Schema.migrator
        future.registerMigration("v99_from_the_future") { db in
            try db.execute(sql: "CREATE TABLE future(x)")
        }
        try future.migrate(queue)
        try queue.close()

        let store = Store(paths: paths, keyProvider: InMemoryBlobKeyProvider(),
                          preferences: Preferences(defaults: UserDefaults(suiteName: "future-\(UUID())")!))
        do {
            try await store.open()
            XCTFail("a newer schema must be refused")
        } catch let error as SchemaError {
            XCTAssertEqual(error, .newerThanApp(["v99_from_the_future"]))
        }
    }
}
