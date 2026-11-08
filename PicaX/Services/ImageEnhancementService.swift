import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

enum ImageEnhancementMode: String, CaseIterable, Identifiable, Sendable {
    case off
    case sharpen
    case upscaleSharpen
    case strong

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off:
            "关闭"
        case .sharpen:
            "锐化"
        case .upscaleSharpen:
            "插值放大 + 锐化"
        case .strong:
            "强力线条增强"
        }
    }

    var usesUpscale: Bool {
        self == .upscaleSharpen || self == .strong
    }

    var isEnabled: Bool {
        self != .off
    }
}

struct ReaderImageEnhancement: Equatable, Sendable {
    static let maxScale: Double = 2.0
    static let scalePresets: [Double] = [1.0, 1.25, 1.5, 2.0]

    let mode: ImageEnhancementMode
    /// 0...1，0 表示不锐化。
    let strength: Double
    /// 目标宽度相对屏幕物理像素宽的倍率，1.0...2.0。
    let scale: Double

    init(mode: ImageEnhancementMode, strength: Double, scale: Double = 1.0) {
        self.mode = mode
        self.strength = min(max(strength, 0), 1)
        self.scale = min(max(scale, 1.0), Self.maxScale)
    }

    static let off = ReaderImageEnhancement(mode: .off, strength: 0, scale: 1)

    var isEnabled: Bool {
        mode != .off
    }

    var cacheKeyFragment: String {
        "\(mode.rawValue)-\(Int((strength * 100).rounded()))-\(Int((scale * 100).rounded()))"
    }

    var scaleLabel: String {
        Self.scaleLabel(for: scale)
    }

    static func scaleLabel(for scale: Double) -> String {
        switch scale {
        case 1.0:
            "1×"
        case 1.25:
            "1.25×"
        case 1.5:
            "1.5×"
        case 2.0:
            "2×"
        default:
            "\(String(format: "%.2f", scale))×"
        }
    }
}

enum ImageEnhancementService {
    /// 相对源图的最大放大倍率，避免低分辨率源图被放大到超大内存占用。
    private nonisolated static let maxUpscaleRatio: Double = 3
    /// 单张增强图的最大像素数（约 64 MB RGBA），防止极端尺寸撑爆内存。
    private nonisolated static let maxOutputPixels: Double = 16_000_000
    private nonisolated static let maxOutputSide: Double = 8192

    nonisolated(unsafe) private static let ciContext: CIContext = {
        CIContext(options: [.cacheIntermediates: false])
    }()

    nonisolated static func current(defaults: UserDefaults = .standard) -> ReaderImageEnhancement {
        let mode = ImageEnhancementMode(rawValue: defaults.string(forKey: ReaderSettingsKey.imageEnhancementMode) ?? "") ?? .off
        let storedStrength = defaults.object(forKey: ReaderSettingsKey.imageEnhancementStrength) as? Double ?? 0
        let storedScale = defaults.object(forKey: ReaderSettingsKey.imageEnhancementScale) as? Double ?? 1
        return ReaderImageEnhancement(
            mode: mode,
            strength: min(max(storedStrength, 0), 100) / 100,
            scale: storedScale
        )
    }

    /// 返回增强后的图片；返回 `nil` 表示无需或无法增强，调用方应继续使用原图。
    nonisolated static func enhancedImage(
        cgImage: CGImage,
        targetPixelWidth: Int?,
        enhancement: ReaderImageEnhancement
    ) -> CGImage? {
        guard enhancement.isEnabled, cgImage.width > 0, cgImage.height > 0 else {
            return nil
        }

        var image = CIImage(cgImage: cgImage)
        var didChange = false

        if let outputWidth = upscaledPixelWidth(
            cgImage: cgImage,
            screenPixelWidth: targetPixelWidth,
            enhancement: enhancement
        ) {
            let factor = CGFloat(outputWidth) / CGFloat(cgImage.width)
            let lanczos = CIFilter.lanczosScaleTransform()
            lanczos.inputImage = image
            lanczos.scale = Float(factor)
            lanczos.aspectRatio = 1
            if let output = lanczos.outputImage {
                image = output
                didChange = true
            }
        }

        if enhancement.strength > 0 {
            image = sharpened(image, mode: enhancement.mode, strength: enhancement.strength)
            didChange = true
        }

        guard didChange else {
            return nil
        }

        let extent = image.extent
        guard !extent.isEmpty, !extent.isInfinite else {
            return nil
        }
        return ciContext.createCGImage(image, from: extent)
    }

