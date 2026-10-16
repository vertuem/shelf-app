import GRDB
@testable import ShelfCore
import XCTest

final class StoreTests: XCTestCase {
    var env: TestEnvironment!

    override func setUp() async throws {
        env = TestEnvironment()
        try await env.store.open()
    }

    override func tearDown() async throws {
        env.cleanUp()
    }

    func testInsertAndReadBack() async throws {
        let stored = try await env.store.insert(Make.text("hello world"))
        let history = try await env.store.history()
        XCTAssertEqual(history.map(\.id), [stored.id])
        XCTAssertEqual(history.first?.preview, "hello world")
        XCTAssertEqual(history.first?.sourceAppName, "Notes")

        let representations = try await env.store.representations(for: stored.id)
        XCTAssertEqual(representations.count, 1)
        XCTAssertEqual(String(data: representations[0].data, encoding: .utf8), "hello world")
    }

    func testDuplicateHashMovesExistingItemToFront() async throws {
        let first = try await env.store.insert(Make.text("one", at: Date(timeIntervalSinceNow: -60)))
        _ = try await env.store.insert(Make.text("two", at: Date(timeIntervalSinceNow: -30)))
        let again = try await env.store.insert(Make.text("one"))
        XCTAssertEqual(again.id, first.id)
        let history = try await env.store.history()
        XCTAssertEqual(history.map(\.preview), ["one", "two"])
        let count = try await env.store.historyCount()
        XCTAssertEqual(count, 2)
    }

    func testBlobsAreSealedWhenEncryptionIsOn() async throws {
        let stored = try await env.store.insert(Make.text("secret sauce"))
        let directory = env.paths.blobDirectory(for: stored.id)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let raw = try Data(contentsOf: files[0])
        XCTAssertTrue(BlobEnvelope.isSealed(raw))
        XCTAssertNil(raw.range(of: Data("secret sauce".utf8)))
    }

    func testBlobsArePlainWhenEncryptionIsOff() async throws {
        env.defaults.set(false, forKey: PrefKey.encryptAtRest)
        let stored = try await env.store.insert(Make.text("plain sauce"))
        let files = try FileManager.default.contentsOfDirectory(at: env.paths.blobDirectory(for: stored.id), includingPropertiesForKeys: nil)
        let raw = try Data(contentsOf: files[0])
        XCTAssertFalse(BlobEnvelope.isSealed(raw))
        // Turning encryption back on must not break reading old plain blobs.
        env.defaults.set(true, forKey: PrefKey.encryptAtRest)
        let representations = try await env.store.representations(for: stored.id)
        XCTAssertEqual(representations.first?.data, Data("plain sauce".utf8))
    }

    func testDataDirectoryIsOwnerOnly() async throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: env.paths.root.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    // MARK: Search

    func testSubstringSearchIsCaseInsensitive() async throws {
        _ = try await env.store.insert(Make.text("The Quick Brown Fox"))
        _ = try await env.store.insert(Make.text("lazy dog"))
        let results = try await env.store.search(SearchQuery.parse("quick"), scope: .history)
        XCTAssertEqual(results.map(\.preview), ["The Quick Brown Fox"])
        let middle = try await env.store.search(SearchQuery.parse("rown fo"), scope: .history)
        XCTAssertEqual(middle.map(\.preview), ["The Quick Brown Fox"])
    }

    func testShortTermsUseLikeScan() async throws {
        _ = try await env.store.insert(Make.text("go fmt"))
        _ = try await env.store.insert(Make.text("nothing here"))
        let results = try await env.store.search(SearchQuery.parse("go"), scope: .history)
        XCTAssertEqual(results.map(\.preview), ["go fmt"])
    }

    func testSearchMatchesSourceAppName() async throws {
        _ = try await env.store.insert(Make.text("alpha", app: "Safari", bundleID: "com.apple.Safari"))
        _ = try await env.store.insert(Make.text("beta"))
        let results = try await env.store.search(SearchQuery.parse("safari"), scope: .history)
        XCTAssertEqual(results.map(\.preview), ["alpha"])
    }

