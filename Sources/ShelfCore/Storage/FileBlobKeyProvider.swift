import CryptoKit
import Foundation

/// The key store for development builds only: a 0600 file in the dev data folder.
///
/// Ad-hoc signed builds get a new code signature on every compile, and the
/// Keychain would then ask for permission on every launch. Development data is
/// separate from release data (`Shelf Dev`), so a file key is acceptable
/// there; release builds always use `KeychainBlobKeyProvider`.
public final class FileBlobKeyProvider: BlobKeyProviding, @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()

    public init(directory: URL) {
        self.directory = directory
    }

    private var currentURL: URL { directory.appendingPathComponent("dev-blob.key") }
    private var pendingURL: URL { directory.appendingPathComponent("dev-blob.pending.key") }

    public func key() throws -> SymmetricKey {
        lock.lock()
        defer { lock.unlock() }
        if let data = try? Data(contentsOf: currentURL), data.count == 32 { return SymmetricKey(data: data) }
        let fresh = SymmetricKey(size: .bits256)
        try write(fresh, to: currentURL)
        return fresh
    }

    public func pendingKey() throws -> SymmetricKey? {
        lock.lock()
        defer { lock.unlock() }
        return (try? Data(contentsOf: pendingURL)).flatMap { $0.count == 32 ? SymmetricKey(data: $0) : nil }
    }

    public func beginRotation() throws -> SymmetricKey {
        lock.lock()
        defer { lock.unlock() }
        if let data = try? Data(contentsOf: pendingURL), data.count == 32 { return SymmetricKey(data: data) }
        let fresh = SymmetricKey(size: .bits256)
        try write(fresh, to: pendingURL)
        return fresh
    }

    public func commitRotation() throws {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: pendingURL.path) else { throw CryptoError.noPendingKey }
        _ = try FileManager.default.replaceItemAt(currentURL, withItemAt: pendingURL)
    }

    private func write(_ key: SymmetricKey, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try key.withUnsafeBytes { Data($0) }.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
