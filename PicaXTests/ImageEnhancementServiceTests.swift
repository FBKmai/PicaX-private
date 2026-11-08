import CoreGraphics
import XCTest
@testable import PicaX

final class ImageEnhancementServiceTests: XCTestCase {
    func testCurrentReadsStoredSettingsAndClampsStrength() {
        let suiteName = "ImageEnhancementServiceTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("could not create isolated defaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(ImageEnhancementMode.upscaleSharpen.rawValue, forKey: ReaderSettingsKey.imageEnhancementMode)
        defaults.set(140.0, forKey: ReaderSettingsKey.imageEnhancementStrength)
        defaults.set(1.5, forKey: ReaderSettingsKey.imageEnhancementScale)

        let enhancement = ImageEnhancementService.current(defaults: defaults)
        XCTAssertEqual(enhancement.mode, .upscaleSharpen)
        XCTAssertEqual(enhancement.strength, 1.0, accuracy: 0.0001)
        XCTAssertEqual(enhancement.scale, 1.5, accuracy: 0.0001)
        XCTAssertTrue(enhancement.isEnabled)
        XCTAssertEqual(enhancement.cacheKeyFragment, "upscaleSharpen-100-150")
    }

    func testCurrentFallsBackToOffForUnknownMode() {
        let suiteName = "ImageEnhancementServiceTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("could not create isolated defaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("unknown-mode", forKey: ReaderSettingsKey.imageEnhancementMode)
        defaults.set(-20.0, forKey: ReaderSettingsKey.imageEnhancementStrength)
        defaults.set(9.0, forKey: ReaderSettingsKey.imageEnhancementScale)

        let enhancement = ImageEnhancementService.current(defaults: defaults)
        XCTAssertEqual(enhancement.mode, .off)
        XCTAssertEqual(enhancement.strength, 0, accuracy: 0.0001)
        XCTAssertEqual(enhancement.scale, ReaderImageEnhancement.maxScale, accuracy: 0.0001)
        XCTAssertFalse(enhancement.isEnabled)
    }

    func testOffEnhancementKeepsOriginalImage() {
        let image = makeImage(width: 50, height: 70)
        let enhanced = ImageEnhancementService.enhancedImage(
            cgImage: image,
            targetPixelWidth: 200,
            enhancement: .off
        )
        XCTAssertNil(enhanced)
    }

    func testUpscaleHonorsTargetWidth() {
        let image = makeImage(width: 50, height: 70)
        let enhancement = ReaderImageEnhancement(mode: .upscaleSharpen, strength: 0)

        guard let doubled = ImageEnhancementService.enhancedImage(
            cgImage: image,
            targetPixelWidth: 100,
            enhancement: enhancement
        ) else {
            XCTFail("expected an upscaled image")
            return
        }
        XCTAssertEqual(doubled.width, 100)
        XCTAssertEqual(doubled.height, 140)
    }

    func testScaleMultipliesTargetWidth() {
        let image = makeImage(width: 50, height: 70)
        let enhancement = ReaderImageEnhancement(mode: .upscaleSharpen, strength: 0, scale: 2)

        guard let upscaled = ImageEnhancementService.enhancedImage(
            cgImage: image,
            targetPixelWidth: 60,
            enhancement: enhancement
        ) else {
            XCTFail("expected an upscaled image")
            return
        }
        XCTAssertEqual(upscaled.width, 120)
        XCTAssertEqual(upscaled.height, 168)
    }

    func testUpscaleIsCappedAtThreeTimesTheSource() {
        let image = makeImage(width: 50, height: 70)
        let enhancement = ReaderImageEnhancement(mode: .upscaleSharpen, strength: 0, scale: 2)

        guard let capped = ImageEnhancementService.enhancedImage(
            cgImage: image,
            targetPixelWidth: 600,
            enhancement: enhancement
        ) else {
            XCTFail("expected a capped upscaled image")
            return
        }
        XCTAssertEqual(capped.width, 150)
        XCTAssertEqual(capped.height, 210)
    }

    func testUpscaleSkipsSourcesWiderThanTheScreen() {
        let image = makeImage(width: 400, height: 560)
        let enhancement = ReaderImageEnhancement(mode: .upscaleSharpen, strength: 0)
        XCTAssertNil(
            ImageEnhancementService.enhancedImage(
                cgImage: image,
                targetPixelWidth: 300,
                enhancement: enhancement
            )
        )
    }

    func testSharpenKeepsPixelSize() {
        let image = makeImage(width: 60, height: 90)
        let enhancement = ReaderImageEnhancement(mode: .sharpen, strength: 0.5)

        guard let sharpened = ImageEnhancementService.enhancedImage(
            cgImage: image,
            targetPixelWidth: 600,
            enhancement: enhancement
        ) else {
            XCTFail("expected a sharpened image")
            return
        }
        XCTAssertEqual(sharpened.width, 60)
        XCTAssertEqual(sharpened.height, 90)
    }

    func testStrongModeSharpensWithoutUpscaling() {
        let image = makeImage(width: 60, height: 90)
        let enhancement = ReaderImageEnhancement(mode: .strong, strength: 0.5)

        guard let enhanced = ImageEnhancementService.enhancedImage(
            cgImage: image,
            targetPixelWidth: nil,
            enhancement: enhancement
        ) else {
            XCTFail("expected an enhanced image")
            return
        }
        XCTAssertEqual(enhanced.width, 60)
        XCTAssertEqual(enhanced.height, 90)
    }

    func testUpscaleBoundsHeightAsWellAsWidth() throws {
        let source = makeImage(width: 110, height: 8000)
        let output = try XCTUnwrap(ImageEnhancementService.enhancedImage(
            cgImage: source, targetPixelWidth: 1000,
            enhancement: ReaderImageEnhancement(mode: .upscaleSharpen, strength: 0, scale: 2)
        ))
        XCTAssertLessThanOrEqual(output.width, 8192)
        XCTAssertLessThanOrEqual(output.height, 8192)
        XCTAssertLessThanOrEqual(output.width * output.height, 16_000_000)
    }

    private func makeImage(width: Int, height: Int) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            fatalError("could not create bitmap context")
        }
        context.setFillColor(red: 0.8, green: 0.2, blue: 0.4, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            fatalError("could not create CGImage")
        }
        return image
    }
}
