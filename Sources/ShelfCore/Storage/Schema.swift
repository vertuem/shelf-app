import Foundation
import GRDB

/// Forward-only migrations. Never edit a shipped migration; add `vN_…` instead.
///
/// The schema version is mirrored into `meta.schema_version`. A database
/// written by a newer Shelf is refused with `SchemaError.newerThanApp`, and
/// the app offers to back it up and start fresh.
public enum Schema {
    /// Bump together with a new migration below.
    public static let currentVersion = 4

    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_initial") { db in
            try db.execute(sql: """
                CREATE TABLE item (
                    id TEXT PRIMARY KEY NOT NULL,
                    created_at INTEGER NOT NULL,
                    last_used_at INTEGER NOT NULL,
                    kind TEXT NOT NULL,
                    source_bundle_id TEXT,
                    source_app_name TEXT,
                    hash BLOB NOT NULL,
                    byte_size INTEGER NOT NULL,
                    oversized INTEGER NOT NULL DEFAULT 0,
                    preview TEXT NOT NULL DEFAULT '',
                    width INTEGER,
                    height INTEGER,
                    file_paths TEXT,
                    url TEXT,
                    color_hex TEXT,
                    in_history INTEGER NOT NULL DEFAULT 1,
                    promised INTEGER NOT NULL DEFAULT 0,
                    has_thumbnail INTEGER NOT NULL DEFAULT 0
                );

                CREATE TABLE item_type (
                    item_id TEXT NOT NULL REFERENCES item(id) ON DELETE CASCADE,
                    item_index INTEGER NOT NULL DEFAULT 0,
                    uti TEXT NOT NULL,
                    blob_path TEXT NOT NULL,
                    byte_size INTEGER NOT NULL,
                    ordinal INTEGER NOT NULL,
                    PRIMARY KEY (item_id, ordinal)
                );

                CREATE TABLE pinboard (
                    id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL,
                    color TEXT NOT NULL,
                    ordinal INTEGER NOT NULL,
                    created_at INTEGER NOT NULL
                );

                CREATE TABLE pin (
                    pinboard_id TEXT NOT NULL REFERENCES pinboard(id) ON DELETE CASCADE,
                    item_id TEXT NOT NULL REFERENCES item(id) ON DELETE CASCADE,
                    ordinal INTEGER NOT NULL,
                    pinned_at INTEGER NOT NULL,
                    PRIMARY KEY (pinboard_id, item_id)
                );

                CREATE TABLE meta (
                    key TEXT PRIMARY KEY NOT NULL,
                    value TEXT
                );

                CREATE INDEX item_created_at ON item(created_at DESC);
                CREATE INDEX item_last_used_at ON item(in_history, last_used_at DESC);
                CREATE INDEX item_hash ON item(hash);
                CREATE INDEX item_kind_created_at ON item(kind, created_at DESC);
                CREATE INDEX item_source_created_at ON item(source_bundle_id, created_at DESC);
                CREATE INDEX pin_item_id ON pin(item_id);

                -- External-content FTS5 index over the searchable metadata. The trigram
                -- tokenizer turns every phrase query into a case-insensitive substring match.
                CREATE VIRTUAL TABLE item_fts USING fts5(
                    preview, source_app_name, url, file_paths,
                    content='item', content_rowid='rowid', tokenize='trigram'
                );
                CREATE TRIGGER item_fts_ai AFTER INSERT ON item BEGIN
                    INSERT INTO item_fts(rowid, preview, source_app_name, url, file_paths)
                    VALUES (new.rowid, new.preview, new.source_app_name, new.url, new.file_paths);
                END;
                CREATE TRIGGER item_fts_ad AFTER DELETE ON item BEGIN
                    INSERT INTO item_fts(item_fts, rowid, preview, source_app_name, url, file_paths)
                    VALUES ('delete', old.rowid, old.preview, old.source_app_name, old.url, old.file_paths);
                END;
                CREATE TRIGGER item_fts_au AFTER UPDATE OF preview, source_app_name, url, file_paths ON item BEGIN
                    INSERT INTO item_fts(item_fts, rowid, preview, source_app_name, url, file_paths)
                    VALUES ('delete', old.rowid, old.preview, old.source_app_name, old.url, old.file_paths);
                    INSERT INTO item_fts(rowid, preview, source_app_name, url, file_paths)
                    VALUES (new.rowid, new.preview, new.source_app_name, new.url, new.file_paths);
                END;
                """)
            try db.execute(sql: "INSERT INTO meta(key, value) VALUES ('install_id', ?)", arguments: [UUID().uuidString])
        }

        // v1.1: per-pinboard icon.
        migrator.registerMigration("v2_pinboard_icon") { db in
            try db.execute(sql: "ALTER TABLE pinboard ADD COLUMN icon TEXT")
        }

        // v1.1: opt-in link previews store a title next to the URL.
        migrator.registerMigration("v3_link_title") { db in
            try db.execute(sql: "ALTER TABLE item ADD COLUMN link_title TEXT")
        }

        // v1.2: a user-given title (Rename, Paste import) and the text recognized
        // inside images, both searchable. An external-content FTS5 table cannot
        // gain columns, so the index and its triggers are recreated and rebuilt.
        migrator.registerMigration("v4_title_and_ocr") { db in
            try db.execute(sql: """
                ALTER TABLE item ADD COLUMN title TEXT;
                ALTER TABLE item ADD COLUMN ocr_text TEXT;
                DROP TRIGGER item_fts_ai;
                DROP TRIGGER item_fts_ad;
                DROP TRIGGER item_fts_au;
                DROP TABLE item_fts;
                CREATE VIRTUAL TABLE item_fts USING fts5(
                    preview, source_app_name, url, file_paths, title, ocr_text,
                    content='item', content_rowid='rowid', tokenize='trigram'
                );
                CREATE TRIGGER item_fts_ai AFTER INSERT ON item BEGIN
                    INSERT INTO item_fts(rowid, preview, source_app_name, url, file_paths, title, ocr_text)
                    VALUES (new.rowid, new.preview, new.source_app_name, new.url, new.file_paths, new.title, new.ocr_text);
                END;
                CREATE TRIGGER item_fts_ad AFTER DELETE ON item BEGIN
                    INSERT INTO item_fts(item_fts, rowid, preview, source_app_name, url, file_paths, title, ocr_text)
                    VALUES ('delete', old.rowid, old.preview, old.source_app_name, old.url, old.file_paths, old.title, old.ocr_text);
                END;
                CREATE TRIGGER item_fts_au AFTER UPDATE OF preview, source_app_name, url, file_paths, title, ocr_text ON item BEGIN
                    INSERT INTO item_fts(item_fts, rowid, preview, source_app_name, url, file_paths, title, ocr_text)
                    VALUES ('delete', old.rowid, old.preview, old.source_app_name, old.url, old.file_paths, old.title, old.ocr_text);
                    INSERT INTO item_fts(rowid, preview, source_app_name, url, file_paths, title, ocr_text)
                    VALUES (new.rowid, new.preview, new.source_app_name, new.url, new.file_paths, new.title, new.ocr_text);
                END;
                INSERT INTO item_fts(item_fts) VALUES ('rebuild');
                """)
        }

        return migrator
    }

    /// Applies pending migrations, refusing databases from a newer app.
    static func migrate(_ writer: some DatabaseWriter) throws {
        let migrator = Self.migrator
        let known = Set(migrator.migrations)
        let applied = try writer.read { db in try migrator.appliedIdentifiers(db) }
        let unknown = applied.subtracting(known)
        guard unknown.isEmpty else {
            throw SchemaError.newerThanApp(unknown.sorted())
        }
        try migrator.migrate(writer)
        try writer.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO meta(key, value) VALUES ('schema_version', ?)",
                           arguments: ["\(currentVersion)"])
        }
    }
}

public enum SchemaError: Error, Equatable {
    /// The database was written by a newer version of Shelf. Downgrades are unsupported.
    case newerThanApp([String])
}
