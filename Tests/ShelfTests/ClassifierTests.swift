import AppKit
@testable import ShelfCapture
import ShelfCore
import XCTest

final class ClassifierTests: XCTestCase {
    /// The phase gate: fixtures from eight apps classify correctly.
    func testFixturesClassifyCorrectly() throws {
        let fixtures = try PasteboardFixture.all()
        XCTAssertGreaterThanOrEqual(Set(fixtures.map(\.app)).count, 8)
        for fixture in fixtures {
            XCTAssertEqual(Classifier.classify(fixture.snapshot).rawValue, fixture.expectedKind, fixture.name)
        }
    }

    func testEveryKindHasAFixture() throws {
        let kinds = Set(try PasteboardFixture.all().map(\.expectedKind))
        XCTAssertEqual(kinds, Set(ContentKind.allCases.map(\.rawValue)))
    }

    func testColorTypeWinsOverEverything() throws {
        let data = try NSKeyedArchiver.archivedData(withRootObject: NSColor.systemRed, requiringSecureCoding: true)
        let snapshot = PasteboardSnapshot(items: [[
            ClipRepresentation(uti: PasteboardTypes.color, data: data),
            ClipRepresentation(uti: PasteboardTypes.plainText, data: Data("red".utf8)),
        ]])
        XCTAssertEqual(Classifier.classify(snapshot), .color)
        let item = ItemBuilder.build(from: snapshot, source: SourceApp(bundleID: nil, name: nil), maxItemBytes: 1_000_000)
        XCTAssertNotNil(item.colorHex)
        XCTAssertTrue(item.colorHex!.hasPrefix("#"))
    }

    func testSingleURLDetection() {
        XCTAssertNotNil(Classifier.singleURL(in: "https://example.com/a?b=c"))
        XCTAssertNotNil(Classifier.singleURL(in: "  http://localhost:8080  "))
        XCTAssertNotNil(Classifier.singleURL(in: "slack://channel?id=1"))
        XCTAssertNil(Classifier.singleURL(in: "example.com"))
        XCTAssertNil(Classifier.singleURL(in: "two https://a.com https://b.com"))
        XCTAssertNil(Classifier.singleURL(in: "file:///etc/hosts"))
        XCTAssertNil(Classifier.singleURL(in: "note: buy milk"))
    }

    func testHexColors() {
        XCTAssertEqual(Classifier.hexColor(in: "#abc"), "#AABBCC")
        XCTAssertEqual(Classifier.hexColor(in: " #1E90FF "), "#1E90FF")
        XCTAssertEqual(Classifier.hexColor(in: "#1E90FF80"), "#1E90FF80")
        XCTAssertNil(Classifier.hexColor(in: "1E90FF"))
        XCTAssertNil(Classifier.hexColor(in: "#GGGGGG"))
        XCTAssertNil(Classifier.hexColor(in: "#12345"))
    }

    func testLongTextBesideAnImageIsText() {
        let long = String(repeating: "word ", count: 60)
        let snapshot = PasteboardSnapshot.text(long, extra: [(PasteboardTypes.png, Data([1]))])
        XCTAssertEqual(Classifier.classify(snapshot), .text)
    }

    func testFileNameBesideAnImageIsImage() {
        let snapshot = PasteboardSnapshot.text("IMG_0042.jpg", extra: [(PasteboardTypes.jpeg, Data([1]))])
        XCTAssertEqual(Classifier.classify(snapshot), .image)
    }

    func testEmptyIsOther() {
        XCTAssertEqual(Classifier.classify(PasteboardSnapshot(items: [])), .other)
    }
}

final class ItemBuilderTests: XCTestCase {
    let source = SourceApp(bundleID: "com.apple.Notes", name: "Notes")

