import AppKit
import ShelfCapture
import ShelfCore
@testable import ShelfPaste
import XCTest

@MainActor
final class RecordingKeystrokes: KeystrokeSending {
    var pastes = 0
    var pasteboardAtKeystroke: String?
    weak var pasteboard: NSPasteboard?

    func sendPaste() {
        pastes += 1
        pasteboardAtKeystroke = pasteboard?.string(forType: .string)
    }
}

@MainActor
struct FakeAccessibility: AccessibilityChecking {
    var isTrusted: Bool
}

@MainActor
final class PasterTests: XCTestCase {
    var env: TestEnvironment!
    var pasteboard: NSPasteboard!
    var keystrokes: RecordingKeystrokes!

    override func setUp() async throws {
        env = TestEnvironment()
        try await env.store.open()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("shelf-paster-\(UUID().uuidString)"))
        keystrokes = RecordingKeystrokes()
        keystrokes.pasteboard = pasteboard
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
        env.cleanUp()
    }

    func makePaster(trusted: Bool = true) -> Paster {
        let paster = Paster(store: env.store, preferences: env.preferences, pasteboard: pasteboard,
                            keystrokes: keystrokes, accessibility: FakeAccessibility(isTrusted: trusted))
        paster.restoreDelay = .milliseconds(20)
        return paster
    }

    func storeRichItem() async throws -> ClipItem {
        let snapshot = PasteboardSnapshot(items: [[
            ClipRepresentation(uti: PasteboardTypes.rtf, data: Data("{\\rtf1 Bold}".utf8)),
            ClipRepresentation(uti: PasteboardTypes.plainText, data: Data("Bold".utf8)),
        ]])
        return try await env.store.insert(ItemBuilder.build(from: snapshot, source: SourceApp(bundleID: nil, name: nil), maxItemBytes: 1_000_000))
    }

    func testPasteWritesTypesSendsKeystrokeAndRestores() async throws {
        env.defaults.set(true, forKey: PrefKey.restorePreviousClipboard)
        let item = try await storeRichItem()
        pasteboard.clearContents()
        pasteboard.setString("what the user had", forType: .string)
        var closed = false

        let outcome = await makePaster().perform(.paste, item: item, targetBundleID: "com.apple.TextEdit") { closed = true }

        XCTAssertEqual(outcome, .pasted)
        XCTAssertTrue(closed)
        XCTAssertEqual(keystrokes.pastes, 1)
        XCTAssertEqual(keystrokes.pasteboardAtKeystroke, "Bold")
        // Restored with the restored marker, so the monitor does not record it again.
        XCTAssertEqual(pasteboard.string(forType: .string), "what the user had")
        XCTAssertFalse(pasteboard.types?.contains(NSPasteboard.PasteboardType(Brand.originMarkerType)) ?? true)
        XCTAssertTrue(pasteboard.types?.contains(NSPasteboard.PasteboardType(Brand.restoredMarkerType)) ?? false)
    }

    func testWrittenItemCarriesOriginMarkerAndAllTypes() async throws {
        let item = try await storeRichItem()
        _ = await makePaster().perform(.paste, item: item, targetBundleID: nil)
        let types = PasteboardWriter.saveContents(of: pasteboard).map(\.uti)
        XCTAssertEqual(types.filter { $0 != Brand.originMarkerType }, [PasteboardTypes.rtf, PasteboardTypes.plainText])
        XCTAssertTrue(types.contains(Brand.originMarkerType))
    }

    func testPlainTextModeWritesPlainTextOnly() async throws {
        let item = try await storeRichItem()
        _ = await makePaster().perform(.pastePlain, item: item, targetBundleID: nil)
        let types = Set(PasteboardWriter.saveContents(of: pasteboard).map(\.uti))
        XCTAssertEqual(types, [PasteboardTypes.plainText, Brand.originMarkerType])
    }

    func testAlwaysPlainTextSetting() async throws {
        env.defaults.set(true, forKey: PrefKey.alwaysPastePlainText)
        let item = try await storeRichItem()
        _ = await makePaster().perform(.paste, item: item, targetBundleID: nil)
        XCTAssertFalse(pasteboard.types?.contains(.rtf) ?? true)
    }

    func testCopyOnlyNeverTypes() async throws {
        let item = try await storeRichItem()
        let outcome = await makePaster().perform(.copy, item: item, targetBundleID: "com.apple.TextEdit")
        XCTAssertEqual(outcome, .copied(.requested))
        XCTAssertEqual(keystrokes.pastes, 0)
        XCTAssertEqual(pasteboard.string(forType: .string), "Bold", "copy keeps the item on the clipboard")
    }

    func testKnownBadAppFallsBackToCopy() async throws {
        let item = try await storeRichItem()
        let outcome = await makePaster().perform(.paste, item: item, targetBundleID: "com.apple.Terminal")
        XCTAssertEqual(outcome, .copied(.manualPasteApp("com.apple.Terminal")))
        XCTAssertEqual(keystrokes.pastes, 0)
        let parallels = await makePaster().perform(.paste, item: item, targetBundleID: "com.parallels.vm")
        XCTAssertEqual(parallels, .copied(.manualPasteApp("com.parallels.vm")))
    }

    func testWithoutAccessibilityPasteModeIsClipboard() async throws {
        let item = try await storeRichItem()
        let paster = makePaster(trusted: false)
        XCTAssertEqual(paster.effectivePasteMode, .toClipboard)
        let outcome = await paster.perform(.paste, item: item, targetBundleID: "com.apple.TextEdit")
        XCTAssertEqual(outcome, .copied(.accessibilityMissing))
        XCTAssertEqual(keystrokes.pastes, 0)
    }

    func testPasteModeClipboardSetting() async throws {
        env.preferences.pasteMode = .toClipboard
        let item = try await storeRichItem()
        let outcome = await makePaster().perform(.paste, item: item, targetBundleID: "com.apple.TextEdit")
        XCTAssertEqual(outcome, .copied(.pasteModeIsClipboard))
    }

    func testMissingFilePastesPathAsText() async throws {
        let snapshot = PasteboardSnapshot(items: [[ClipRepresentation(uti: PasteboardTypes.fileURL, data: Data("file:///nonexistent/gone.txt".utf8))]])
        let item = try await env.store.insert(ItemBuilder.build(from: snapshot, source: SourceApp(bundleID: nil, name: nil), maxItemBytes: 1_000_000))
        XCTAssertTrue(item.missingFiles)
        _ = await makePaster().perform(.paste, item: item, targetBundleID: nil)
        XCTAssertEqual(pasteboard.string(forType: .string), "/nonexistent/gone.txt")
    }

    func testPasteMovesItemToFront() async throws {
        let item = try await storeRichItem()
        _ = try await env.store.insert(Make.text("newer"))
        _ = await makePaster().perform(.copy, item: item, targetBundleID: nil)
        let first = try await env.store.history().first
        XCTAssertEqual(first?.id, item.id)
    }

    func testPastedItemStaysOnClipboardByDefault() async throws {
        let item = try await storeRichItem()
        pasteboard.clearContents()
        pasteboard.setString("old", forType: .string)
        _ = await makePaster().perform(.paste, item: item, targetBundleID: nil)
        XCTAssertEqual(pasteboard.string(forType: .string), "Bold")
    }

    func testMultiItemPasteboardsAreRestoredAsSeparateItems() throws {
        let representations = [
            ClipRepresentation(itemIndex: 0, uti: PasteboardTypes.fileURL, data: Data("file:///a".utf8)),
            ClipRepresentation(itemIndex: 1, uti: PasteboardTypes.fileURL, data: Data("file:///b".utf8)),
        ]
        PasteboardWriter.write(representations, to: pasteboard)
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 2)
    }

    // MARK: Several cards at once

    func testSeveralTextCardsPasteAsLinesInOrder() async throws {
        let first = try await env.store.insert(Make.text("one"))
        let second = try await storeRichItem()
        let image = try await env.store.insert(Make.image())
        let outcome = await makePaster().perform(.paste, items: [first, second, image], targetBundleID: "com.apple.TextEdit")
        XCTAssertEqual(outcome, .pasted)
        XCTAssertEqual(pasteboard.string(forType: .string), "one\nBold", "the image has no text and is left out")
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 1)
        XCTAssertNotNil(pasteboard.pasteboardItems?.first?.data(forType: PasteboardWriter.marker))
        XCTAssertEqual(keystrokes.pastes, 1)
    }

    func testSeveralFileCardsPasteAsSeparateFiles() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { FileManager.default.removeIfPresent(folder) }
        var items: [ClipItem] = []
        for name in ["a.txt", "b.txt"] {
            let url = folder.appendingPathComponent(name)
            try Data(name.utf8).write(to: url)
            let snapshot = PasteboardSnapshot(items: [[ClipRepresentation(uti: PasteboardTypes.fileURL, data: Data(url.absoluteString.utf8))]])
            items.append(try await env.store.insert(ItemBuilder.build(from: snapshot, source: SourceApp(bundleID: "com.apple.finder", name: "Finder"), maxItemBytes: 1_000_000)))
        }
        XCTAssertEqual(items.map(\.kind), [.file, .file])
        let outcome = await makePaster().perform(.paste, items: items, targetBundleID: "com.apple.finder")
        XCTAssertEqual(outcome, .pasted)
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 2, "one pasteboard item per file, as Finder copies them")
        XCTAssertEqual(pasteboard.pasteboardItems?.compactMap { $0.string(forType: .fileURL) }.count, 2)
    }

    func testOneCardInTheListPastesNormally() async throws {
        let item = try await storeRichItem()
        let outcome = await makePaster().perform(.paste, items: [item], targetBundleID: nil)
        XCTAssertEqual(outcome, .pasted)
        XCTAssertNotNil(pasteboard.data(forType: .rtf))
    }

    func testOnlyImagesSelectedFails() async throws {
        let one = try await env.store.insert(Make.image(seed: 1))
        let two = try await env.store.insert(Make.image(seed: 2))
        var closed = 0
        let outcome = await makePaster().perform(.paste, items: [one, two], targetBundleID: nil) { closed += 1 }
        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(closed, 1)
        XCTAssertEqual(keystrokes.pastes, 0)
    }

    func testTransformedPasteWritesChangedPlainText() async throws {
        let item = try await storeRichItem()
        let outcome = await makePaster().perform(.transformed(.uppercase), item: item, targetBundleID: nil)
        XCTAssertEqual(outcome, .pasted)
        XCTAssertEqual(pasteboard.string(forType: .string), "BOLD")
        XCTAssertNil(pasteboard.data(forType: .rtf), "a transform always pastes plain text")
        let two = try await env.store.insert(Make.text("second Item"))
        _ = await makePaster().perform(.transformed(.snakeCase), items: [item, two], targetBundleID: nil)
        XCTAssertEqual(pasteboard.string(forType: .string), "bold_second_item")
    }
}
