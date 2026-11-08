import CoreGraphics
import CoreImage
import CryptoKit
import Foundation
import ImageIO

/// Pixel dimensions after applying EXIF orientation, not SwiftUI points.
nonisolated struct ReaderImageDimensions: Codable, Equatable, Sendable {
    let width: Int
    let height: Int

    var label: String { "\(width) × \(height)" }
    var pixels: Int64 { Int64(width) * Int64(height) }

    static func read(from data: Data) throws -> ReaderImageDimensions {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.intValue > 0, height.intValue > 0,
              width.intValue <= 1_000_000, height.intValue <= 1_000_000 else {
            throw ReaderImageSourceError.invalidImage
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let swapsAxes = (5...8).contains(orientation)
        return ReaderImageDimensions(
            width: swapsAxes ? height.intValue : width.intValue,
            height: swapsAxes ? width.intValue : height.intValue
        )
    }
}

nonisolated enum ReaderImageSourceError: LocalizedError {
    case invalidImage
    case budgetExceeded
    case cannotUnscramble

    var errorDescription: String? {
        switch self {
        case .invalidImage: "无法读取原图像素。"
        case .budgetExceeded: "原图超出本轮对比的像素、编码大小或解码内存预算（最多 1200 万像素、单边 16384）；已跳过，原图未修改。"
        case .cannotUnscramble: "JM 原图重排失败，未将未解密的图片送入模型。"
        }
    }
}

/// A single immutable source snapshot shared by both sides of the comparison.
/// Never stores the traditional enhancement or a screen-width thumbnail.
nonisolated struct ReaderImageSource: @unchecked Sendable {
    let image: CGImage
    let dimensions: ReaderImageDimensions
    let fingerprint: String
}

nonisolated enum ReaderImageSourceLoader {
    static let maximumPixels: Int64 = 12_000_000
    static let maximumSide = 16_384
    static let maximumEncodedBytes = 64 * 1024 * 1024

    static func load(url: URL) async throws -> ReaderImageSource {
        var data = try await ImageCacheService.data(for: url)
        try Task.checkCancellation()
        do {
            return try await decodeOffMain(data: data, url: url)
        } catch let error as ReaderImageSourceError {
            // A resource or JM failure is not a corrupt network cache. Do not redownload it.
            guard case .invalidImage = error, url.picaxLocalFileURL == nil else { throw error }
            ImageCacheService.removeCachedImageData(for: url)
            data = try await ImageCacheService.data(for: url, storesInCache: false)
            let source = try await decodeOffMain(data: data, url: url)
            ImageCacheService.storeDecodedImageData(data, for: url)
            return source
        }
    }

    private static func decodeOffMain(data: Data, url: URL) async throws -> ReaderImageSource {
        let task = Task.detached(priority: .userInitiated) { try decode(data: data, url: url) }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    static func decode(data: Data, url: URL) throws -> ReaderImageSource {
        try Task.checkCancellation()
        guard data.count <= maximumEncodedBytes else { throw ReaderImageSourceError.budgetExceeded }
        let size = try ReaderImageDimensions.read(from: data)
        try validate(dimensions: size)
        guard let encodedSource = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ReaderImageSourceError.invalidImage
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(encodedSource, 0, nil) as? [CFString: Any]
        let depth = (properties?[kCGImagePropertyDepth] as? NSNumber)?.intValue ?? 8
        guard depth > 0, depth <= 16 else { throw ReaderImageSourceError.budgetExceeded }
        // JM keeps source and destination rasters during reordering; account
        // for those copies before invoking its original-size decoder.
        let bytesPerPixel: Int64 = JmImageScrambler.requiresReordering(url: url) ? 24 : 12
        guard size.pixels * bytesPerPixel + Int64(data.count) <= 256 * 1024 * 1024 else {
            throw ReaderImageSourceError.budgetExceeded
        }
        let image: CGImage
        if let reordered = try JmImageScrambler.sourceImage(data: data, url: url) {
            let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.int32Value ?? 1
            if orientation == 1 {
                image = reordered
            } else {
                let oriented = CIImage(cgImage: reordered).oriented(forExifOrientation: orientation)
                guard let normalized = CIContext(options: [.cacheIntermediates: false]).createCGImage(
                    oriented, from: oriented.extent, format: .RGBA8,
                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
                ) else { throw ReaderImageSourceError.invalidImage }
                image = normalized
            }
        } else {
            guard let normalized = CGImageSourceCreateThumbnailAtIndex(encodedSource, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(size.width, size.height)
                  ] as CFDictionary) else { throw ReaderImageSourceError.invalidImage }
            image = normalized
        }
        try Task.checkCancellation()
        guard image.width == size.width, image.height == size.height else {
            throw ReaderImageSourceError.invalidImage
        }
        return ReaderImageSource(
            image: image,
            dimensions: size,
            fingerprint: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        )
    }

    static func validate(dimensions: ReaderImageDimensions) throws {
        guard dimensions.width > 0, dimensions.height > 0,
              dimensions.width <= maximumSide, dimensions.height <= maximumSide,
              dimensions.pixels <= maximumPixels else {
            throw ReaderImageSourceError.budgetExceeded
        }
    }

    /// Reproduce the reader's bounded traditional display path from the exact
    /// same source snapshot used by the AI comparison, without a second fetch.
    static func traditionalImage(
        source: ReaderImageSource, targetPixelWidth: Int?, enhancement: ReaderImageEnhancement
    ) throws -> CGImage {
        let width = displayPixelWidth(dimensions: source.dimensions, targetPixelWidth: targetPixelWidth, enhancement: enhancement)
        let decoded: CGImage
        if width < source.image.width {
            let height = max(1, Int((Double(width) * Double(source.image.height) / Double(source.image.width)).rounded(.up)))
            guard let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { throw ReaderImageSourceError.budgetExceeded }
            context.interpolationQuality = .high
            context.draw(source.image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            guard let image = context.makeImage() else { throw ReaderImageSourceError.invalidImage }
            decoded = image
        } else { decoded = source.image }
        return ImageEnhancementService.enhancedImage(
            cgImage: decoded, targetPixelWidth: targetPixelWidth, enhancement: enhancement
        ) ?? decoded
    }

    /// Decode at the final demand, not screen width followed by Lanczos.
    static func displayPixelWidth(
        dimensions: ReaderImageDimensions,
        targetPixelWidth: Int?,
        enhancement: ReaderImageEnhancement
    ) -> Int {
        let multiplier = enhancement.mode.usesUpscale ? enhancement.scale : 1
        let demand = targetPixelWidth.map { Double(max($0, 1)) * multiplier } ?? Double(dimensions.width)
        var width = min(Double(dimensions.width), demand, 8192)
        width = min(width, 8192 * Double(dimensions.width) / Double(dimensions.height))
        let pixels = width * width * Double(dimensions.height) / Double(dimensions.width)
        if pixels > 16_000_000 { width *= (16_000_000 / pixels).squareRoot() }
        return max(1, Int(width.rounded(.down)))
    }

}
