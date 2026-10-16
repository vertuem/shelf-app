import AppKit
import ShelfCore

/// File promises (Finder drags, some Photos and Mail copies) are recorded as a
/// placeholder card, because reading them makes the source app produce the
/// file. On the first paste, if the same promise is still on the pasteboard,
/// it is received into Shelf's folder and the item gets real file URLs.
@MainActor
public enum PromiseResolver {
    public static func resolveIfPossible(_ item: ClipItem, store: Store, pasteboard: NSPasteboard = .general) async -> ClipItem {
        guard item.promised else { return item }
        let snapshot = PasteboardSnapshot.read(from: pasteboard)
        guard ItemBuilder.hash(of: snapshot) == item.hash,
              let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
              !receivers.isEmpty else { return item }

        let destination = store.paths.receivedFiles.appendingPathComponent(item.id.uuidString.lowercased(), isDirectory: true)
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var urls: [URL] = []
        for receiver in receivers where !receiver.fileNames.isEmpty {
            urls += await receive(receiver, into: destination)
        }
        guard !urls.isEmpty else { return item }
        let representations = urls.enumerated().map { index, url in
            ClipRepresentation(itemIndex: index, uti: PasteboardTypes.fileURL, data: Data(url.absoluteString.utf8))
        }
        let paths = urls.map(\.path)
        try? await store.resolvePromise(item.id, representations: representations, filePaths: paths,
                                        preview: paths.map { ($0 as NSString).lastPathComponent }.joined(separator: "\n"))
        return (try? await store.item(item.id)) ?? item
    }

    /// How long a source app gets to deliver promised files before the paste
    /// goes ahead with the placeholder.
    static let timeout: Duration = .seconds(10)

    /// Waits for every file of one promise, or the timeout; failed files are left out.
    private static func receive(_ receiver: NSFilePromiseReceiver, into destination: URL) async -> [URL] {
        let expected = receiver.fileNames.count
        return await withCheckedContinuation { continuation in
            var received: [URL] = []
            var answered = 0
            var finished = false
            func finish() {
                guard !finished else { return }
                finished = true
                continuation.resume(returning: received)
            }
            receiver.receivePromisedFiles(atDestination: destination, options: [:], operationQueue: .main) { url, error in
                MainActor.assumeIsolated {
                    answered += 1
                    if error == nil { received.append(url) }
                    if answered == expected { finish() }
                }
            }
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                finish()
            }
        }
    }
}
