import CoreGraphics
import CoreText
import Foundation
import ImageIO
import XCTest
@testable import PicaX

final class ReaderImageSourceTests: XCTestCase {
    func testTraditionalDecodeUsesFinalDemandNotScreenThumbnail() {
        let size = ReaderImageDimensions(width: 2400, height: 3400)
        let enhancement = ReaderImageEnhancement(mode: .upscaleSharpen, strength: 0, scale: 2)
        XCTAssertEqual(ReaderImageSourceLoader.displayPixelWidth(
            dimensions: size, targetPixelWidth: 1200, enhancement: enhancement
        ), 2400)
        XCTAssertEqual(ReaderImageSourceLoader.displayPixelWidth(
            dimensions: size, targetPixelWidth: 1200, enhancement: .off
        ), 1200)
    }

    func testCorrectedDecodePreservesFineLinesAndDoesNotModifyOriginal() async throws {
        let data = try png(stripes(width: 2400, height: 40))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("page.png")
        try data.write(to: url)
        let image = try await ReaderImageDecoder.image(
            url: url, targetPixelWidth: 1200,
            enhancement: ReaderImageEnhancement(mode: .upscaleSharpen, strength: 0, scale: 2)
        )
        let output = try XCTUnwrap(image.image.picaxCGImage)
        XCTAssertEqual(output.width, 2400)
        XCTAssertEqual(output.height, 40)
        // A 1200px intermediate loses these alternating 1px lines. This catches
        // detail loss even if the old pipeline interpolates back to 2400px.
        let row = rgba(output)
        var contrast = 0
        for x in 0..<(output.width - 1) {
            contrast += abs(Int(row[x * 4]) - Int(row[(x + 1) * 4]))
        }
        XCTAssertGreaterThan(Double(contrast) / Double(output.width - 1), 200)
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    func testOriginalSourceHasIndependentContentFingerprintAndFullSize() throws {
        let url = URL(fileURLWithPath: "/synthetic-page.png")
        let first = try ReaderImageSourceLoader.decode(data: png(stripes(width: 101, height: 79)), url: url)
        let second = try ReaderImageSourceLoader.decode(data: png(stripes(width: 103, height: 79)), url: url)
        XCTAssertEqual(first.dimensions, ReaderImageDimensions(width: 101, height: 79))
        XCTAssertEqual(first.image.width, 101)
        XCTAssertEqual(first.fingerprint.count, 64)
        XCTAssertNotEqual(first.fingerprint, second.fingerprint)
    }

    func testSourceBudgetRejectsDimensionsBeforeAllocatingBitmap() {
        XCTAssertThrowsError(try ReaderImageSourceLoader.validate(
            dimensions: ReaderImageDimensions(width: 4000, height: 4000)
        ))
        XCTAssertThrowsError(try ReaderImageSourceLoader.validate(
            dimensions: ReaderImageDimensions(width: 1, height: 16_385)
        ))
        XCTAssertThrowsError(try ReaderImageSourceLoader.validate(
            dimensions: ReaderImageDimensions(width: Int.max, height: Int.max)
        ))
    }

    func testLongPageDisplayDecodeIsBoundedOnBothAxes() {
        let width = ReaderImageSourceLoader.displayPixelWidth(
            dimensions: ReaderImageDimensions(width: 1000, height: 100_000),
            targetPixelWidth: 1200,
            enhancement: ReaderImageEnhancement(mode: .strong, strength: 0.5, scale: 2)
        )
        XCTAssertLessThanOrEqual(width * 100, 8192)
        XCTAssertGreaterThan(width, 0)
    }

    func testEXIFOrientationNormalizesDimensionsAndImage() throws {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.tiff" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, stripes(width: 31, height: 47), [
            kCGImagePropertyOrientation: 6
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let source = try ReaderImageSourceLoader.decode(data: data as Data, url: URL(fileURLWithPath: "/rotated.tiff"))
        XCTAssertEqual(source.dimensions, ReaderImageDimensions(width: 47, height: 31))
        XCTAssertEqual(source.image.width, 47)
        XCTAssertEqual(source.image.height, 31)
    }

    func testJMFailureCannotBecomeValidAISource() throws {
        let tooShort = try png(stripes(width: 5, height: 3))
        let url = try XCTUnwrap(URL(string: "https://example.invalid/photos/250000/00001.jpg"))
        XCTAssertTrue(JmImageScrambler.requiresReordering(url: url))
        XCTAssertThrowsError(try ReaderImageSourceLoader.decode(data: tooShort, url: url)) { error in
            guard case ReaderImageSourceError.cannotUnscramble = error else {
                return XCTFail("Expected a strict reorder failure, got \(error)")
            }
        }
    }

    func testSyntheticCalibrationPageIncludesTextDotsLinesAndGradient() throws {
        let context = context(width: 320, height: 480)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 320, height: 480))
        let gradient = try XCTUnwrap(CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [CGColor(gray: 0.1, alpha: 1), CGColor(gray: 0.9, alpha: 1)] as CFArray,
            locations: [0, 1]
        ))
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 320, y: 120), options: [])
        context.setFillColor(gray: 0, alpha: 1)
        for y in stride(from: 150, to: 300, by: 4) {
            for x in stride(from: 10, to: 310, by: 4) {
                context.fillEllipse(in: CGRect(x: CGFloat(x), y: CGFloat(y), width: 1, height: 1))
            }
        }
        for x in stride(from: 10, to: 310, by: 3) {
            context.fill(CGRect(x: CGFloat(x), y: 310, width: 1, height: 60))
        }
        let text = NSAttributedString(string: "漫画测试：中文小字 0123456789", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("PingFangSC-Regular" as CFString, 12, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ])
        context.textPosition = CGPoint(x: 10, y: 420)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        let image = try XCTUnwrap(context.makeImage())
        let data = try png(image)
        let result = try ReaderImageSourceLoader.decode(data: data, url: URL(fileURLWithPath: "/calibration.png"))
        XCTAssertEqual(result.dimensions, ReaderImageDimensions(width: 320, height: 480))
        XCTAssertGreaterThan(Set(rgba(result.image)).count, 32)
        // This is an engineering fixture, not an assertion that AI improves text.
    }

    private func stripes(width: Int, height: Int) -> CGImage {
        let context = context(width: width, height: height)
        for x in 0..<width {
            context.setFillColor(gray: x.isMultiple(of: 2) ? 0 : 1, alpha: 1)
            context.fill(CGRect(x: CGFloat(x), y: 0, width: 1, height: CGFloat(height)))
        }
        return context.makeImage()!
    }

    private func context(width: Int, height: Int) -> CGContext {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    private func rgba(_ image: CGImage) -> [UInt8] {
        let context = context(width: image.width, height: image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
        return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }

    private func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
