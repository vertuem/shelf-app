import AppKit
@testable import ShelfCapture
import ShelfCore
import XCTest

/// Text inside copied images is recognized on-device and lands in the search index.
@MainActor
final class ImageTextTests: XCTestCase {
    func testTextInsideACopiedImageBecomesSearchable() async throws {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        let recognizer = ImageTextRecognizer(store: env.store, preferences: env.preferences)
        recognizer.start()
        defer { recognizer.stop() }

        let item = try await env.store.insert(Self.image(saying: "SHELF OCR"))
        XCTAssertNil(item.ocrText, "recognition happens after the insert, off the capture path")

        let recognized = await wait(timeout: 30) {
            await Self.ocrText(of: item.id, in: env.store)?.contains("SHELF") == true
        }
        XCTAssertTrue(recognized, "the word drawn into the image should be recognized and stored")

        let results = try await env.store.search(SearchQuery.parse("shelf"), scope: .history)
        XCTAssertEqual(results.map(\.id), [item.id], "search matches the recognized text")
    }

    func testNothingIsStoredWhenRecognitionIsOff() async throws {
        let env = TestEnvironment()
        defer { env.cleanUp() }
        env.defaults.set(false, forKey: PrefKey.recognizeTextInImages)
        let recognizer = ImageTextRecognizer(store: env.store, preferences: env.preferences)
        recognizer.start()
        defer { recognizer.stop() }

        let skipped = try await env.store.insert(Self.image(saying: "SHELF OCR"))
        let storedWhileOff = await wait(timeout: 3) {
            await Self.ocrText(of: skipped.id, in: env.store) != nil
        }
        XCTAssertFalse(storedWhileOff, "with the setting off, no text is stored")

        // Turning the setting on applies to the next copy, which also proves the
        // recognizer was running and skipped the first one on purpose.
        env.defaults.set(true, forKey: PrefKey.recognizeTextInImages)
        let recognized = try await env.store.insert(Self.image(saying: "SHELF TWO"))
        let stored = await wait(timeout: 30) {
            await Self.ocrText(of: recognized.id, in: env.store)?.contains("SHELF") == true
        }
        XCTAssertTrue(stored)
        let skippedText = await Self.ocrText(of: skipped.id, in: env.store)
        XCTAssertNil(skippedText, "the item copied while the setting was off stays without text")

        let results = try await env.store.search(SearchQuery.parse("shelf"), scope: .history)
        XCTAssertEqual(results.map(\.id), [recognized.id])
    }

    // MARK: Support

    private static func ocrText(of id: UUID, in store: Store) async -> String? {
        (try? await store.item(id))?.ocrText
    }

    /// A 600 by 200 white PNG with `text` drawn large and black in the middle,
    /// inserted the way the capture path stores an image copy.
    private static func image(saying text: String) -> CapturedItem {
        let png = renderPNG(saying: text)
        let info = Thumbnailer.info(of: png)
        return CapturedItem(
            kind: .image,
            sourceBundleID: "com.apple.Preview",
            sourceAppName: "Preview",
            hash: Data(SHA.digest(png)),
            byteSize: png.count,
            width: info?.width,
            height: info?.height,
            representations: [ClipRepresentation(uti: PasteboardTypes.png, data: png)],
            thumbnail: Thumbnailer.thumbnail(of: png)
        )
    }

    private static func renderPNG(saying text: String) -> Data {
        let size = NSSize(width: 600, height: 200)
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let font = NSFont(name: "Helvetica-Bold", size: 48) ?? NSFont.boldSystemFont(ofSize: 48)
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black])
        let bounds = string.size()
        string.draw(at: NSPoint(x: (size.width - bounds.width) / 2, y: (size.height - bounds.height) / 2))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])!
    }

    /// A screenshot of a password field or a key must not land in the search index.
    func testSecretLookingTokensAreDroppedFromRecognizedText() {
        let lines = [
            "Username: alex",
            "API key: sk-live-4f8GhT2kQ9mZ1pL7xN3vB6cD8eR0sW5y",
            "AKIAIOSFODNN7EXAMPLE1 is the access key",
            "ghp_abcdefghijklmnopqrstuvwxyz0123456789",
            "Meeting at 14:00 in the big room",
        ]
        let kept = ImageTextRecognizer.redactingSecrets(lines)
        XCTAssertEqual(kept, [
            "Username: alex",
            "API key:",
            "is the access key",
            "Meeting at 14:00 in the big room",
        ])
    }
}