    func testFiltersCombine() async throws {
        let old = Date(timeIntervalSinceNow: -10 * 86_400)
        _ = try await env.store.insert(Make.text("old text", at: old))
        _ = try await env.store.insert(Make.text("new text", app: "Safari", bundleID: "com.apple.Safari"))
        _ = try await env.store.insert(Make.image())

        let images = try await env.store.search(SearchQuery.parse("type:image"), scope: .history)
        XCTAssertEqual(images.map(\.kind), [.image])

        let safari = try await env.store.search(SearchQuery.parse("app:safari text"), scope: .history)
        XCTAssertEqual(safari.map(\.preview), ["new text"])

        let recent = try await env.store.search(SearchQuery.parse("after:3d text"), scope: .history)
        XCTAssertEqual(recent.map(\.preview), ["new text"])

        let older = try await env.store.search(SearchQuery.parse("before:3d"), scope: .history)
        XCTAssertEqual(older.map(\.preview), ["old text"])
    }

    func testQuotedPhraseIsOneTerm() async throws {
        _ = try await env.store.insert(Make.text("red apple green pear"))
        _ = try await env.store.insert(Make.text("green apple"))
        let results = try await env.store.search(SearchQuery.parse("\"green apple\""), scope: .history)
        XCTAssertEqual(results.map(\.preview), ["green apple"])
    }

    func testFuzzyFallbackFindsSubsequence() async throws {
        _ = try await env.store.insert(Make.text("Keyboard Shortcuts"))
        _ = try await env.store.insert(Make.text("unrelated"))
        let results = try await env.store.search(SearchQuery.parse("kbsc"), scope: .history)
        XCTAssertEqual(results.map(\.preview), ["Keyboard Shortcuts"])
    }

    func testRankingPrefersWordStartMatches() async throws {
        _ = try await env.store.insert(Make.text("unpinned items"))
        _ = try await env.store.insert(Make.text("pin the card"))
        let results = try await env.store.search(SearchQuery.parse("pin"), scope: .history)
        XCTAssertEqual(results.first?.preview, "pin the card")
    }

    // MARK: Pinboards