    func testPreviewIsCappedAndNormalized() {
        let text = "  first   line\t with tabs \n\n\n\nsecond line  \n" + String(repeating: "x", count: 1_000)
        let item = ItemBuilder.build(from: .text(text), source: source, maxItemBytes: 1_000_000)
        XCTAssertTrue(item.preview.hasPrefix("first line with tabs\n\nsecond line\n"))
        XCTAssertEqual(item.preview.count, 500)
        XCTAssertEqual(item.sourceAppName, "Notes")
    }

    func testOversizedItemsKeepOnlySmallTypes() {
        let big = Data(count: 2_000_000)
        let snapshot = PasteboardSnapshot(items: [[
            ClipRepresentation(uti: PasteboardTypes.tiff, data: big),
            ClipRepresentation(uti: PasteboardTypes.url, data: Data("https://example.com/big.tiff".utf8)),
        ]])
        let item = ItemBuilder.build(from: snapshot, source: source, maxItemBytes: 1_000_000)
        XCTAssertTrue(item.oversized)
        XCTAssertEqual(item.representations.map(\.uti), [PasteboardTypes.url])
        XCTAssertEqual(item.byteSize, big.count + 28)
    }

    func testImageDimensionsAndThumbnail() throws {
        let png = try XCTUnwrap(Self.pngData(width: 1_600, height: 900))
        let snapshot = PasteboardSnapshot(items: [[ClipRepresentation(uti: PasteboardTypes.png, data: png)]])
        let item = ItemBuilder.build(from: snapshot, source: source, maxItemBytes: 10_000_000)
        XCTAssertEqual(item.kind, .image)
        XCTAssertEqual(item.width, 1_600)
        XCTAssertEqual(item.height, 900)
        let thumbnail = try XCTUnwrap(item.thumbnail)
        let info = try XCTUnwrap(Thumbnailer.info(of: thumbnail))
        XCTAssertEqual(max(info.width, info.height), 512)
    }

    func testFilePathsFromEveryItem() throws {
        let fixture = try XCTUnwrap(PasteboardFixture.all().first { $0.name == "finder-two-files" })
        let item = ItemBuilder.build(from: fixture.snapshot, source: source, maxItemBytes: 1_000_000)
        XCTAssertEqual(item.filePaths, ["/Users/test/a.txt", "/Users/test/b.txt"])
        XCTAssertEqual(item.preview, "a.txt\nb.txt")
        XCTAssertEqual(Set(item.representations.map(\.itemIndex)), [0, 1])
    }

    func testRichTextWithoutPlainTextGetsAPreview() {
        let html = "<html><head><style>p{}</style></head><body><p>Hello&nbsp;<b>world</b></p></body></html>"
        let snapshot = PasteboardSnapshot(items: [[ClipRepresentation(uti: PasteboardTypes.html, data: Data(html.utf8))]])
        let item = ItemBuilder.build(from: snapshot, source: source, maxItemBytes: 1_000_000)
        XCTAssertEqual(item.kind, .richText)
        XCTAssertEqual(item.preview, "Hello world")
    }

    func testLinkKeepsURL() {
        let snapshot = PasteboardSnapshot.text("https://example.com/path")
        let item = ItemBuilder.build(from: snapshot, source: source, maxItemBytes: 1_000_000)
        XCTAssertEqual(item.kind, .link)
        XCTAssertEqual(item.url, "https://example.com/path")
    }

    func testHashIsStableAndContentSensitive() {
        let first = ItemBuilder.hash(of: .text("same"))
        XCTAssertEqual(first, ItemBuilder.hash(of: .text("same")))
        XCTAssertNotEqual(first, ItemBuilder.hash(of: .text("different")))
        let sameBytesOtherType = PasteboardSnapshot(items: [[ClipRepresentation(uti: PasteboardTypes.html, data: Data("same".utf8))]])
        XCTAssertNotEqual(first, ItemBuilder.hash(of: sameBytesOtherType))
        XCTAssertEqual(first.count, 32)
    }

