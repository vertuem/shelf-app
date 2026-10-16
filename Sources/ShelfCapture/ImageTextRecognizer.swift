import Foundation
import ShelfCore
import Vision

/// On-device text recognition for copied images, so screenshots and photos of
/// notes turn up in search.
///
/// On by default: Vision runs on this Mac and nothing
/// leaves it. Each new image item is recognized once, from the full-size data
/// when it was stored and from the 512 px thumbnail otherwise, and the text
/// goes into the search index through `Store.setOCRText`. Items are handled
/// one at a time in capture order, so a burst of screenshots never runs
/// several Vision requests at once. The recognized text is never logged.
@MainActor
public final class ImageTextRecognizer {
    /// Recognized text is cut here before storage: plenty for a dense
    /// screenshot, bounded for the search index.
    public nonisolated static let maxCharacters = 4_000

    private let store: Store
    private let preferences: Preferences
    private var task: Task<Void, Never>?

    public init(store: Store, preferences: Preferences) {
        self.store = store
        self.preferences = preferences
    }

    public func start() {
        guard task == nil else { return }
        // Subscribe before the task runs, so a copy recorded right after
        // `start()` is never missed.
        let events = store.events()
        task = Task { [weak self] in
            for await event in events {
                guard case .captured(let item, true) = event, item.kind == .image else { continue }
                await self?.recognizeIfAllowed(item)
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    func recognizeIfAllowed(_ item: ClipItem) async {
        guard preferences.recognizeTextInImages, let data = await imageData(for: item) else { return }
        guard let text = await Self.recognize(in: data) else { return }
        try? await store.setOCRText(item.id, text: text)
    }

    /// The full-size image when it was stored, else the thumbnail. Oversized
    /// items keep only their small types, so they are read from the thumbnail
    /// and skipped when there is none.
    private func imageData(for item: ClipItem) async -> Data? {
        if !item.oversized, let representations = try? await store.representations(for: item.id) {
            for type in PasteboardTypes.imageTypes {
                if let full = representations.first(where: { $0.uti == type }) { return full.data }
            }
        }
        return store.thumbnail(for: item.id)
    }

    /// Runs Vision off the main thread. Nil when nothing was recognized.
    nonisolated static func recognize(in data: Data) async -> String? {
        await Task.detached(priority: .utility) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            let handler = VNImageRequestHandler(data: data, options: [:])
            do {
                try handler.perform([request])
            } catch {
                Log.capture.debug("Text recognition failed: \(String(describing: type(of: error)), privacy: .public)")
                return nil
            }
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            let text = redactingSecrets(lines).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return String(text.prefix(maxCharacters))
        }.value
    }

    /// A screenshot can show a password field or an API key. The OCR text is
    /// stored unencrypted for search, so tokens that look like secrets are
    /// dropped before storage, whatever the "Detect secrets" setting says: a
    /// false positive only costs one word in the index.
    nonisolated static func redactingSecrets(_ lines: [String]) -> [String] {
        lines.map { line in
            line.split(separator: " ", omittingEmptySubsequences: false)
                .map { token in SecretDetector.looksLikeSecret(String(token)) ? "" : String(token) }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
        }
        .filter { !$0.isEmpty }
    }
}
