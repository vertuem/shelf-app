import Foundation
import ShelfCapture
import ShelfCore

/// A pasteboard captured from (or modeled on) a real app. See `Fixtures/_README.json`.
struct PasteboardFixture: Decodable {
    var name: String
    var app: String
    var expectedKind: String
    var items: [[Entry]]
    var promised: [String]?

    struct Entry: Decodable {
        var type: String
        var text: String?
        var base64: String?

        var data: Data {
            if let text { return Data(text.utf8) }
            return base64.flatMap { Data(base64Encoded: $0) } ?? Data()
        }
    }

    var snapshot: PasteboardSnapshot {
        PasteboardSnapshot(
            items: items.enumerated().map { index, entries in
                entries.map { ClipRepresentation(itemIndex: index, uti: $0.type, data: $0.data) }
            },
            promisedTypes: promised ?? []
        )
    }

    static func all() throws -> [PasteboardFixture] {
        let folder = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix("_") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { try JSONDecoder().decode(PasteboardFixture.self, from: Data(contentsOf: $0)) }
    }
}

extension PasteboardSnapshot {
    static func text(_ string: String, extra: [(String, Data)] = []) -> PasteboardSnapshot {
        PasteboardSnapshot(items: [[ClipRepresentation(uti: PasteboardTypes.plainText, data: Data(string.utf8))]
                + extra.map { ClipRepresentation(uti: $0.0, data: $0.1) }])
    }
}
