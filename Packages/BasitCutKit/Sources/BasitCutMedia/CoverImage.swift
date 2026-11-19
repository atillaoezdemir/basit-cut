import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import BasitCutCore

/// The project's cover: the chosen source frame, framed and cropped exactly
/// like the video, as a JPEG for the exported file's artwork.
///
/// Only the frame reference is stored in the project; the image is rendered
/// when needed, so it always matches the current crop.
public enum CoverImage {
    /// Longest side of the rendered cover.
    public static let maxDimension: CGFloat = 1920

    /// The cover frame rendered like the video (fitted into the canvas, then
    /// cropped), or nil if the project has no cover or its source isn't available.
    public static func render(
        project: Project,
        assets: [MediaSource.ID: AVAsset],
        maxDimension: CGFloat = maxDimension
    ) async throws -> CGImage? {
        guard let cover = project.cover,
              let source = project.source(id: cover.sourceID),
              let asset = assets[cover.sourceID],
              let canvas = project.canvasSize?.cgSize,
              let crop = project.cropRect
        else { return nil }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (frame, _) = try await generator.image(at: cover.time.cmTime)

        // Where the upright frame sits in the canvas (top-left origin), as in
        // CompositionBuilder.layerTransform.
        let oriented = source.orientedSize.cgSize
        let fit = min(canvas.width / oriented.width, canvas.height / oriented.height)
        let placed = CGRect(
            x: (canvas.width - oriented.width * fit) / 2 - crop.x,
            y: (canvas.height - oriented.height * fit) / 2 - crop.y,
            width: oriented.width * fit,
            height: oriented.height * fit
        )

        let scale = min(1, maxDimension / max(crop.width, crop.height))
        let width = Int((crop.width * scale).rounded()), height = Int((crop.height * scale).rounded())
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        // CoreGraphics has its origin at the bottom left.
        context.scaleBy(x: scale, y: scale)
        context.draw(frame, in: CGRect(
            x: placed.minX, y: crop.height - placed.maxY, width: placed.width, height: placed.height
        ))
        return context.makeImage()
    }

    public static func jpegData(_ image: CGImage, quality: Double = 0.85) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// The cover as an artwork metadata item for a QuickTime movie.
    static func artworkItem(jpeg: Data) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = .quickTimeMetadataArtwork
        item.value = jpeg as NSData
        item.dataType = kCMMetadataBaseDataType_JPEG as String
        return item
    }
}
