@testable import ShelfCore
@testable import ShelfUI
import SwiftUI
import XCTest

/// Search highlighting on cards, and when a text card switches to monospace.
final class CardTextTests: XCTestCase {
    func testHighlightMarksEveryMatchCaseInsensitively() {
        let text = "Meeting moved to Thursday. meeting room booked."
        let marked = Highlighter.attributed(text, terms: ["meeting"])
        let runs = marked.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs.map { String(marked[$0.range].characters) }, ["Meeting", "meeting"])
        XCTAssertEqual(String(marked.characters), text, "the text itself is unchanged")
    }

    func testHighlightIgnoresDiacriticsAndEmptyTerms() {
        let marked = Highlighter.attributed("Café au lait", terms: ["cafe", ""])
        let runs = marked.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }
        XCTAssertEqual(runs.map { String(marked[$0.range].characters) }, ["Café"])
        XCTAssertTrue(Highlighter.attributed("plain", terms: []).runs.allSatisfy { $0.inlinePresentationIntent == nil })
    }

    func testCodeFromEditorsAndTerminalsIsMonospaced() {
        XCTAssertTrue(CodeDetector.isCodeApp("com.apple.Terminal"))
        XCTAssertTrue(CodeDetector.isCodeApp("com.jetbrains.rustrover"))
        XCTAssertFalse(CodeDetector.isCodeApp("com.apple.Notes"))
        XCTAssertFalse(CodeDetector.isCodeApp(nil))
    }

    func testTextThatLooksLikeCode() {
        XCTAssertTrue(CodeDetector.looksLikeCode("git rebase -i origin/main"))
        XCTAssertTrue(CodeDetector.looksLikeCode("let x = items.map { $0.id }"))
        XCTAssertTrue(CodeDetector.looksLikeCode("#!/bin/sh\nset -e"))
        XCTAssertTrue(CodeDetector.looksLikeCode("func a() {\n    return 1\n}\n"))
        XCTAssertTrue(CodeDetector.looksLikeCode("{\n  \"name\": \"shelf\",\n  \"version\": 1\n}"))
        XCTAssertTrue(CodeDetector.looksLikeCode("SELECT id FROM item WHERE in_history = 1"))
        XCTAssertFalse(CodeDetector.looksLikeCode("Meeting moved to Thursday 14:00. I booked the big room and sent the new invite."))
        XCTAssertFalse(CodeDetector.looksLikeCode("Quarterly report: revenue up 12 percent, churn down to 2.1 percent.\nFull numbers in the appendix."))
        XCTAssertFalse(CodeDetector.looksLikeCode("https://developer.apple.com/documentation"))
        XCTAssertFalse(CodeDetector.looksLikeCode(""))
    }

    func testOnlyTextCardsPreferMonospace() {
        func item(_ kind: ContentKind, _ preview: String, from bundleID: String) -> ClipItem {
            ClipItem(id: UUID(), createdAt: Date(), lastUsedAt: Date(), kind: kind, sourceBundleID: bundleID,
                     hash: Data(), byteSize: preview.utf8.count, preview: preview)
        }
        XCTAssertTrue(item(.text, "ls -la", from: "com.apple.Notes").prefersMonospace, "the text looks like a shell command")
        XCTAssertTrue(item(.text, "Dinner at eight?", from: "com.apple.Terminal").prefersMonospace, "anything from a terminal")
        XCTAssertFalse(item(.richText, "let x = 1", from: "com.apple.dt.Xcode").prefersMonospace, "rich text keeps its own look")
    }

    func testAShortFirstLineBecomesTheTitle() {
        let split = Highlighter.titleAndBody(of: "Room change\nMeeting moved to Thursday.")
        XCTAssertEqual(split.title, "Room change")
        XCTAssertEqual(split.body, "Meeting moved to Thursday.")
        XCTAssertNil(Highlighter.titleAndBody(of: "One line only").title)
        XCTAssertNil(Highlighter.titleAndBody(of: String(repeating: "x", count: 80) + "\nbody").title, "a long first line is body text")
        XCTAssertNil(Highlighter.titleAndBody(of: "Dear all,\nthanks").title, "a salutation is not a heading")
    }

    func testCodeColorsKeywordsStringsCommentsAndNumbers() {
        let code = "let total = count(\"items\") // sum\nfunc run() -> Int { 42 }"
        let marked = CodeHighlighter.attributed(code)
        func color(of token: String) -> Color? {
            guard let range = marked.range(of: token) else { return nil }
            return marked[range].foregroundColor
        }
        XCTAssertEqual(color(of: "let"), .purple)
        XCTAssertEqual(color(of: "func"), .purple)
        XCTAssertEqual(color(of: "\"items\""), .red)
        XCTAssertEqual(color(of: "// sum"), .gray)
        XCTAssertEqual(color(of: "42"), .blue)
        XCTAssertEqual(color(of: "Int"), .teal)
        XCTAssertNil(color(of: "total"), "plain identifiers keep the text color")
        XCTAssertEqual(String(marked.characters), code)
    }

    func testCodeSearchHighlightWinsOverSyntaxColor() {
        let marked = CodeHighlighter.attributed("let total = 1", searchTerms: ["let"])
        let range = marked.range(of: "let")!
        XCTAssertEqual(marked[range].foregroundColor, .accentColor)
        XCTAssertEqual(marked[range].inlinePresentationIntent, .stronglyEmphasized)
    }

    func testRichTextKeepsBoldAndItalicButNotFontsOrColors() throws {
        let rtf = Data("{\\rtf1\\ansi\\deff0{\\fonttbl{\\f0 Georgia;}}{\\colortbl;\\red255\\green0\\blue0;}\\f0\\fs28\\cf1 Plain {\\b bold} and {\\i italic}}".utf8)
        let text = try XCTUnwrap(RichTextRenderer.attributed(from: [ClipRepresentation(uti: PasteboardTypes.rtf, data: rtf)], pointSize: 12))
        XCTAssertEqual(String(text.characters), "Plain bold and italic")
        let bold = try XCTUnwrap(text.range(of: "bold").flatMap { text[$0].appKit.font })
        XCTAssertTrue(bold.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertEqual(bold.pointSize, 12, "sizes are normalized")
        XCTAssertFalse(bold.fontName.contains("Georgia"), "the card uses the system font")
        let italic = try XCTUnwrap(text.range(of: "italic").flatMap { text[$0].appKit.font })
        XCTAssertTrue(italic.fontDescriptor.symbolicTraits.contains(.italic))
        let plain = try XCTUnwrap(text.range(of: "Plain").flatMap { text[$0].appKit.font })
        XCTAssertFalse(plain.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertNil(text.range(of: "Plain").flatMap { text[$0].appKit.foregroundColor }, "colors are dropped for dark mode")
        XCTAssertNil(RichTextRenderer.attributed(from: [ClipRepresentation(uti: PasteboardTypes.html, data: Data("<b>x</b>".utf8))]), "HTML-only falls back to the preview")
    }

    func testTextTransforms() {
        XCTAssertEqual(TextTransform.uppercase.apply("Hello there"), "HELLO THERE")
        XCTAssertEqual(TextTransform.lowercase.apply("Hello THERE"), "hello there")
        XCTAssertEqual(TextTransform.titleCase.apply("hello there, world"), "Hello There, World")
        XCTAssertEqual(TextTransform.snakeCase.apply("Hello there, World"), "hello_there_world")
        XCTAssertEqual(TextTransform.snakeCase.apply("someCamelCase value2"), "some_camel_case_value2")
        XCTAssertEqual(TextTransform.kebabCase.apply("Shelf  position!"), "shelf-position")
    }

    func testContextBlockListsCardsOldestFirstWithMetadata() {
        func item(_ preview: String, kind: ContentKind = .text, app: String = "Notes", age: TimeInterval, title: String? = nil, ocr: String? = nil) -> ClipItem {
            ClipItem(id: UUID(), createdAt: Date(timeIntervalSince1970: 1_000_000 - age), lastUsedAt: Date(timeIntervalSince1970: 1_000_000 - age),
                     kind: kind, sourceAppName: app, hash: Data(), byteSize: 1, preview: preview, title: title, ocrText: ocr)
        }
        let block = ContextBlock.make([
            ContextBlock.Entry(item: item("newest", age: 0), text: "newest"),
            ContextBlock.Entry(item: item("", kind: .image, app: "Preview", age: 50, ocr: "ocr words"), text: nil),
            ContextBlock.Entry(item: item("func a() {\n    b()\n}", app: "Xcode", age: 100, title: "Helper"), text: "func a() {\n    b()\n}"),
        ], title: "Work", now: Date(timeIntervalSince1970: 1_000_000))
        let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(lines[0], "# Shelf: Work, 3 items")
        XCTAssertTrue(lines[1].hasPrefix("Copied "))
        XCTAssertEqual(lines[3], "## 1. Helper (Text)")
        XCTAssertTrue(lines[4].hasPrefix("From Xcode · "))
        XCTAssertEqual(lines[6], "```", "code is fenced")
        XCTAssertTrue(block.contains("## 2. Image\nFrom Preview"))
        XCTAssertTrue(block.contains("Text recognized in the image:\nocr words"))
        XCTAssertTrue(block.hasSuffix("## 3. Text\nFrom Notes · \(ContextBlock.stamp(Date(timeIntervalSince1970: 1_000_000)))\n\nnewest\n"))
    }
}
