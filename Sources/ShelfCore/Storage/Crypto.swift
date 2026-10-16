import CryptoKit
import Foundation
import Security

/// Supplies the 256-bit key that seals blobs and thumbnails.
///
/// Rotation is two-phase so a crash halfway through never strands data: the
/// new key is stored as "pending" first, every file is re-sealed while both
/// keys can open it, and only then does the pending key replace the current one.
public protocol BlobKeyProviding: Sendable {
    /// The current key, created and stored on first use.
    func key() throws -> SymmetricKey
    /// The pending key of an unfinished rotation, if any.
    func pendingKey() throws -> SymmetricKey?
    /// Creates and stores a pending key.
    func beginRotation() throws -> SymmetricKey
    /// Makes the pending key current and forgets the old one.
    func commitRotation() throws
}

public enum CryptoError: Error, Equatable {
    case keychain(OSStatus)
    case malformedBlob
    case noPendingKey
}

/// The release key store: generic password items in the login Keychain, which
/// the user's login password protects.
///
/// The login keychain travels with backups and Migration Assistant like any
/// other keychain item; `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` would
/// only keep it on this Mac in the data protection keychain, which needs a
/// signing entitlement Shelf does not have yet. A copied data folder without
/// the keychain holds only ciphertext.
public final class KeychainBlobKeyProvider: BlobKeyProviding, @unchecked Sendable {
    public static let service = Brand.keychainService
    private let service: String
    private let currentAccount = "blobkey"
    private let pendingAccount = "blobkey.pending"
    private let lock = NSLock()
    private var cached: SymmetricKey?

    public init(service: String = KeychainBlobKeyProvider.service) {
        self.service = service
    }

    public func key() throws -> SymmetricKey {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        if let stored = try read(account: currentAccount) {
            cached = stored
            return stored
        }
        let fresh = SymmetricKey(size: .bits256)
        try write(fresh, account: currentAccount)
        cached = fresh
        return fresh
    }

    public func pendingKey() throws -> SymmetricKey? {
        lock.lock()
        defer { lock.unlock() }
        return try read(account: pendingAccount)
    }

    public func beginRotation() throws -> SymmetricKey {
        lock.lock()
        defer { lock.unlock() }
        if let existing = try read(account: pendingAccount) { return existing }
        let fresh = SymmetricKey(size: .bits256)
        try write(fresh, account: pendingAccount)
        return fresh
    }

    public func commitRotation() throws {
        lock.lock()
        defer { lock.unlock() }
        guard let pending = try read(account: pendingAccount) else { throw CryptoError.noPendingKey }
        try write(pending, account: currentAccount)
        delete(account: pendingAccount)
        cached = pending
    }

    private func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func read(account: String) throws -> SymmetricKey? {
        var query = query(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, data.count == 32 else { throw CryptoError.malformedBlob }
            return SymmetricKey(data: data)
        case errSecItemNotFound:
            return nil
        default:
            throw CryptoError.keychain(status)
        }
    }

    private func write(_ key: SymmetricKey, account: String) throws {
        delete(account: account)
        var attributes = query(account: account)
        attributes[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        attributes[kSecAttrLabel as String] = "\(Brand.name) history key"
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw CryptoError.keychain(status) }
    }

    private func delete(account: String) {
        SecItemDelete(query(account: account) as CFDictionary)
    }

    var serviceForTests: String { service }

    func deleteAllForTests() {
        delete(account: currentAccount)
        delete(account: pendingAccount)
    }
}

/// Keys that live only in memory, for tests and previews.
public final class InMemoryBlobKeyProvider: BlobKeyProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var current = SymmetricKey(size: .bits256)
    private var pending: SymmetricKey?

    public init() {}

    public func key() throws -> SymmetricKey {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    public func pendingKey() throws -> SymmetricKey? {
        lock.lock()
        defer { lock.unlock() }
        return pending
    }

    public func beginRotation() throws -> SymmetricKey {
        lock.lock()
        defer { lock.unlock() }
        let fresh = pending ?? SymmetricKey(size: .bits256)
        pending = fresh
        return fresh
    }

    public func commitRotation() throws {
        lock.lock()
        defer { lock.unlock() }
        guard let pending else { throw CryptoError.noPendingKey }
        current = pending
        self.pending = nil
    }
}

/// The on-disk envelope for blobs and thumbnails.
///
/// Every file starts with a 4-byte header so a blob written with encryption
/// off can still be read after the user turns it on, and the other way round:
/// `SHB\0` followed by plain bytes, or `SHB\u{1}` followed by a ChaChaPoly
/// combined box (12-byte nonce, ciphertext, 16-byte tag).
public enum BlobEnvelope {
    static let magic: [UInt8] = [0x53, 0x48, 0x42] // "SHB"
    static let plainTag: UInt8 = 0
    static let sealedTag: UInt8 = 1

    public static func seal(_ data: Data, key: SymmetricKey) throws -> Data {
        let box = try ChaChaPoly.seal(data, using: key)
        var out = Data(magic + [sealedTag])
        out.append(box.combined)
        return out
    }

    public static func plain(_ data: Data) -> Data {
        var out = Data(magic + [plainTag])
        out.append(data)
        return out
    }

    public static func isSealed(_ envelope: Data) -> Bool {
        envelope.count >= 4 && Array(envelope.prefix(3)) == magic && envelope[envelope.startIndex + 3] == sealedTag
    }

    /// Opens an envelope, trying each key in turn; only consulted for sealed files.
    public static func open(_ envelope: Data, keys: () throws -> [SymmetricKey]) throws -> Data {
        guard envelope.count >= 4, Array(envelope.prefix(3)) == magic else { throw CryptoError.malformedBlob }
        let body = envelope.dropFirst(4)
        switch envelope[envelope.startIndex + 3] {
        case plainTag:
            return Data(body)
        case sealedTag:
            let box = try ChaChaPoly.SealedBox(combined: body)
            var lastError: Error = CryptoError.malformedBlob
            for key in try keys() {
                do {
                    return try ChaChaPoly.open(box, using: key)
                } catch {
                    lastError = error
                }
            }
            throw lastError
        default:
            throw CryptoError.malformedBlob
        }
    }
}
