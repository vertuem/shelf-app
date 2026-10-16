import CoreGraphics
import Foundation
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Makes the 512 px HEIC thumbnails shown on image and file cards.
///
/// Images are downsampled by ImageIO straight from the encoded bytes, so a
/// 5 MB photo is never fully decoded. HEIC halves the size of PNG thumbnails
/// on Apple silicon, which has a hardware encoder.
public enum Thumbnailer {
    public static let maxPixelSize = 512

    public struct ImageInfo: Sendable, Equatable {
        public var width: Int
        public var height: Int
    }

    /// Pixel dimensions without decoding the image.
    public static func info(of data: Data) -> ImageInfo? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        // EXIF orientations 5 to 8 are rotated by 90 degrees.
        return orientation >= 5 ? ImageInfo(width: height, height: width) : ImageInfo(width: width, height: height)
    }

    /// A HEIC thumbnail of encoded image data (PNG, TIFF, JPEG, HEIC, PDF, …).
    public static func thumbnail(of data: Data, maxPixelSize: Int = maxPixelSize) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return encode(image)
    }

    /// A Quick Look thumbnail of a file on disk, for file cards. Nil when Quick Look has none.
    public static func thumbnail(ofFileAt url: URL) async -> Data? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 256, height: 256),
            scale: 2,
            representationTypes: .thumbnail
        )
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        return encode(representation.cgImage)
    }

    /// Encodes as HEIC, falling back to JPEG if the encoder is unavailable.
    public static func encode(_ image: CGImage) -> Data? {
        for type in [UTType.heic, UTType.jpeg] {
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
            if CGImageDestinationFinalize(destination) {
                return output as Data
            }
        }
        return nil
    }
}
