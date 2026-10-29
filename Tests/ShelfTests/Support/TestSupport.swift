import CryptoKit
import Foundation
import ShelfCore
import XCTest

/// A store in a temporary folder with an in-memory key and its own defaults suite.
struct TestEnvironment {
    let paths: AppPaths
    let defaults: UserDefaults
    let preferences: Preferences
    let keys: InMemoryBlobKeyProvider
    let store: Store

    init(hardCap: Int = RetentionPeriod.hardCapUnpinnedItems) {
        paths = AppPaths.temporary()
        let suite = "ShelfTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        preferences = Preferences(defaults: defaults)
        keys = InMemoryBlobKeyProvider()
        store = Store(paths: paths, keyProvider: keys, preferences: preferences, hardCap: hardCap)
    }

    func cleanUp() {
        removeIfPresent(paths.root)
    }
}

/// Deletes a file or folder if it exists. Never throws, so it is safe in `defer`.
func removeIfPresent(_ url: URL) {
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    do { try FileManager.default.removeItem(at: url) } catch {}
}

enum Make {
    static func text(_ text: String, app: String = "Notes", bundleID: String = "com.apple.Notes", at date: Date = Date()) -> CapturedItem {
        let data = Data(text.utf8)
        return CapturedItem(
            capturedAt: date,
            kind: .text,
            sourceBundleID: bundleID,
            sourceAppName: app,
            hash: Data(SHA.digest(data)),
            byteSize: data.count,
            preview: TextPreview.make(text),
            representations: [ClipRepresentation(uti: "public.utf8-plain-text", data: data)]
        )
    }

    static func image(at date: Date = Date(), app: String = "Preview", seed: Int = 0) -> CapturedItem {
        let data = Data((0..<64).map { UInt8(($0 + seed) % 256) })
        return CapturedItem(
            capturedAt: date,
            kind: .image,
            sourceBundleID: "com.apple.Preview",
            sourceAppName: app,
            hash: Data(SHA.digest(data)),
            byteSize: data.count,
            width: 640,
            height: 480,
            representations: [ClipRepresentation(uti: "public.png", data: data)],
            thumbnail: Data([1, 2, 3])
        )
    }
}

enum SHA {
    static func digest(_ data: Data) -> SHA256.Digest { SHA256.hash(data: data) }
}

@MainActor
extension XCTestCase {
    /// Polls until `condition` holds or the timeout passes.
    func wait(timeout: TimeInterval = 2, _ condition: @escaping @MainActor () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }
}
