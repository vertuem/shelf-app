import Foundation
import ShelfCore

/// One GitHub release, as returned by the REST API.
struct Release: Decodable, Sendable, Equatable, Identifiable {
    var tagName: String
    var name: String?
    var body: String?
    var prerelease: Bool
    var draft: Bool
    var publishedAt: Date?
    var htmlURL: URL
    var assets: [Asset]

    var id: String { tagName }

    struct Asset: Decodable, Sendable, Equatable {
        var name: String
        var browserDownloadURL: URL
        var size: Int

        enum CodingKeys: String, CodingKey {
            case name, size, browserDownloadURL = "browser_download_url"
        }
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name", name, body, prerelease, draft
        case publishedAt = "published_at", htmlURL = "html_url", assets
    }

    var version: SemanticVersion? { SemanticVersion(tagName) }
    var dmg: Asset? { assets.first { $0.name.lowercased().hasSuffix(".dmg") } }
    var checksums: Asset? { assets.first { $0.name.uppercased().contains("SHA256") } }

    static func decodeList(_ data: Data) throws -> [Release] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([Release].self, from: data)
    }
}

/// Which release, if any, to offer. Pure, so the rules are unit-tested.
enum UpdatePolicy {
    /// Automatic checks wait this long after a release; manual checks do not.
    static let stabilityBuffer: TimeInterval = 3 * 86_400

    static func candidate(
        from releases: [Release],
        current: SemanticVersion,
        includeBetas: Bool,
        applyStabilityBuffer: Bool,
        skippedVersion: String?,
        now: Date = Date()
    ) -> Release? {
        releases
            .filter { release in
                guard !release.draft, release.dmg != nil, let version = release.version, version > current else { return false }
                if release.prerelease || version.isPrerelease, !includeBetas { return false }
                if let skippedVersion, release.tagName == skippedVersion { return false }
                if applyStabilityBuffer, let published = release.publishedAt, now.timeIntervalSince(published) < stabilityBuffer {
                    return false
                }
                return true
            }
            .max { ($0.version ?? current) < ($1.version ?? current) }
    }

    /// The sum for one file in `shasum -a 256` output ("<hex>  <name>").
    static func expectedChecksum(in sums: String, for fileName: String) -> String? {
        for line in sums.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 2, parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "*")) == fileName else { continue }
            let hex = parts[0].lowercased()
            return hex.count == 64 && hex.allSatisfy(\.isHexDigit) ? hex : nil
        }
        return nil
    }

    /// Downloads are only accepted over HTTPS from GitHub.
    static func isTrustedDownloadURL(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "github.com" || host.hasSuffix(".githubusercontent.com")
    }
}
