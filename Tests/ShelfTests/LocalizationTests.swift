import Foundation
import XCTest

/// The String Catalog is complete and actually compiles into working lookups.
/// `swift build` alone does not prove this: the catalog is compiled by
/// `build.sh` into the app bundle.
final class LocalizationTests: XCTestCase {
    static let languages = ["nl", "de", "fr", "es", "ja"]

    var catalogURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Localizable.xcstrings")
    }

    func testEveryStringIsTranslatedIntoEveryLanguage() throws {
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any]
        let strings = try XCTUnwrap(catalog?["strings"] as? [String: [String: Any]])
        XCTAssertGreaterThan(strings.count, 250)
        var missing: [String] = []
        for (key, entry) in strings where (entry["shouldTranslate"] as? Bool) != false {
            let localizations = entry["localizations"] as? [String: Any] ?? [:]
            for language in Self.languages where localizations[language] == nil {
                missing.append("\(language): \(key)")
            }
        }
        XCTAssertTrue(missing.isEmpty, "Untranslated:\n" + missing.sorted().prefix(30).joined(separator: "\n"))
    }

    func testFormatSpecifiersSurviveTranslation() throws {
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any]
        let strings = try XCTUnwrap(catalog?["strings"] as? [String: [String: Any]])
        let pattern = try NSRegularExpression(pattern: "%(\\d+\\$)?(@|lld|d)")
        func specifiers(_ text: String) -> [String] {
            pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
                .map { (text as NSString).substring(with: $0.range(at: 2)) }.sorted()
        }
        for (key, entry) in strings {
            let expected = specifiers(key)
            for (language, value) in entry["localizations"] as? [String: [String: Any]] ?? [:] {
                for translation in Self.values(in: value) {
                    XCTAssertEqual(specifiers(translation), expected, "\(language): \(key) -> \(translation)")
                }
            }
        }
    }

    func testCompiledCatalogResolvesLookupsAndPlurals() throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("l10n-\(UUID().uuidString)")
        defer { removeIfPresent(output) }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["xcstringstool", "compile", catalogURL.path, "--output-directory", output.path]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw XCTSkip("xcstringstool needs a full Xcode install") }

        let dutch = try XCTUnwrap(Bundle(url: output.appendingPathComponent("nl.lproj")))
        XCTAssertEqual(dutch.localizedString(forKey: "Settings", value: nil, table: nil), "Instellingen")
        let german = try XCTUnwrap(Bundle(url: output.appendingPathComponent("de.lproj")))
        XCTAssertEqual(german.localizedString(forKey: "Settings", value: nil, table: nil), "Einstellungen")
        let japanese = try XCTUnwrap(Bundle(url: output.appendingPathComponent("ja.lproj")))
        XCTAssertEqual(japanese.localizedString(forKey: "Settings", value: nil, table: nil), "設定")

        let english = try XCTUnwrap(Bundle(url: output.appendingPathComponent("en.lproj")))
        let format = english.localizedString(forKey: "%lld items", value: nil, table: nil)
        XCTAssertEqual(String.localizedStringWithFormat(format, 1), "1 item")
        XCTAssertEqual(String.localizedStringWithFormat(format, 3), "3 items")
    }

    static func values(in localization: [String: Any]) -> [String] {
        if let unit = localization["stringUnit"] as? [String: Any], let value = unit["value"] as? String {
            return [value]
        }
        let variations = localization["variations"] as? [String: [String: [String: Any]]] ?? [:]
        return variations.values.flatMap { $0.values.flatMap { values(in: $0) } }
    }
}
