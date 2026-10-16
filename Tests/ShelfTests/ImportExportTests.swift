import GRDB
@testable import ShelfCapture
@testable import ShelfCore
import XCTest

final class ImportExportTests: XCTestCase {
    func testExportThenImportRoundTrip() async throws {
        let source = TestEnvironment()
        let target = TestEnvironment()
        defer { source.cleanUp() }
        defer { target.cleanUp() }
        try await source.store.open()
        try await target.store.open()

        let text = try await source.store.insert(Make.text("exported text"))
        let image = try await source.store.insert(Make.image())
        let board = try await source.store.createPinboard(name: "Snippets", color: .orange, icon: "star")
        try await source.store.pin(text.id, to: board.id)

        let zip = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID()).zip")
        defer { removeIfPresent(zip) }
        let manifest = try await HistoryArchive.export(store: source.store, to: zip, appVersion: "1.0.0")
        XCTAssertEqual(manifest.itemCount, 2)
        XCTAssertFalse(manifest.encrypted)

        let result = try await HistoryArchive.importArchive(from: zip, into: target.store)
        XCTAssertEqual(result.imported, 2)
        XCTAssertEqual(result.pinboards, 1)
        let history = try await target.store.history()
        XCTAssertEqual(Set(history.map(\.hash)), Set([text.hash, image.hash]))
        let importedText = try XCTUnwrap(history.first { $0.hash == text.hash })
        let data = try await target.store.representations(for: importedText.id).first?.data
        XCTAssertEqual(data, Data("exported text".utf8))
        let boards = try await target.store.pinboards()
        XCTAssertEqual(boards.first?.name, "Snippets")
        XCTAssertEqual(boards.first?.itemCount, 1)

