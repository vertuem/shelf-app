import AppKit
@testable import ShelfCapture
import ShelfCore
import XCTest

/// Integration tests against a real, uniquely named pasteboard, so the user's
/// clipboard is never touched while tests run.
@MainActor
final class ClipboardMonitorTests: XCTestCase {
    var env: TestEnvironment!
    var pasteboard: NSPasteboard!
    var monitor: ClipboardMonitor!
    nonisolated(unsafe) static var frontmost = SourceApp(bundleID: "com.apple.TextEdit", name: "TextEdit")

    override func setUp() async throws {
        env = TestEnvironment()
        try await env.store.open()
        let name = NSPasteboard.Name("shelf-tests-\(UUID().uuidString)")
        Self.frontmost = SourceApp(bundleID: "com.apple.TextEdit", name: "TextEdit")
        monitor = ClipboardMonitor(store: env.store, preferences: env.preferences, pasteboard: NSPasteboard(name: name)) { Self.frontmost }
        // Same name, same pasteboard: the test writes, the monitor reads.
        pasteboard = NSPasteboard(name: name)
        await monitor.start()
    }

    override func tearDown() async throws {
        await monitor.stop()
        pasteboard.releaseGlobally()
        env.cleanUp()
    }

    func write(_ text: String, extraTypes: [String] = []) {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        for type in extraTypes {
            item.setData(Data(), forType: NSPasteboard.PasteboardType(type))
        }
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    func testCopyAppearsWithin500Milliseconds() async throws {
        write("hello from the integration test")
        let start = Date()
        // The 500 ms budget, with the 20% tolerance every budget gets (busy CI runners).
        let appeared = await wait(timeout: 0.6) { (try? await self.env.store.historyCount()) == 1 }
        XCTAssertTrue(appeared, "took \(Date().timeIntervalSince(start)) s")
        let item = try await env.store.history().first
        XCTAssertEqual(item?.preview, "hello from the integration test")
        XCTAssertEqual(item?.sourceBundleID, "com.apple.TextEdit")
        XCTAssertEqual(item?.kind, .text)
    }

    func testOwnWritesAreNotRecorded() async throws {
        write("pasted by Shelf", extraTypes: [Brand.originMarkerType])
        await monitor.tick()
        let count = try await env.store.historyCount()
        XCTAssertEqual(count, 0)
        let rejection = await monitor.lastRejection
        XCTAssertEqual(rejection, .ownWrite)
    }

    func testRestoredClipboardIsNotRecorded() async throws {
        // Copied in an ignored app that does not mark its data as concealed…
        Self.frontmost = SourceApp(bundleID: "com.bitwarden.desktop", name: "Bitwarden")
        write("vault secret")
        await monitor.tick()
        // …then put back by Shelf after a paste, while another app is frontmost.
        Self.frontmost = SourceApp(bundleID: "com.apple.TextEdit", name: "TextEdit")
        write("vault secret", extraTypes: [Brand.restoredMarkerType])
        await monitor.tick()
        let count = try await env.store.historyCount()
        XCTAssertEqual(count, 0)
    }

    func testConcealedItemsAreNeverStored() async throws {
        write("hunter2", extraTypes: [PasteboardTypes.concealed])
        await monitor.tick()
        let count = try await env.store.historyCount()
        XCTAssertEqual(count, 0)
        // Nothing reached the disk either.
        let blobs = try FileManager.default.contentsOfDirectory(atPath: env.paths.blobs.path)
        XCTAssertTrue(blobs.isEmpty)
    }

    func testIgnoredAppsAreNotRecorded() async throws {
        Self.frontmost = SourceApp(bundleID: "com.bitwarden.desktop", name: "Bitwarden")
        write("from a password manager")
        await monitor.tick()
        let count = try await env.store.historyCount()
        XCTAssertEqual(count, 0)
    }

    func testSwitchingAwayRightAfterCopyingInAnIgnoredAppIsStillIgnored() async throws {
        Self.frontmost = SourceApp(bundleID: "com.bitwarden.desktop", name: "Bitwarden")
        await monitor.tick() // a poll before the copy sees Bitwarden in front
        write("vault password")
        Self.frontmost = SourceApp(bundleID: "com.apple.Safari", name: "Safari") // ⌘Tab before the next poll
        await monitor.tick()
        let count = try await env.store.historyCount()
        XCTAssertEqual(count, 0)
    }

    func testReadingStopsAfterTheSizeLimit() async throws {
        let item = NSPasteboardItem()
        item.setData(Data(count: 2_000_000), forType: NSPasteboard.PasteboardType("com.example.big"))
        item.setData(Data(count: 2_000_000), forType: NSPasteboard.PasteboardType("com.example.bigger"))
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        let snapshot = PasteboardSnapshot.read(from: pasteboard, maxBytes: 1_000_000)
        XCTAssertEqual(snapshot.representations.count, 1)
        XCTAssertEqual(snapshot.skippedTypes, ["com.example.bigger"])
        let built = ItemBuilder.build(from: snapshot, source: SourceApp(bundleID: nil, name: nil), maxItemBytes: 10_000_000)
        XCTAssertTrue(built.oversized)
    }

    func testDuplicateWithinASecondIsMergedByHash() async throws {
        write("twice")
        await monitor.tick()
        write("twice")
        await monitor.tick()
        let count = try await env.store.historyCount()
        XCTAssertEqual(count, 1)
    }

    func testLockedScreenSkipsCopies() async throws {
        await monitor.setScreenLocked(true)
        write("copied while locked")
        await monitor.tick()
        let lockedCount = try await env.store.historyCount()
        XCTAssertEqual(lockedCount, 0)
        await monitor.setScreenLocked(false)
        write("copied after unlock")
        await monitor.tick()
        let history = try await env.store.history().map(\.preview)
        XCTAssertEqual(history, ["copied after unlock"])
    }

    func testPausedCaptureSkipsCopies() async throws {
        env.preferences.pausedUntil = Date().addingTimeInterval(60)
        write("while paused")
        await monitor.tick()
        let count = try await env.store.historyCount()
        XCTAssertEqual(count, 0)
    }

    func testOversizedItemIsFlagged() async throws {
        env.defaults.set(1, forKey: PrefKey.maxItemMegabytes)
        write(String(repeating: "a", count: 1_200_000))
        await monitor.tick()
        let item = try await env.store.history().first
        XCTAssertEqual(item?.oversized, true)
    }

    func testDetectSecretsWhenOn() async throws {
        env.defaults.set(true, forKey: PrefKey.detectSecrets)
        write("ghp_abcdefghijklmnopqrstuvwxyz0123456789")
        await monitor.tick()
        let count = try await env.store.historyCount()
        XCTAssertEqual(count, 0)
    }

    func testUniversalClipboardSource() async throws {
        write("from my iPhone", extraTypes: [PasteboardTypes.remoteClipboard])
        await monitor.tick()
        let item = try await env.store.history().first
        XCTAssertEqual(item?.sourceBundleID, UniversalClipboardSource.bundleID)
    }

    func testDeclaredSourceWinsOverFrontmostApp() async throws {
        let item = NSPasteboardItem()
        item.setString("text", forType: .string)
        item.setString("com.apple.Safari", forType: NSPasteboard.PasteboardType(PasteboardTypes.source))
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        await monitor.tick()
        let stored = try await env.store.history().first
        XCTAssertEqual(stored?.sourceBundleID, "com.apple.Safari")
    }

    func testLosslessRoundTripOfEveryType() async throws {
        let item = NSPasteboardItem()
        item.setString("plain", forType: .string)
        item.setData(Data("{\\rtf1 rich}".utf8), forType: .rtf)
        item.setData(Data("<b>rich</b>".utf8), forType: .html)
        item.setData(Data([0, 1, 2, 3]), forType: NSPasteboard.PasteboardType("com.example.private"))
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        let expected = PasteboardSnapshot.read(from: pasteboard).representations
        await monitor.tick()
        let stored = try await env.store.history().first
        let representations = try await env.store.representations(for: XCTUnwrap(stored).id)
        XCTAssertEqual(representations, expected)
        XCTAssertFalse(representations.contains { $0.uti == "NSStringPboardType" }, "synthesized aliases are not stored")
    }
}