    private nonisolated static func upscaledPixelWidth(
        cgImage: CGImage,
        screenPixelWidth: Int?,
        enhancement: ReaderImageEnhancement
    ) -> Int? {
        guard enhancement.mode.usesUpscale,
              cgImage.width > 0,
              cgImage.height > 0,
              let screenPixelWidth,
              screenPixelWidth > 0 else {
            return nil
        }

        let sourceWidth = Double(cgImage.width)
        let sourceHeight = Double(cgImage.height)
        var width = min(Double(screenPixelWidth) * enhancement.scale, sourceWidth * maxUpscaleRatio)
        width = min(width, maxOutputSide, maxOutputSide * sourceWidth / sourceHeight)

        let height = width * sourceHeight / sourceWidth
        let pixels = width * height
        if pixels > maxOutputPixels {
            width *= (maxOutputPixels / pixels).squareRoot()
        }

        let rounded = Int(width.rounded(.down))
        return rounded > cgImage.width ? rounded : nil
    }

    private nonisolated static func sharpened(
        _ image: CIImage,
        mode: ImageEnhancementMode,
        strength: Double
    ) -> CIImage {
        var result = image
        switch mode {
        case .off:
            return result
        case .sharpen:
            result = unsharpMask(result, radius: 1.6 + 3.2 * strength, intensity: 0.6 + 2.4 * strength)
            result = sharpenLuminance(result, sharpness: 0.3 + 1.2 * strength)
        case .upscaleSharpen:
            result = unsharpMask(result, radius: 1.2 + 2.4 * strength, intensity: 0.4 + 2.0 * strength)
            result = sharpenLuminance(result, sharpness: 0.2 + 1.0 * strength)
        case .strong:
            // 细粒度 + 粗粒度双通道反锐化掩膜，再叠亮度锐化与轻微对比/饱和提升，接近 Anime4K 的线条强化观感。
            result = unsharpMask(result, radius: 1.0 + 1.4 * strength, intensity: 0.8 + 1.8 * strength)
            result = unsharpMask(result, radius: 2.6 + 3.4 * strength, intensity: 0.5 + 1.4 * strength)
            result = sharpenLuminance(result, sharpness: 0.6 + 1.4 * strength)
            result = colorControls(result, contrast: 1.0 + 0.08 * strength, saturation: 1.0 + 0.04 * strength)
        }
        return result
    }

    private nonisolated static func unsharpMask(_ image: CIImage, radius: Double, intensity: Double) -> CIImage {
        let filter = CIFilter.unsharpMask()
        filter.inputImage = image
        filter.radius = Float(radius)
        filter.intensity = Float(intensity)
        return filter.outputImage ?? image
    }

    private nonisolated static func sharpenLuminance(_ image: CIImage, sharpness: Double) -> CIImage {
        let filter = CIFilter.sharpenLuminance()
        filter.inputImage = image
        filter.sharpness = Float(sharpness)
        return filter.outputImage ?? image
    }

    private nonisolated static func colorControls(_ image: CIImage, contrast: Double, saturation: Double) -> CIImage {
        let filter = CIFilter.colorControls()
        filter.inputImage = image
        filter.contrast = Float(contrast)
        filter.saturation = Float(saturation)
        return filter.outputImage ?? image
    }
}