        // Importing twice does not duplicate.
        let again = try await HistoryArchive.importArchive(from: zip, into: target.store)
        XCTAssertEqual(again.duplicates, 2)
        let count = try await target.store.historyCount()
        XCTAssertEqual(count, 2)
    }

    func testArchivePathsCannotEscapeTheArchive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("archive-\(UUID())/blobs")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertNoThrow(try HistoryArchive.contained("abc/0-0-public_utf8-plain-text.bin", in: root))
        XCTAssertThrowsError(try HistoryArchive.contained("../../../../.ssh/id_ed25519", in: root))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: URL(fileURLWithPath: "/etc"))
        XCTAssertThrowsError(try HistoryArchive.contained("link/hosts", in: root), "a symlink out of the archive")
    }

    func testImportDoesNotReturnPinnedOnlyItemsToHistory() async throws {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        try await env.store.open()
        let item = try await env.store.insert(Make.text("pinned only"))
        let board = try await env.store.createPinboard(name: "B")
        try await env.store.pin(item.id, to: board.id)
        try await env.store.removeFromHistory([item.id])
        _ = try await env.store.insert(Make.text("pinned only"), returnToHistory: false)
        let history = try await env.store.history()
        XCTAssertTrue(history.isEmpty)
    }

    func testRejectsNonArchives() async throws {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        try await env.store.open()
        let bogus = FileManager.default.temporaryDirectory.appendingPathComponent("bogus-\(UUID()).zip")
        try Data("not a zip".utf8).write(to: bogus)
        do {
            _ = try await HistoryArchive.importArchive(from: bogus, into: env.store)
            XCTFail("expected an error")
        } catch {}
    }

    /// A database shaped like Maccy 2.x's SwiftData store.
    func testMaccyImport() async throws {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        try await env.store.open()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("maccy-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Storage.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try await queue.write { db in
            try db.execute(sql: """
                CREATE TABLE ZHISTORYITEM (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZNUMBEROFCOPIES INTEGER,
                    ZFIRSTCOPIEDAT TIMESTAMP, ZLASTCOPIEDAT TIMESTAMP, ZAPPLICATION VARCHAR, ZPIN VARCHAR, ZTITLE VARCHAR);
                CREATE TABLE ZHISTORYITEMCONTENT (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZITEM INTEGER, ZTYPE VARCHAR, ZVALUE BLOB);
                INSERT INTO ZHISTORYITEM VALUES (1, 1, 1, 1, 800000000, 800000100, 'com.apple.Safari', NULL, 'hello');
                INSERT INTO ZHISTORYITEM VALUES (2, 1, 1, 3, 800000200, 800000300, 'com.apple.Notes', 'b', 'pinned');
                INSERT INTO ZHISTORYITEM VALUES (3, 1, 1, 1, 800000400, 800000500, 'com.apple.Notes', NULL, 'secret');
                """)
            try db.execute(sql: "INSERT INTO ZHISTORYITEMCONTENT VALUES (1, 2, 1, 1, 'public.utf8-plain-text', ?)", arguments: [Data("hello maccy".utf8)])
            try db.execute(sql: "INSERT INTO ZHISTORYITEMCONTENT VALUES (2, 2, 1, 2, 'public.utf8-plain-text', ?)", arguments: [Data("pinned text".utf8)])
            try db.execute(sql: "INSERT INTO ZHISTORYITEMCONTENT VALUES (3, 2, 1, 3, 'public.utf8-plain-text', ?)", arguments: [Data("pw".utf8)])
            try db.execute(sql: "INSERT INTO ZHISTORYITEMCONTENT VALUES (4, 2, 1, 3, 'org.nspasteboard.ConcealedType', ?)", arguments: [Data()])
        }
        try queue.close()

        XCTAssertEqual(MaccyDatabase.itemCount(at: url), 3)
        let result = try await MaccyImporter.importHistory(from: url, into: env.store, preferences: env.preferences)
        XCTAssertEqual(result, MaccyImporter.Result(imported: 2, skipped: 1, pinned: 1))
        let history = try await env.store.history()
        XCTAssertEqual(history.map(\.preview), ["pinned text", "hello maccy"])
        XCTAssertEqual(history.last?.sourceBundleID, "com.apple.Safari")
        XCTAssertEqual(history.last?.createdAt, Date(timeIntervalSinceReferenceDate: 800_000_000))
        let boards = try await env.store.pinboards()
        XCTAssertEqual(boards.map(\.name), ["Maccy"])
    }

    /// A database shaped like Paste 5's Core Data store, with an inline plist, an
    /// inline LZFSE-compressed plist and an external payload file.
    func testPasteImport() async throws {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        try await env.store.open()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("paste-\(UUID())")
        let url = folder.appendingPathComponent("db.sqlite")
        let external = PasteDatabase.externalDataDirectory(for: url)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        defer { removeIfPresent(folder) }

        func payload(_ items: [[(String, Data)]]) throws -> Data {
            let plist = items.map { item in
                ["types": item.map(\.0), "dataByType": Dictionary(item, uniquingKeysWith: { first, _ in first })] as [String: Any]
            }
            return try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        }
        func inline(_ data: Data) -> Data { Data([1]) + data }
        func compressed(_ data: Data) throws -> Data { try (data as NSData).compressed(using: .lzfse) as Data }
        let png = Data((0..<64).map { UInt8($0) })
        let imageName = UUID().uuidString
        try compressed(payload([[("public.png", png)]])).write(to: external.appendingPathComponent(imageName))
        let imageReference = Data([2]) + Data(imageName.utf8) + Data([0])
        let link = "https://example.com/paste"
        let rows: [(Int, Data)] = [
            (1, inline(try payload([[("public.utf8-plain-text", Data("hello paste".utf8)), ("public.text", Data("hello paste".utf8))]]))),
            (2, inline(try payload([[("public.utf8-plain-text", Data("pinned text".utf8))]]))),
            (3, imageReference),
            (4, inline(try compressed(try payload([[("public.url", Data(link.utf8)), ("public.utf8-plain-text", Data(link.utf8))]])))),
            (5, inline(try payload([[("public.utf8-plain-text", Data("pw".utf8)), ("org.nspasteboard.ConcealedType", Data())]]))),
        ]

        let queue = try DatabaseQueue(path: url.path)
        try await queue.write { db in
            try db.execute(sql: """
                CREATE TABLE ZAPPLICATIONENTITY (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZRAWCOLOR INTEGER,
                    ZCREATEDAT TIMESTAMP, ZUPDATEDAT TIMESTAMP, ZBUNDLEIDENTIFIER VARCHAR, ZNAME VARCHAR, ZRAWICON BLOB);
                CREATE TABLE ZLISTENTITY (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZRAWTYPE INTEGER, ZMETADATA INTEGER,
                    ZCREATEDAT TIMESTAMP, ZUPDATEDAT TIMESTAMP, ZIDENTIFIER VARCHAR, ZNAME VARCHAR, ZRAWATTRIBUTES BLOB, ZRAWSHARERECORD BLOB);
                CREATE TABLE ZITEMDATAENTITY (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZITEM INTEGER, ZRAWPASTEBOARDITEMS BLOB);
                CREATE TABLE ZITEMENTITY (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZDISPLAYORDERINPINBOARD INTEGER,
                    ZRAWTYPE INTEGER, ZDATA INTEGER, ZDEVICE INTEGER, ZLIST INTEGER, ZSOURCEAPPLICATION INTEGER, ZCREATEDAT TIMESTAMP,
                    ZTIMESTAMP TIMESTAMP, ZUPDATEDAT TIMESTAMP, ZCHECKSUM VARCHAR, ZIDENTIFIER VARCHAR, ZTITLE VARCHAR, ZRAWPREVIEW BLOB);
                INSERT INTO ZAPPLICATIONENTITY VALUES (1, 1, 1, 0, 800000000, 800000000, 'com.apple.Safari', 'Safari', NULL);
                INSERT INTO ZAPPLICATIONENTITY VALUES (2, 1, 1, 0, 800000000, 800000000, 'com.apple.Notes', 'Notes', NULL);
                INSERT INTO ZLISTENTITY VALUES (1, 5, 1, 1, NULL, 800000000, 800000000, 'clipboard', 'Clipboard', NULL, NULL);
                INSERT INTO ZLISTENTITY VALUES (2, 5, 1, 2, NULL, 800000000, 800000000, 'snippets', 'Snippets', NULL, NULL);
                INSERT INTO ZITEMENTITY VALUES (1, 4, 1, 0, 5, 1, NULL, NULL, 1, 800000000, 800000100, 800000100, 'a', 'i1', NULL, NULL);
                INSERT INTO ZITEMENTITY VALUES (2, 4, 1, 0, 5, 2, NULL, 2, 2, 800000200, 800000300, 800000300, 'b', 'i2', 'Custom title', NULL);
                INSERT INTO ZITEMENTITY VALUES (3, 4, 1, 0, 1, 3, NULL, NULL, 2, 800000400, 800000500, 800000500, 'c', 'i3', NULL, NULL);
                INSERT INTO ZITEMENTITY VALUES (4, 4, 1, 0, 4, 4, NULL, NULL, 1, 800000600, 800000700, 800000700, 'd', 'i4', NULL, NULL);
                INSERT INTO ZITEMENTITY VALUES (5, 4, 1, 0, 5, 5, NULL, NULL, 2, 800000800, 800000900, 800000900, 'e', 'i5', NULL, NULL);
                """)
            for (item, data) in rows {
                try db.execute(sql: "INSERT INTO ZITEMDATAENTITY VALUES (?, 3, 1, ?, ?)", arguments: [item, item, data])
            }
        }
        try queue.close()

        XCTAssertEqual(PasteDatabase.itemCount(at: url), 5)
        let result = try await PasteImporter.importHistory(from: url, into: env.store, preferences: env.preferences)
        XCTAssertEqual(result, PasteImporter.Result(imported: 4, skipped: 1, pinned: 1))
        let history = try await env.store.history()
        XCTAssertEqual(history.map(\.kind), [.link, .image, .text, .text])
        XCTAssertEqual(history.map(\.preview), ["https://example.com/paste", "", "pinned text", "hello paste"])
        XCTAssertEqual(history.map(\.title), [nil, nil, "Custom title", nil], "Paste's item titles come along")
        XCTAssertEqual(history.first?.url, "https://example.com/paste")
        XCTAssertEqual(history.last?.sourceBundleID, "com.apple.Safari")
        XCTAssertEqual(history.last?.createdAt, Date(timeIntervalSinceReferenceDate: 800_000_000))
        let image = try XCTUnwrap(history.first { $0.kind == .image })
        let imageData = try await env.store.representations(for: image.id).first { $0.uti == "public.png" }?.data
        XCTAssertEqual(imageData, png)
        let boards = try await env.store.pinboards()
        XCTAssertEqual(boards.map(\.name), ["Snippets"])
        XCTAssertEqual(boards.first?.itemCount, 1)
    }

    func testLinkPreviewFetchRules() {
        XCTAssertTrue(LinkPreviewer.isFetchable(URL(string: "https://www.apple.com/macos")!))
        XCTAssertFalse(LinkPreviewer.isFetchable(URL(string: "http://localhost:3000")!))
        XCTAssertFalse(LinkPreviewer.isFetchable(URL(string: "http://192.168.1.10/admin")!))
        XCTAssertFalse(LinkPreviewer.isFetchable(URL(string: "http://10.0.0.1")!))
        XCTAssertFalse(LinkPreviewer.isFetchable(URL(string: "http://172.20.1.1")!))
        XCTAssertFalse(LinkPreviewer.isFetchable(URL(string: "http://printer.local")!))
        XCTAssertFalse(LinkPreviewer.isFetchable(URL(string: "ftp://example.com/file")!))
        XCTAssertFalse(LinkPreviewer.isFetchable(URL(string: "slack://channel")!))
        for alias in ["http://127.1/", "http://0177.0.0.1/", "http://0x7f.0.0.1/", "http://localhost./", "http://2130706433/"] {
            XCTAssertFalse(LinkPreviewer.isFetchable(URL(string: alias)!), alias)
        }
    }

    func testNamesThatResolveToPrivateAddressesAreRefused() async {
        let localhost = await LinkPreviewer.resolvesToPublicAddresses("localhost")
        XCTAssertFalse(localhost)
    }
}
