import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A small JPEG preview that Telegram shows on a file message, so the channel can be browsed by eye.
/// The file itself is still sent untouched; only the preview is shrunk.
struct DocumentThumbnail: Equatable {
    let url: URL
    let width: Int
    let height: Int

    /// Telegram asks for thumbnails of at most 320 points on the long side and under 200 KB.
    static let maximumSide = 320
    static let maximumBytes = 200 * 1024

    /// Writes `preview.jpg` into `directory` for a photo or video, or returns `nil` for anything else
    /// or if no preview could be made. A missing preview never stops an upload.
    static func make(for fileURL: URL, in directory: URL) async -> DocumentThumbnail? {
        let type = UTType(filenameExtension: fileURL.pathExtension)
        let image: CGImage?
        if type?.conforms(to: .movie) == true {
            image = await videoFrame(of: fileURL)
        } else if type?.conforms(to: .image) == true {
            image = imageThumbnail(of: fileURL)
        } else {
            return nil
        }
        guard let image else { return nil }
        return write(image, to: directory.appendingPathComponent("preview.jpg"))
    }

    private static func imageThumbnail(of url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumSide,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func videoFrame(of url: URL) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maximumSide, height: maximumSide)
        return try? await generator.image(at: .zero).image
    }

    /// Saves the image as a JPEG, lowering the quality until it fits Telegram's size limit.
    private static func write(_ image: CGImage, to url: URL) -> DocumentThumbnail? {
        for quality in [0.7, 0.5, 0.3] {
            guard
                let destination = CGImageDestinationCreateWithURL(
                    url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
            else { return nil }
            let options = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
            CGImageDestinationAddImage(destination, image, options)
            guard CGImageDestinationFinalize(destination) else { return nil }
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            if let size = attributes?[.size] as? Int, size <= maximumBytes {
                return DocumentThumbnail(url: url, width: image.width, height: image.height)
            }
        }
        try? FileManager.default.removeItem(at: url)
        return nil
    }
}
