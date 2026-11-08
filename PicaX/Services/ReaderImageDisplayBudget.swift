import Foundation

nonisolated enum ReaderImageDisplayError: LocalizedError {
    case budgetExceeded

    var errorDescription: String? {
        "图片超出普通阅读的解码内存预算，无法安全载入；原图未修改。"
    }
}

/// Ordinary reading and full-resolution AI snapshots have different budgets.
/// A long image does not need an 8192px-long thumbnail just because Core Image
/// enhancement and AI have stricter limits. Extreme pages still downsample.
nonisolated enum ReaderImageDisplayBudget {
    static let maximumPixels = 24_000_000.0 // at most ~96 MB per RGBA display raster
    static let maximumWidth = 8192.0
    static let maximumLongSide = 65_536

    static func pixelWidth(
        dimensions: ReaderImageDimensions,
        targetPixelWidth: Int?,
        enhancement: ReaderImageEnhancement
    ) -> Int {
        guard dimensions.width > 0, dimensions.height > 0 else { return 1 }
        let sourceWidth = Double(dimensions.width)
        let aspect = Double(dimensions.height) / sourceWidth
        let multiplier = enhancement.mode.usesUpscale ? enhancement.scale : 1
        let demand = targetPixelWidth.map { Double(max($0, 1)) * multiplier } ?? sourceWidth
        var width = min(sourceWidth, demand, maximumWidth, Double(maximumLongSide) / aspect)
        let pixels = width * width * aspect
        if pixels > maximumPixels { width *= (maximumPixels / pixels).squareRoot() }
        return max(1, Int(width.rounded(.down)))
    }

    /// The display JM path retains the source decoder and one bounded output,
    /// not several original-size byte arrays. Reserve conservatively for a
    /// 16-bit source, output snapshots, encoded bytes and decoder bookkeeping.
    /// This is an allocation policy, not a measured process-memory ceiling.
    static func validateJM(
        dimensions: ReaderImageDimensions,
        encodedByteCount: Int,
        targetPixelWidth: Int
    ) throws {
        guard dimensions.width > 0, dimensions.height > 0,
              dimensions.width <= maximumLongSide, dimensions.height <= maximumLongSide,
              encodedByteCount >= 0, targetPixelWidth > 0,
              targetPixelWidth <= dimensions.width else {
            throw ReaderImageDisplayError.budgetExceeded
        }
        let height = ceil(Double(dimensions.height) * Double(targetPixelWidth) / Double(dimensions.width))
        let outputPixels = Double(targetPixelWidth) * height
        let estimated = Double(dimensions.pixels) * 8 + outputPixels * 8
            + Double(encodedByteCount) + 32 * 1024 * 1024
        guard outputPixels <= maximumPixels + maximumWidth,
              height <= Double(maximumLongSide), estimated <= 256 * 1024 * 1024 else {
            throw ReaderImageDisplayError.budgetExceeded
        }
    }
}
