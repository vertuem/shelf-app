import CryptoKit
import Foundation

/// Reads and writes payload files: one per pasteboard type, plus a thumbnail.
///
/// Safe to use from any thread. File names carry no clipboard content: the
/// directory is the item id and the file name is the type identifier.
public final class BlobStore: Sendable {
    public let paths: AppPaths
    private let keyProvider: any BlobKeyProviding
    private let shouldEncrypt: @Sendable () -> Bool

    public init(paths: AppPaths, keyProvider: any BlobKeyProviding, shouldEncrypt: @escaping @Sendable () -> Bool) {
        self.paths = paths
        self.keyProvider = keyProvider
        self.shouldEncrypt = shouldEncrypt
    }

    /// Writes every representation and returns the relative path of each, in order.
    public func write(_ representations: [ClipRepresentation], for itemID: UUID) throws -> [String] {
        let directory = paths.blobDirectory(for: itemID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var relativePaths: [String] = []
        for (ordinal, representation) in representations.enumerated() {
            let name = "\(representation.itemIndex)-\(ordinal)-\(Self.slug(for: representation.uti)).bin"
            let url = directory.appendingPathComponent(name)
            try envelope(for: representation.data).write(to: url, options: [.atomic])
            relativePaths.append("\(itemID.uuidString.lowercased())/\(name)")
        }
        return relativePaths
    }

    public func read(relativePath: String) throws -> Data {
        let envelope = try Data(contentsOf: paths.blobs.appendingPathComponent(relativePath))
        return try BlobEnvelope.open(envelope, keys: openingKeys)
    }

    public func writeThumbnail(_ data: Data, for itemID: UUID) throws {
        try envelope(for: data).write(to: paths.thumbnail(for: itemID), options: [.atomic])
    }

    public func readThumbnail(for itemID: UUID) -> Data? {
        guard let envelope = try? Data(contentsOf: paths.thumbnail(for: itemID)) else { return nil }
        return try? BlobEnvelope.open(envelope, keys: openingKeys)
    }

    public func removeFiles(for itemID: UUID) {
        let fileManager = FileManager.default
        fileManager.removeIfPresent(paths.blobDirectory(for: itemID))
        fileManager.removeIfPresent(paths.thumbnail(for: itemID))
        fileManager.removeIfPresent(paths.receivedFiles.appendingPathComponent(itemID.uuidString.lowercased()))
    }

    /// Deletes every blob and thumbnail. Used by "Erase history".
    public func removeAll() throws {
        let fileManager = FileManager.default
        for directory in [paths.blobs, paths.thumbs, paths.receivedFiles] {
            if fileManager.fileExists(atPath: directory.path) {
                try fileManager.removeItem(at: directory)
            }
        }
        try paths.prepare()
    }

    /// Rotates the encryption key: re-seals every remaining file under a new key,
    /// then makes that key current. Resumable: if the app dies halfway, both keys
    /// still open every file and the next call finishes the job.
    public func rotateKey() throws {
        let newKey = try keyProvider.beginRotation()
        let fileManager = FileManager.default
        for directory in [paths.blobs, paths.thumbs] {
            guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
            for case let url as URL in enumerator where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                let envelope = try Data(contentsOf: url)
                guard BlobEnvelope.isSealed(envelope) else { continue }
                let plain = try BlobEnvelope.open(envelope, keys: openingKeys)
                try BlobEnvelope.seal(plain, key: newKey).write(to: url, options: [.atomic])
            }
        }
        try keyProvider.commitRotation()
    }

    /// Finishes a rotation interrupted by a crash or a quit.
    public func finishInterruptedRotation() throws {
        if try keyProvider.pendingKey() != nil {
            try rotateKey()
        }
    }

    /// Total bytes used by blobs and thumbnails, for the disk usage row in Settings.
    public func diskUsage() -> Int64 {
        var total: Int64 = 0
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        for directory in [paths.blobs, paths.thumbs] {
            guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { continue }
            for case let url as URL in enumerator {
                let values = try? url.resourceValues(forKeys: Set(keys))
                if values?.isRegularFile == true {
                    total += Int64(values?.totalFileAllocatedSize ?? 0)
                }
            }
        }
        return total
    }

    private func openingKeys() throws -> [SymmetricKey] {
        var keys = [try keyProvider.key()]
        if let pending = try keyProvider.pendingKey() { keys.append(pending) }
        return keys
    }

    private func envelope(for data: Data) throws -> Data {
        shouldEncrypt() ? try BlobEnvelope.seal(data, key: keyProvider.key()) : BlobEnvelope.plain(data)
    }

    /// `public.utf8-plain-text` becomes `public_utf8-plain-text`; long dynamic types are truncated.
    static func slug(for uti: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        let mapped = uti.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        return String(String(mapped).prefix(80))
    }
}