    func testPinningKeepsItemWhenRemovedFromHistory() async throws {
        let item = try await env.store.insert(Make.text("keep me"))
        let board = try await env.store.createPinboard(name: "Snippets")
        try await env.store.pin(item.id, to: board.id)

        try await env.store.removeFromHistory([item.id])
        let history = try await env.store.history()
        XCTAssertTrue(history.isEmpty)
        let pinned = try await env.store.items(onPinboard: board.id)
        XCTAssertEqual(pinned.map(\.id), [item.id])

        // Unpinning an item that already left history deletes it with its files.
        try await env.store.unpin(item.id, from: board.id)
        let gone = try await env.store.item(item.id)
        XCTAssertNil(gone)
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.paths.blobDirectory(for: item.id).path))
    }

    func testRemovingUnpinnedItemDeletesFiles() async throws {
        let item = try await env.store.insert(Make.image())
        XCTAssertTrue(FileManager.default.fileExists(atPath: env.paths.thumbnail(for: item.id).path))
        try await env.store.removeFromHistory([item.id])
        let gone = try await env.store.item(item.id)
        XCTAssertNil(gone)
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.paths.thumbnail(for: item.id).path))
    }

    func testPinOrderAndReorder() async throws {
        let a = try await env.store.insert(Make.text("a"))
        let b = try await env.store.insert(Make.text("b"))
        let c = try await env.store.insert(Make.text("c"))
        let board = try await env.store.createPinboard(name: "Board")
        for item in [a, b, c] { try await env.store.pin(item.id, to: board.id) }
        var order = try await env.store.items(onPinboard: board.id).map(\.preview)
        XCTAssertEqual(order, ["c", "b", "a"], "new pins go first")

        try await env.store.reorderPins(on: board.id, itemIDs: [a.id, c.id, b.id])
        order = try await env.store.items(onPinboard: board.id).map(\.preview)
        XCTAssertEqual(order, ["a", "c", "b"])

        try await env.store.pin(a.id, to: board.id) // already pinned: no-op
        let count = try await env.store.pinboards().first?.itemCount
        XCTAssertEqual(count, 3)
    }

    func testPinboardCrudAndReorder() async throws {
        let one = try await env.store.createPinboard(name: "One")
        let two = try await env.store.createPinboard(name: "Two")
        XCTAssertNotEqual(one.color, two.color)
        try await env.store.updatePinboard(one.id, name: "First", color: .red, icon: .some("star"))
        try await env.store.reorderPinboards([two.id, one.id])
        let boards = try await env.store.pinboards()
        XCTAssertEqual(boards.map(\.name), ["Two", "First"])
        XCTAssertEqual(boards.last?.color, .red)
        XCTAssertEqual(boards.last?.icon, "star")

        let item = try await env.store.insert(Make.text("only on two"))
        try await env.store.pin(item.id, to: two.id)
        try await env.store.removeFromHistory([item.id])
        try await env.store.deletePinboard(two.id)
        let gone = try await env.store.item(item.id)
        XCTAssertNil(gone, "items only on a deleted board and not in history are deleted")
    }

    func testPinnedFilterAndGlobalSearch() async throws {
        let a = try await env.store.insert(Make.text("alpha pinned"))
        _ = try await env.store.insert(Make.text("alpha loose"))
        let board = try await env.store.createPinboard(name: "Snippets")
        try await env.store.pin(a.id, to: board.id)

        let pinned = try await env.store.search(SearchQuery.parse("pinned: alpha"), scope: .history)
        XCTAssertEqual(pinned.map(\.preview), ["alpha pinned"])
        let byName = try await env.store.search(SearchQuery.parse("pinned:snippets"), scope: .history)
        XCTAssertEqual(byName.map(\.preview), ["alpha pinned"])

        try await env.store.removeFromHistory([a.id])
        let history = try await env.store.search(SearchQuery.parse("alpha"), scope: .history)
        XCTAssertEqual(history.map(\.preview), ["alpha loose"])
        let everywhere = try await env.store.search(SearchQuery.parse("alpha"), scope: .everywhere)
        XCTAssertEqual(Set(everywhere.map(\.preview)), ["alpha pinned", "alpha loose"])
        let names = try await env.store.pinboardNames(for: everywhere.map(\.id))
        XCTAssertEqual(names[a.id], ["Snippets"])

        let onBoard = try await env.store.search(SearchQuery.parse("alp"), scope: .pinboard(board.id))
        XCTAssertEqual(onBoard.map(\.preview), ["alpha pinned"])
    }

    // MARK: Retention

    func testRetentionPurgesOldUnpinnedItems() async throws {
        let now = Date()
        let old = try await env.store.insert(Make.text("old", at: now.addingTimeInterval(-40 * 86_400)))
        let oldPinned = try await env.store.insert(Make.text("old pinned", at: now.addingTimeInterval(-40 * 86_400)))
        let fresh = try await env.store.insert(Make.text("fresh", at: now.addingTimeInterval(-86_400)))
        let board = try await env.store.createPinboard(name: "Keep")
        try await env.store.pin(oldPinned.id, to: board.id)

        let result = try await env.store.purge(retention: .month, now: now)
        XCTAssertEqual(result.deleted, 1)
        XCTAssertEqual(result.keptBecausePinned, 1)
        let history = try await env.store.history().map(\.id)
        XCTAssertEqual(history, [fresh.id])
        let oldItem = try await env.store.item(old.id)
        XCTAssertNil(oldItem)
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.paths.blobDirectory(for: old.id).path))
        let pinned = try await env.store.items(onPinboard: board.id).map(\.id)
        XCTAssertEqual(pinned, [oldPinned.id])
    }

    func testForeverKeepsEverything() async throws {
        _ = try await env.store.insert(Make.text("ancient", at: Date(timeIntervalSinceNow: -900 * 86_400)))
        let result = try await env.store.purge(retention: .forever)
        XCTAssertEqual(result.deleted, 0)
        let count = try await env.store.historyCount()
        XCTAssertEqual(count, 1)
    }

    func testHardCapDeletesOldestUnpinned() async throws {
        let env = TestEnvironment(hardCap: 5)
        defer { env.cleanUp() }
        let start = Date(timeIntervalSinceNow: -1_000)
        var ids: [UUID] = []
        for index in 0..<8 {
            ids.append(try await env.store.insert(Make.text("item \(index)", at: start.addingTimeInterval(Double(index)))).id)
        }
        let board = try await env.store.createPinboard(name: "B")
        try await env.store.pin(ids[0], to: board.id)
        _ = try await env.store.purge(retention: .forever)
        let remaining = Set(try await env.store.history().map(\.id))
        XCTAssertTrue(remaining.contains(ids[0]), "pinned items are exempt")
        XCTAssertFalse(remaining.contains(ids[1]))
        XCTAssertFalse(remaining.contains(ids[2]))
        XCTAssertEqual(remaining.count, 6) // 5 unpinned + 1 pinned
    }

    func testRemoveOldImages() async throws {
        let now = Date()
        _ = try await env.store.insert(Make.image(at: now.addingTimeInterval(-40 * 86_400), seed: 1))
        _ = try await env.store.insert(Make.image(at: now, seed: 2))
        let stats = try await env.store.statistics(now: now)
        XCTAssertEqual(stats.oldImageCount, 1)
        let removed = try await env.store.removeImages(olderThan: now.addingTimeInterval(-30 * 86_400))
        XCTAssertEqual(removed, 1)
        let count = try await env.store.historyCount()
        XCTAssertEqual(count, 1)
    }

    // MARK: Erase

    func testEraseHistoryEmptiesDirectoryAndRotatesKey() async throws {
        let item = try await env.store.insert(Make.image())
        let keyBefore = try env.keys.key()
        try await env.store.eraseHistory(keepPinned: false)
        let count = try await env.store.historyCount()
        XCTAssertEqual(count, 0)
        let blobs = try FileManager.default.contentsOfDirectory(atPath: env.paths.blobs.path)
        let thumbs = try FileManager.default.contentsOfDirectory(atPath: env.paths.thumbs.path)
        XCTAssertTrue(blobs.isEmpty)
        XCTAssertTrue(thumbs.isEmpty)
        XCTAssertNotEqual(try env.keys.key(), keyBefore)
        let gone = try await env.store.item(item.id)
        XCTAssertNil(gone)
    }

    func testEraseKeepingPinnedResealsUnderNewKey() async throws {
        let pinned = try await env.store.insert(Make.text("pinned stays"))
        _ = try await env.store.insert(Make.text("goes away"))
        let board = try await env.store.createPinboard(name: "B")
        try await env.store.pin(pinned.id, to: board.id)
        try await env.store.eraseHistory(keepPinned: true)

        let history = try await env.store.history()
        XCTAssertTrue(history.isEmpty)
        let representations = try await env.store.representations(for: pinned.id)
        XCTAssertEqual(representations.first?.data, Data("pinned stays".utf8))
        XCTAssertNil(try env.keys.pendingKey())
    }

    func testInterruptedRotationIsFinishedOnOpen() async throws {
        let item = try await env.store.insert(Make.text("survives a crash"))
        _ = try env.keys.beginRotation() // crash before re-sealing
        let reopened = Store(paths: env.paths, keyProvider: env.keys, preferences: env.preferences)
        try await reopened.open()
        XCTAssertNil(try env.keys.pendingKey())
        let representations = try await reopened.representations(for: item.id)
        XCTAssertEqual(representations.first?.data, Data("survives a crash".utf8))
    }

    // MARK: Events

    func testEventsAreBroadcastToEverySubscriber() async throws {
        let first = env.store.events()
        let second = env.store.events()
        let item = try await env.store.insert(Make.text("broadcast"))
        var iterator1 = first.makeAsyncIterator()
        var iterator2 = second.makeAsyncIterator()
        guard case .captured(let one, true) = await iterator1.next(),
              case .captured(let two, true) = await iterator2.next() else {
            return XCTFail("expected captured events")
        }
        XCTAssertEqual(one.id, item.id)
        XCTAssertEqual(two.id, item.id)
    }

    func testClipItemDescriptionNeverContainsContent() async throws {
        let item = try await env.store.insert(Make.text("my bank password hunter2"))
        let printed = [String(describing: item), String(reflecting: item), "\(item)"].joined()
        XCTAssertFalse(printed.contains("hunter2"))
        XCTAssertTrue(printed.contains(item.id.uuidString))
    }
}
