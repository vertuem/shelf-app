import Foundation

/// Where Shelf keeps its data: `~/Library/Application Support/Shelf/`.
///
/// ```
/// shelf.sqlite                  metadata and search index
/// blobs/<item-id>/<n>-<type>.bin   one file per pasteboard type
/// thumbs/<item-id>.heic            512 px thumbnails
/// ```
///
/// The directory is created with mode 0700 so other local users cannot list it.
public struct AppPaths: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// The real location. Dev builds use a separate folder so they never touch release data.
    public static func standard(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> AppPaths {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let isDev = bundleIdentifier?.hasSuffix(".dev") ?? true
        let folder = isDev ? "\(Brand.name) Dev" : Brand.name
        return AppPaths(root: base.appendingPathComponent(folder, isDirectory: true))
    }

    /// A throwaway location for tests.
    public static func temporary() -> AppPaths {
        AppPaths(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("ShelfTests-\(UUID().uuidString)", isDirectory: true))
    }

    public var database: URL { root.appendingPathComponent("\(Brand.slug).sqlite") }
    public var blobs: URL { root.appendingPathComponent("blobs", isDirectory: true) }
    public var thumbs: URL { root.appendingPathComponent("thumbs", isDirectory: true) }
    public var backups: URL { root.appendingPathComponent("Backups", isDirectory: true) }
    /// Files delivered by file promises when a pending-file card is pasted.
    public var receivedFiles: URL { root.appendingPathComponent("Received Files", isDirectory: true) }

    public func blobDirectory(for itemID: UUID) -> URL {
        blobs.appendingPathComponent(itemID.uuidString.lowercased(), isDirectory: true)
    }

    public func thumbnail(for itemID: UUID) -> URL {
        thumbs.appendingPathComponent("\(itemID.uuidString.lowercased()).heic")
    }

    /// Creates the folders with owner-only permissions. Safe to call repeatedly.
    public func prepare() throws {
        let fileManager = FileManager.default
        let attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        for url in [root, blobs, thumbs] {
            if !fileManager.fileExists(atPath: url.path) {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: attributes)
            }
            try fileManager.setAttributes(attributes, ofItemAtPath: url.path)
        }
    }
}

extension FileManager {
    /// Deletes a file or folder if it exists. Never throws; for cleanup in `defer`.
    public func removeIfPresent(_ url: URL) {
        guard fileExists(atPath: url.path) else { return }
        do { try removeItem(at: url) } catch {}
    }
}
