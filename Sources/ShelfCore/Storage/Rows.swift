import Foundation
import GRDB

/// Conversions between GRDB rows and the model types. Kept in one place so the
/// column names in `Schema` and here can be compared at a glance.
enum Rows {
    static func millis(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    static func date(_ millis: Int64) -> Date {
        Date(timeIntervalSince1970: Double(millis) / 1000)
    }

    static func uuid(_ string: String) -> UUID {
        UUID(uuidString: string) ?? UUID()
    }

    static func key(_ id: UUID) -> String {
        id.uuidString.lowercased()
    }

    static func item(_ row: Row) -> ClipItem {
        let pathsJSON: String? = row["file_paths"]
        let paths = pathsJSON.flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
        return ClipItem(
            id: uuid(row["id"]),
            createdAt: date(row["created_at"]),
            lastUsedAt: date(row["last_used_at"]),
            kind: ContentKind(rawValue: row["kind"]) ?? .other,
            sourceBundleID: row["source_bundle_id"],
            sourceAppName: row["source_app_name"],
            hash: row["hash"],
            byteSize: row["byte_size"],
            oversized: row["oversized"],
            preview: row["preview"],
            width: row["width"],
            height: row["height"],
            filePaths: paths,
            url: row["url"],
            colorHex: row["color_hex"],
            inHistory: row["in_history"],
            promised: row["promised"],
            hasThumbnail: row["has_thumbnail"],
            linkTitle: row["link_title"],
            title: row["title"],
            ocrText: row["ocr_text"]
        )
    }

    static func pinboard(_ row: Row) -> Pinboard {
        Pinboard(
            id: uuid(row["id"]),
            name: row["name"],
            color: PinboardColor(rawValue: row["color"]) ?? .blue,
            icon: row["icon"],
            ordinal: row["ordinal"],
            createdAt: date(row["created_at"]),
            itemCount: row["item_count"] ?? 0
        )
    }

    static func filePathsJSON(_ paths: [String]) -> String? {
        guard !paths.isEmpty, let data = try? JSONEncoder().encode(paths) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
