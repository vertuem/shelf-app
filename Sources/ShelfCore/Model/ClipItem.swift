import Foundation

/// One entry in the clipboard history, as the UI sees it.
///
/// Holds metadata only. Payloads live in the `BlobStore` and are loaded on
/// paste, so a `ClipItem` is cheap to keep in memory by the thousand.
public struct ClipItem: Sendable, Identifiable, Hashable {
    public let id: UUID
    public var createdAt: Date
    public var lastUsedAt: Date
    public var kind: ContentKind
    public var sourceBundleID: String?
    public var sourceAppName: String?
    public var hash: Data
    public var byteSize: Int
    /// Above the size limit: only metadata, small types and a thumbnail were kept.
    public var oversized: Bool
    /// First 500 characters, whitespace normalized. Stored unencrypted for search.
    public var preview: String
    public var width: Int?
    public var height: Int?
    public var filePaths: [String]
    public var url: String?
    public var colorHex: String?
    /// False once the item was removed from the Clipboard tab but survives in a pinboard.
    public var inHistory: Bool
    /// A promised file whose data was not delivered yet (Finder drags, file promises).
    public var promised: Bool
    public var hasThumbnail: Bool
    /// Title fetched by the opt-in link preview.
    public var linkTitle: String?
    /// A name the user gave the item (Rename), shown in the header instead of the kind.
    public var title: String?
    /// Text recognized inside an image, for search. Not shown on the card.
    public var ocrText: String?

    public init(
        id: UUID,
        createdAt: Date,
        lastUsedAt: Date,
        kind: ContentKind,
        sourceBundleID: String? = nil,
        sourceAppName: String? = nil,
        hash: Data,
        byteSize: Int,
        oversized: Bool = false,
        preview: String = "",
        width: Int? = nil,
        height: Int? = nil,
        filePaths: [String] = [],
        url: String? = nil,
        colorHex: String? = nil,
        inHistory: Bool = true,
        promised: Bool = false,
        hasThumbnail: Bool = false,
        linkTitle: String? = nil,
        title: String? = nil,
        ocrText: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.kind = kind
        self.sourceBundleID = sourceBundleID
        self.sourceAppName = sourceAppName
        self.hash = hash
        self.byteSize = byteSize
        self.oversized = oversized
        self.preview = preview
        self.width = width
        self.height = height
        self.filePaths = filePaths
        self.url = url
        self.colorHex = colorHex
        self.inHistory = inHistory
        self.promised = promised
        self.hasThumbnail = hasThumbnail
        self.linkTitle = linkTitle
        self.title = title
        self.ocrText = ocrText
    }

    /// Number of characters in the preview, for the card footer.
    public var characterCount: Int { preview.count }

    /// The host of `url`, for link cards and the footer.
    public var host: String? {
        guard let url, let components = URLComponents(string: url) else { return nil }
        return components.host
    }

    /// Paths that point at files which no longer exist get a broken-file badge.
    public var missingFiles: Bool {
        guard kind == .file, !filePaths.isEmpty else { return false }
        return filePaths.contains { !FileManager.default.fileExists(atPath: $0) }
    }
}

// Crash reports, logs and debugger output must never contain clipboard data.
// Only the id and kind are printed, whatever the caller asks for.
extension ClipItem: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "ClipItem(\(id.uuidString), \(kind.rawValue))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["id": id, "kind": kind], displayStyle: .struct)
    }
}

/// One pasteboard type of one pasteboard item, with its bytes.
public struct ClipRepresentation: Sendable, Hashable {
    /// Index of the `NSPasteboardItem` this type belongs to; multi-file copies have several.
    public var itemIndex: Int
    public var uti: String
    public var data: Data

    public init(itemIndex: Int = 0, uti: String, data: Data) {
        self.itemIndex = itemIndex
        self.uti = uti
        self.data = data
    }
}

extension ClipRepresentation: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "ClipRepresentation(\(itemIndex), \(uti), \(data.count) bytes)" }
    public var debugDescription: String { description }
}

/// Everything the capture engine hands to the store for one copy.
public struct CapturedItem: Sendable {
    public var capturedAt: Date
    public var kind: ContentKind
    public var sourceBundleID: String?
    public var sourceAppName: String?
    public var hash: Data
    public var byteSize: Int
    public var oversized: Bool
    public var preview: String
    public var width: Int?
    public var height: Int?
    public var filePaths: [String]
    public var url: String?
    public var colorHex: String?
    public var promised: Bool
    /// The types to store. Empty types of oversized items were dropped.
    public var representations: [ClipRepresentation]
    /// HEIC thumbnail, at most 512 px on the long side.
    public var thumbnail: Data?

    public init(
        capturedAt: Date = Date(),
        kind: ContentKind,
        sourceBundleID: String? = nil,
        sourceAppName: String? = nil,
        hash: Data,
        byteSize: Int,
        oversized: Bool = false,
        preview: String = "",
        width: Int? = nil,
        height: Int? = nil,
        filePaths: [String] = [],
        url: String? = nil,
        colorHex: String? = nil,
        promised: Bool = false,
        representations: [ClipRepresentation],
        thumbnail: Data? = nil
    ) {
        self.capturedAt = capturedAt
        self.kind = kind
        self.sourceBundleID = sourceBundleID
        self.sourceAppName = sourceAppName
        self.hash = hash
        self.byteSize = byteSize
        self.oversized = oversized
        self.preview = preview
        self.width = width
        self.height = height
        self.filePaths = filePaths
        self.url = url
        self.colorHex = colorHex
        self.promised = promised
        self.representations = representations
        self.thumbnail = thumbnail
    }
}

extension CapturedItem: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "CapturedItem(\(kind.rawValue), \(representations.count) types)" }
    public var debugDescription: String { description }
}