    static func pngData(width: Int, height: Int) -> Data? {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)
        return rep?.representation(using: .png, properties: [:])
    }
}

final class CaptureFilterTests: XCTestCase {
    let settings = CaptureSettings()

    func evaluate(_ types: Set<String>, apps: [String] = ["com.apple.TextEdit"], locked: Bool = false,
                  settings: CaptureSettings? = nil) -> CaptureRejection? {
        CaptureFilter.evaluate(types: types, sourceBundleIDs: apps, isScreenLocked: locked, settings: settings ?? self.settings)
    }

    func testOrdinaryCopyPasses() {
        XCTAssertNil(evaluate([PasteboardTypes.plainText]))
    }

    func testOwnWritesAreIgnored() {
        XCTAssertEqual(evaluate([PasteboardTypes.plainText, Brand.originMarkerType]), .ownWrite)
    }

    func testConcealedTransientAutoGenerated() {
        XCTAssertEqual(evaluate([PasteboardTypes.plainText, PasteboardTypes.concealed]), .concealed)
        XCTAssertEqual(evaluate([PasteboardTypes.plainText, "com.agilebits.onepassword"]), .concealed)
        XCTAssertEqual(evaluate([PasteboardTypes.plainText, PasteboardTypes.transient]), .transient)
        XCTAssertEqual(evaluate([PasteboardTypes.plainText, PasteboardTypes.autoGenerated]), .autoGenerated)
    }

    func testFiltersCanBeTurnedOff() {
        var relaxed = CaptureSettings()
        relaxed.ignoreConfidential = false
        relaxed.ignoreTransient = false
        relaxed.ignoreAutoGenerated = false
        XCTAssertNil(evaluate([PasteboardTypes.plainText, PasteboardTypes.concealed, PasteboardTypes.transient,
                               PasteboardTypes.autoGenerated], settings: relaxed))
    }

    func testIgnoredAppsIncludingWildcards() {
        XCTAssertEqual(evaluate([PasteboardTypes.plainText], apps: ["com.1password.1password"]), .ignoredApp("com.1password.1password"))
        var custom = CaptureSettings()
        custom.ignoredApps = ["com.parallels.*"]
        XCTAssertEqual(evaluate([PasteboardTypes.plainText], apps: ["com.parallels.vm"], settings: custom), .ignoredApp("com.parallels.vm"))
        XCTAssertNil(evaluate([PasteboardTypes.plainText], apps: ["com.parallel"], settings: custom))
    }

    func testLockedScreen() {
        XCTAssertEqual(evaluate([PasteboardTypes.plainText], locked: true), .screenLocked)
        var allowed = CaptureSettings()
        allowed.captureWhileLocked = true
        XCTAssertNil(evaluate([PasteboardTypes.plainText], locked: true, settings: allowed))
    }

    func testEmpty() {
        XCTAssertEqual(evaluate([]), .empty)
    }

    func testSecretDetector() {
        XCTAssertTrue(SecretDetector.looksLikeSecret("ghp_abcdefghijklmnopqrstuvwxyz0123456789"))
        XCTAssertTrue(SecretDetector.looksLikeSecret("sk-proj-1234567890abcdefXYZ"))
        XCTAssertTrue(SecretDetector.looksLikeSecret("Zx8!qL2#vN9$wP4@rT6%"))
        XCTAssertTrue(SecretDetector.looksLikeSecret("AKIAIOSFODNN7EXAMPLE"))
        XCTAssertFalse(SecretDetector.looksLikeSecret("hello world this is a sentence"))
        XCTAssertFalse(SecretDetector.looksLikeSecret("short"))
        XCTAssertFalse(SecretDetector.looksLikeSecret("https://example.com/a/very/long/path/here"))
        XCTAssertFalse(SecretDetector.looksLikeSecret("Pneumonoultramicroscopic"))
        XCTAssertFalse(SecretDetector.looksLikeSecret("someone.long.name@example.com"))
    }
}
