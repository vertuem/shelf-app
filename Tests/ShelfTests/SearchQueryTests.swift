@testable import ShelfCore
import XCTest

final class SearchQueryTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_791_936_000) // 2026-10-14 UTC
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func testPlainTerms() {
        let query = SearchQuery.parse("hello  world", now: now, calendar: calendar)
        XCTAssertEqual(query.terms, ["hello", "world"])
        XCTAssertTrue(query.filters.isEmpty)
    }

    func testTypePrefix() {
        let query = SearchQuery.parse("type:image cat", now: now, calendar: calendar)
        XCTAssertEqual(query.kinds, [.image])
        XCTAssertEqual(query.terms, ["cat"])
        XCTAssertEqual(query.filters.map(\.key), ["type"])
        XCTAssertEqual(SearchQuery.parse("type:url").kinds, [.link])
    }

    func testUnknownTypeStaysText() {
        let query = SearchQuery.parse("type:banana", now: now, calendar: calendar)
        XCTAssertTrue(query.kinds.isEmpty)
        XCTAssertEqual(query.terms, ["type:banana"])
    }

    func testAppPrefix() {
        let query = SearchQuery.parse("app:Safari", now: now, calendar: calendar)
        XCTAssertEqual(query.apps, ["Safari"])
    }

    func testAfterIsoDate() {
        let query = SearchQuery.parse("after:2026-10-01", now: now, calendar: calendar)
        XCTAssertEqual(query.after, calendar.date(from: DateComponents(year: 2026, month: 10, day: 1)))
    }

    func testRelativeDates() {
        XCTAssertEqual(SearchQuery.parse("after:7d", now: now, calendar: calendar).after, now.addingTimeInterval(-7 * 86_400))
        XCTAssertEqual(SearchQuery.parse("after:today", now: now, calendar: calendar).after, calendar.startOfDay(for: now))
        XCTAssertNotNil(SearchQuery.parse("before:yesterday", now: now, calendar: calendar).before)
        XCTAssertNil(SearchQuery.parse("after:someday", now: now, calendar: calendar).after)
    }

    func testPinnedPrefix() {
        XCTAssertEqual(SearchQuery.parse("pinned:", now: now, calendar: calendar).pinned, .anyBoard)
        XCTAssertEqual(SearchQuery.parse("pinned:Snippets", now: now, calendar: calendar).pinned, .board("Snippets"))
    }

    func testQuotedPhrases() {
        let query = SearchQuery.parse("\"hello world\" type:text \"app:literal\"", now: now, calendar: calendar)
        XCTAssertEqual(query.terms, ["hello world", "app:literal"])
        XCTAssertEqual(query.kinds, [.text])
    }

    func testUnclosedQuote() {
        XCTAssertEqual(SearchQuery.parse("\"open ended", now: now, calendar: calendar).terms, ["open ended"])
    }

    func testRemovingAFilterChip() {
        let text = "foo type:image bar"
        let query = SearchQuery.parse(text)
        let removed = SearchQuery.removing(query.filters[0], from: text)
        XCTAssertEqual(removed, "foo bar")
    }

    func testEmptiness() {
        XCTAssertTrue(SearchQuery.parse("   ").isEmpty)
        XCTAssertFalse(SearchQuery.parse("pinned:").isEmpty)
    }
}

final class FuzzyScorerTests: XCTestCase {
    func testSubsequenceMatches() {
        XCTAssertNotNil(FuzzyScorer.score("kbs", in: "Keyboard Shortcuts"))
        XCTAssertNil(FuzzyScorer.score("xyz", in: "Keyboard Shortcuts"))
    }

    func testSubstringBeatsScatteredMatch() throws {
        let substring = try XCTUnwrap(FuzzyScorer.score("board", in: "Keyboard"))
        let scattered = try XCTUnwrap(FuzzyScorer.score("kbrd", in: "Keyboard"))
        XCTAssertGreaterThan(substring, scattered)
    }

    func testWordStartBeatsMidWord() throws {
        let start = try XCTUnwrap(FuzzyScorer.score("pin", in: "pin the card"))
        let middle = try XCTUnwrap(FuzzyScorer.score("pin", in: "unpinned"))
        XCTAssertGreaterThan(start, middle)
    }

    func testDoesNotCrashOnExpandingLowercase() {
        _ = FuzzyScorer.score("i", in: "İİİİ i")
    }
}

final class UUIDv7Tests: XCTestCase {
    func testVersionAndOrdering() {
        let early = UUIDv7.make(at: Date(timeIntervalSince1970: 1_000))
        let late = UUIDv7.make(at: Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(early.uuidString.lowercased().dropFirst(14).first, "7")
        XCTAssertLessThan(early.uuidString.lowercased(), late.uuidString.lowercased())
        XCTAssertEqual(UUIDv7.date(of: late), Date(timeIntervalSince1970: 2_000))
    }
}

final class CryptoTests: XCTestCase {
    func testSealedRoundTrip() throws {
        let keys = InMemoryBlobKeyProvider()
        let sealed = try BlobEnvelope.seal(Data("payload".utf8), key: keys.key())
        XCTAssertTrue(BlobEnvelope.isSealed(sealed))
        XCTAssertEqual(try BlobEnvelope.open(sealed) { [try keys.key()] }, Data("payload".utf8))
    }

    func testWrongKeyFails() throws {
        let sealed = try BlobEnvelope.seal(Data("payload".utf8), key: InMemoryBlobKeyProvider().key())
        XCTAssertThrowsError(try BlobEnvelope.open(sealed) { [try InMemoryBlobKeyProvider().key()] })
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try BlobEnvelope.open(Data("nope".utf8)) { [] })
    }

    func testPlainEnvelope() throws {
        let plain = BlobEnvelope.plain(Data("x".utf8))
        XCTAssertFalse(BlobEnvelope.isSealed(plain))
        XCTAssertEqual(try BlobEnvelope.open(plain) { [] }, Data("x".utf8))
    }

    func testKeychainProviderRoundTrip() throws {
        // Uses a throwaway service name; skipped where no login keychain is available (CI).
        let provider = KeychainBlobKeyProvider(service: "com.vertuem.shelf.tests.\(UUID().uuidString)")
        let first: Data
        do {
            first = try provider.key().withUnsafeBytes { Data($0) }
        } catch {
            throw XCTSkip("No usable keychain: \(error)")
        }
        let again = try KeychainBlobKeyProvider(service: provider.serviceForTests).key().withUnsafeBytes { Data($0) }
        XCTAssertEqual(first, again)
        _ = try provider.beginRotation()
        try provider.commitRotation()
        let rotated = try provider.key().withUnsafeBytes { Data($0) }
        XCTAssertNotEqual(first, rotated)
        provider.deleteAllForTests()
    }
}
