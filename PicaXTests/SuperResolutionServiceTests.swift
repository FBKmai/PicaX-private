import CoreGraphics
import CoreML
import Foundation
import XCTest
@testable import PicaX

final class SuperResolutionServiceTests: XCTestCase {
    private func descriptor(
        id: String = "model",
        preset: SuperResolutionPreset = .manga,
        minimum: Int? = 100,
        maximum: Int? = 1_000,
        precision: String = "float32",
        validated: Bool = true,
        sourceURL: String = "https://example.com/weights",
        license: String = "CC-BY-NC-4.0",
        hash: String = String(repeating: "a", count: 64),
        resourceName: String? = nil,
        inputName: String = "input",
        tileSize: Int = 128,
        overlap: Int = 20,
        scale: Int = 2,
        fullPage: SuperResolutionFullPageCapability? = nil
    ) -> SuperResolutionModel {
        SuperResolutionModel(
            id: id, preset: preset, displayName: "Test model", version: "1",
            resourceName: resourceName ?? id, sourceURL: sourceURL, license: license,
            weightSHA256: hash, inputName: inputName, outputName: "output",
            tileSize: tileSize, overlap: overlap, scale: scale,
            minimumPageHeight: minimum, maximumPageHeight: maximum,
            precision: precision, validated: validated, fullPage: fullPage
        )
    }

    private func fullPageCapability(
        validated: Bool = true,
        shapeMode: SuperResolutionFullPageCapability.ShapeMode = .range,
        alignment: Int = 16,
        minimumWidth: Int = 64,
        minimumHeight: Int = 64,
        maximumWidth: Int = 2_048,
        maximumHeight: Int = 2_048,
        maximumPixels: Int = 2_000_000,
        workingBytesPerPixel: Int = 2_048,
        enumeratedSizes: [[Int]]? = nil
    ) -> SuperResolutionFullPageCapability {
        SuperResolutionFullPageCapability(
            validated: validated, shapeMode: shapeMode, alignment: alignment,
            minimumWidth: minimumWidth, minimumHeight: minimumHeight,
            maximumWidth: maximumWidth, maximumHeight: maximumHeight,
            maximumPixels: maximumPixels,
            estimatedWorkingBytesPerPixel: workingBytesPerPixel,
            enumeratedSizes: enumeratedSizes
        )
    }

    private func assertFailure<T>(
        _ expected: SuperResolutionError,
        _ expression: @autoclosure () throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            XCTAssertEqual(error as? SuperResolutionError, expected, file: file, line: line)
        }
    }

    func testDescriptorDecodesAndRequiresValidatedMetadata() throws {
        let json = """
        {"id":"color","preset":"color","displayName":"Color","version":"1",
         "resourceName":"color","sourceURL":"https://example.com/model","license":"CC-BY-NC-4.0",
         "weightSHA256":"\(String(repeating: "A", count: 64))","inputName":"input","outputName":"output",
         "tileSize":128,"overlap":20,"scale":2,"precision":"float16","validated":true}
        """
        let decoded = try JSONDecoder().decode(SuperResolutionModel.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.preset, .color)
        XCTAssertNil(decoded.minimumPageHeight)
        XCTAssertNil(decoded.maximumPageHeight)
        XCTAssertNoThrow(try decoded.validate())
        XCTAssertNoThrow(try descriptor().validate())
        assertFailure(.invalidDescriptor, try descriptor(validated: false).validate())
        assertFailure(.invalidDescriptor, try descriptor(license: "  ").validate())
        assertFailure(.invalidDescriptor, try descriptor(validated: true, license: "UNRESOLVED").validate())
        assertFailure(.invalidDescriptor, try descriptor(validated: true, license: "CC-BY-NC-4.0 OR UNRESOLVED").validate())
        assertFailure(.invalidDescriptor, try descriptor(validated: true, license: "unknown").validate())
        assertFailure(.invalidDescriptor, try descriptor(validated: true, license: "MIT").validate())
        XCTAssertNoThrow(try descriptor(license: "CC-BY-NC-SA-4.0").validate())
        assertFailure(.invalidDescriptor, try descriptor(sourceURL: "not a url").validate())
        assertFailure(.invalidDescriptor, try descriptor(hash: String(repeating: "g", count: 64)).validate())
        assertFailure(.invalidDescriptor, try descriptor(hash: String(repeating: "a", count: 63)).validate())
        assertFailure(.invalidDescriptor, try descriptor(resourceName: "../other").validate())
        assertFailure(.invalidDescriptor, try descriptor(resourceName: "other.mlmodelc").validate())
        assertFailure(.invalidDescriptor, try descriptor(inputName: "\n").validate())
        assertFailure(.invalidDescriptor, try descriptor(inputName: "image").validate())
        assertFailure(.invalidDescriptor, try descriptor(sourceURL: "http://example.com/weights").validate())
        assertFailure(.invalidDescriptor, try descriptor(resourceName: "model.mlpackage").validate())
    }

    func testDescriptorRequiresFixedGeometryAndPrecision() {
        assertFailure(.invalidDescriptor, try descriptor(tileSize: 64).validate())
        assertFailure(.invalidDescriptor, try descriptor(overlap: 19).validate())
        assertFailure(.invalidDescriptor, try descriptor(scale: 4).validate())
        assertFailure(.invalidDescriptor, try descriptor(precision: "float16").validate())
        assertFailure(.invalidDescriptor, try descriptor(precision: "FLOAT32").validate())
        XCTAssertNoThrow(try descriptor(preset: .color, minimum: nil, maximum: nil, precision: "float16").validate())
        XCTAssertNoThrow(try descriptor(preset: .color, minimum: nil, maximum: nil, precision: "float32").validate())
        assertFailure(.invalidDescriptor, try descriptor(preset: .color, minimum: nil, maximum: 200).validate())
        assertFailure(.invalidDescriptor, try descriptor(preset: .color, minimum: 100, maximum: nil).validate())
        assertFailure(.invalidDescriptor, try descriptor(preset: .color, minimum: 0, maximum: 200).validate())
        assertFailure(.invalidDescriptor, try descriptor(preset: .color, minimum: 200, maximum: 199).validate())
        XCTAssertNoThrow(try descriptor(preset: .color, minimum: 100, maximum: 200).validate())
        assertFailure(.missingMangaHeightRange, try descriptor(minimum: nil).validate())
        assertFailure(.missingMangaHeightRange, try descriptor(maximum: nil).validate())
        assertFailure(.invalidMangaHeightRange, try descriptor(minimum: 200, maximum: 199).validate())
        assertFailure(.invalidMangaHeightRange, try descriptor(minimum: 0).validate())
    }

    func testFullPageMetadataDecodesAndStaysOptional() throws {
        let legacy = """
        {"id":"color","preset":"color","displayName":"Color","version":"1",
         "resourceName":"color","sourceURL":"https://example.com/model","license":"CC-BY-NC-4.0",
         "weightSHA256":"\(String(repeating: "a", count: 64))","inputName":"input","outputName":"output",
         "tileSize":128,"overlap":20,"scale":2,"precision":"float32","validated":true}
        """
        let legacyModel = try JSONDecoder().decode(SuperResolutionModel.self, from: Data(legacy.utf8))
        XCTAssertNil(legacyModel.fullPage)
        XCTAssertNoThrow(try legacyModel.validate())

        let modern = """
        {"id":"color","preset":"color","displayName":"Color","version":"1",
         "resourceName":"color","sourceURL":"https://example.com/model","license":"CC-BY-NC-4.0",
         "weightSHA256":"\(String(repeating: "a", count: 64))","inputName":"input","outputName":"output",
         "tileSize":128,"overlap":20,"scale":2,"precision":"float32","validated":true,
         "fullPage":{"validated":true,"shapeMode":"enumerated","alignment":16,
           "minimumWidth":64,"minimumHeight":64,"maximumWidth":2048,"maximumHeight":2048,
           "maximumPixels":2000000,"estimatedWorkingBytesPerPixel":1024,
           "enumeratedSizes":[[256,384],[1008,1504]]}}
        """
        let modernModel = try JSONDecoder().decode(SuperResolutionModel.self, from: Data(modern.utf8))
        XCTAssertEqual(modernModel.fullPage?.shapeMode, .enumerated)
        XCTAssertEqual(modernModel.fullPage?.enumeratedSizes, [[256, 384], [1008, 1504]])
        XCTAssertNoThrow(try modernModel.validate())
    }

    func testFullPageCapabilityValidation() {
        XCTAssertNoThrow(try descriptor(fullPage: fullPageCapability()).validate())
        XCTAssertNoThrow(try descriptor(fullPage: fullPageCapability(
            shapeMode: .enumerated, enumeratedSizes: [[256, 384], [1008, 1504]])).validate())
        let invalid = [
            fullPageCapability(alignment: 12),
            fullPageCapability(alignment: 0),
            fullPageCapability(minimumWidth: 0),
            fullPageCapability(maximumWidth: 32),
            fullPageCapability(maximumHeight: 32),
            fullPageCapability(maximumPixels: 100),
            fullPageCapability(workingBytesPerPixel: 0),
            fullPageCapability(workingBytesPerPixel: 65_537),
            fullPageCapability(shapeMode: .enumerated),
            fullPageCapability(shapeMode: .enumerated, enumeratedSizes: [[1000, 1500]]),
            fullPageCapability(shapeMode: .enumerated, enumeratedSizes: [[256, 384], [256, 384]]),
            fullPageCapability(shapeMode: .enumerated, enumeratedSizes: [[4096, 64]]),
            fullPageCapability(shapeMode: .enumerated, enumeratedSizes: [[256]]),
            fullPageCapability(shapeMode: .range, enumeratedSizes: [[256, 384]])
        ]
        for capability in invalid {
            assertFailure(.invalidDescriptor, try descriptor(fullPage: capability).validate())
        }
    }

    func testFullPageInputDimensionsPadOrChooseAnEnumeratedShape() throws {
        let range = fullPageCapability()
        XCTAssertEqual(try range.inputDimensions(width: 1000, height: 1500).width, 1008)
        XCTAssertEqual(try range.inputDimensions(width: 1000, height: 1500).height, 1504)
        XCTAssertEqual(try range.inputDimensions(width: 10, height: 20).width, 64)
        XCTAssertEqual(try range.inputDimensions(width: 10, height: 20).height, 64)
        assertFailure(.fullPagePageUnsupported, try range.inputDimensions(width: 2_049, height: 500))
        assertFailure(.fullPagePageUnsupported, try range.inputDimensions(width: 2_000, height: 1_100))

        let enumerated = fullPageCapability(
            shapeMode: .enumerated,
            enumeratedSizes: [[256, 384], [512, 768], [1008, 1504]])
        XCTAssertEqual(try enumerated.inputDimensions(width: 100, height: 100).width, 256)
        XCTAssertEqual(try enumerated.inputDimensions(width: 100, height: 100).height, 384)
        XCTAssertEqual(try enumerated.inputDimensions(width: 999, height: 1501).width, 1008)
        XCTAssertEqual(try enumerated.inputDimensions(width: 999, height: 1501).height, 1504)
        assertFailure(.fullPagePageUnsupported, try enumerated.inputDimensions(width: 1_100, height: 1_600))
    }

    func testAutomaticModeDisclosesTiledFallbackAndNeverMislabelsIt() throws {
        let tiledOnly = descriptor(fullPage: nil)
        XCTAssertEqual(try SuperResolutionModelSelection.resolveMode(
            requested: .tiled, model: tiledOnly, width: 1_000, height: 1_500).actual, .tiled)
        assertFailure(.fullPageUnavailable, try SuperResolutionModelSelection.resolveMode(
            requested: .fullPage, model: tiledOnly, width: 1_000, height: 1_500))

        let unverified = descriptor(fullPage: fullPageCapability(validated: false))
        assertFailure(.fullPageUnavailable, try SuperResolutionModelSelection.resolveMode(
            requested: .fullPage, model: unverified, width: 1_000, height: 1_500))
        let automaticUnverified = try SuperResolutionModelSelection.resolveMode(
            requested: .automatic, model: unverified, width: 1_000, height: 1_500)
        XCTAssertEqual(automaticUnverified.actual, .tiled)
        XCTAssertNotNil(automaticUnverified.fallbackReason)

        let verified = descriptor(fullPage: fullPageCapability())
        XCTAssertEqual(try SuperResolutionModelSelection.resolveMode(
            requested: .fullPage, model: verified, width: 1_000, height: 1_500).actual, .fullPage)
        assertFailure(.fullPagePageUnsupported, try SuperResolutionModelSelection.resolveMode(
            requested: .fullPage, model: verified, width: 2_049, height: 2_049))
        let automatic = try SuperResolutionModelSelection.resolveMode(
            requested: .automatic, model: verified, width: 1_000, height: 1_500)
        XCTAssertEqual(automatic.actual, .fullPage)
        XCTAssertNil(automatic.fallbackReason)
        let automaticTooLarge = try SuperResolutionModelSelection.resolveMode(
            requested: .automatic, model: verified, width: 3_000, height: 3_000)
        XCTAssertEqual(automaticTooLarge.actual, .tiled)
        XCTAssertNotNil(automaticTooLarge.fallbackReason)
    }

    func testFullPageBudgetAccountsForWorkingSetAndStorage() throws {
        let capability = fullPageCapability()
        let budget = try SuperResolutionFullPageBudget.make(
            width: 100, height: 200, sourceBytesPerRow: 400,
            capability: capability, physicalMemory: 8 * 1024 * 1024 * 1024)
        XCTAssertEqual(budget.inputWidth, 112)
        XCTAssertEqual(budget.inputHeight, 208)
        XCTAssertEqual(budget.outputWidth, 200)
        XCTAssertEqual(budget.outputHeight, 400)
        XCTAssertEqual(budget.inputBytes, 279_552)
        XCTAssertEqual(budget.outputBytes, 320_000)
        XCTAssertEqual(budget.estimatedPeakBytes, 250_676_352)
        XCTAssertEqual(budget.requiredFreeBytes, 34_194_432)
        assertFailure(.budgetExceeded, try SuperResolutionFullPageBudget.make(
            width: 100, height: 200, sourceBytesPerRow: 400,
            capability: capability, physicalMemory: 256 * 1024 * 1024))
        assertFailure(.invalidInput, try SuperResolutionFullPageBudget.make(
            width: 0, height: 200, sourceBytesPerRow: 400,
            capability: capability, physicalMemory: 8 * 1024 * 1024 * 1024))
    }

    func testMangaSelectionUsesInclusiveOriginalHeightAndRejectsAmbiguity() throws {
        let small = descriptor(id: "small", minimum: 100, maximum: 200)
        let large = descriptor(id: "large", minimum: 201, maximum: 400)
        XCTAssertEqual(try SuperResolutionModelSelection.select(
            from: [large, small], preset: .manga, width: 99, height: 200
        ).id, "small")
        XCTAssertEqual(try SuperResolutionModelSelection.select(
            from: [small, large], preset: .manga, width: 100, height: 201
        ).id, "large")
        XCTAssertEqual(try SuperResolutionModelSelection.select(
            from: [small, large], preset: .manga, width: 100, height: 400
        ).id, "large")
        assertFailure(.noMangaModelForHeight, try SuperResolutionModelSelection.select(
            from: [small], preset: .manga, width: 100, height: 201
        ))
        let touching = descriptor(id: "touching", minimum: 200, maximum: 500)
        assertFailure(.overlappingMangaRanges, try SuperResolutionModelSelection.select(
            from: [small, touching], preset: .manga, width: 99, height: 199
        ))
        let missing = descriptor(id: "missing", minimum: nil, maximum: nil)
        assertFailure(.missingMangaHeightRange, try SuperResolutionModelSelection.select(
            from: [small, missing], preset: .manga, width: 99, height: 199
        ))
    }

    func testDuplicateDescriptorIdentityCannotSelectDifferentWeights() {
        let one = descriptor(id: "same", minimum: 100, maximum: 200)
        let two = descriptor(id: "same", minimum: 201, maximum: 400, resourceName: "different")
        assertFailure(.invalidDescriptor, try SuperResolutionModelSelection.select(
            from: [one, two], preset: .manga, width: 99, height: 199
        ))
    }

    func testColorSelectionAndPageEligibility() throws {
        let one = descriptor(id: "one", preset: .color, minimum: nil, maximum: nil)
        let two = descriptor(id: "two", preset: .color, minimum: nil, maximum: nil)
        let unvalidated = descriptor(id: "not-installed", preset: .color, validated: false)
        XCTAssertEqual(try SuperResolutionModelSelection.select(
            from: [one, unvalidated], preset: .color, width: 800, height: 600
        ).id, "one")
        assertFailure(.ambiguousColorModels, try SuperResolutionModelSelection.select(
            from: [one, two], preset: .color, width: 800, height: 600
        ))
        assertFailure(.modelUnavailable, try SuperResolutionModelSelection.select(
            from: [unvalidated], preset: .color, width: 800, height: 600
        ))
        assertFailure(.modelUnavailable, try SuperResolutionModelSelection.select(
            from: [], preset: .manga, width: 100, height: 200
        ))
        assertFailure(.unsuitableMangaPage, try SuperResolutionModelSelection.validatePage(
            width: 800, height: 600, preset: .manga
        ))
        assertFailure(.unsuitableMangaPage, try SuperResolutionModelSelection.validatePage(
            width: 800, height: 800, preset: .manga
        ))
        XCTAssertNoThrow(try SuperResolutionModelSelection.validatePage(width: 100, height: 400, preset: .manga))
        assertFailure(.longPage, try SuperResolutionModelSelection.validatePage(
            width: 100, height: 401, preset: .manga
        ))
        assertFailure(.longPage, try SuperResolutionModelSelection.validatePage(
            width: 100, height: 401, preset: .color
        ))
        assertFailure(.invalidInput, try SuperResolutionModelSelection.validatePage(
            width: 0, height: 1, preset: .color
        ))
    }

    func testCatalogRejectsMissingUnvalidatedAndUnlicensedResources() throws {
        let installedURL = URL(fileURLWithPath: "/bundle/model.mlmodelc", isDirectory: true)
        let valid = descriptor(preset: .color, minimum: nil, maximum: nil)
        let unvalidated = descriptor(preset: .color, minimum: nil, maximum: nil, validated: false)
        let unresolved = descriptor(preset: .color, minimum: nil, maximum: nil, license: "UNRESOLVED")
        assertFailure(.modelUnavailable, try SuperResolutionService.selectBundledModel(
            descriptors: [valid], preset: .color, width: 100, height: 100, resourceURL: { _ in nil }
        ))
        assertFailure(.modelUnavailable, try SuperResolutionService.selectBundledModel(
            descriptors: [unvalidated, unresolved], preset: .color, width: 100, height: 100,
            resourceURL: { _ in installedURL }
        ))
        let chosen = try SuperResolutionService.selectBundledModel(
            descriptors: [valid, unvalidated, unresolved], preset: .color, width: 100, height: 100,
            resourceURL: { _ in installedURL }
        )
        XCTAssertEqual(chosen.descriptor, valid)
        XCTAssertEqual(chosen.url, installedURL)
        let missingRange = descriptor(minimum: nil, maximum: nil)
        assertFailure(.missingMangaHeightRange, try SuperResolutionService.selectBundledModel(
            descriptors: [missingRange], preset: .manga, width: 100, height: 200,
            resourceURL: { _ in installedURL }
        ))
        assertFailure(.modelUnavailable, try SuperResolutionService.selectBundledModel(
            descriptors: [missingRange], preset: .manga, width: 100, height: 200,
            resourceURL: { _ in nil }
        ))
    }

    func testMemoryAndStorageBudgetBoundaries() throws {
        let budget = try SuperResolutionBudget.make(width: 100, height: 200, sourceBytesPerRow: 400)
        XCTAssertEqual(budget.outputWidth, 200)
        XCTAssertEqual(budget.outputHeight, 400)
        XCTAssertEqual(budget.inputBytes, 80_000)
        XCTAssertEqual(budget.outputBytes, 320_000)
        XCTAssertEqual(budget.estimatedPeakBytes, 80_000 * 3 + 320_000 * 4 + 96 * 1024 * 1024)
        XCTAssertEqual(budget.requiredFreeBytes, 320_000 * 2 + 32 * 1024 * 1024)

        let belowLimit = try SuperResolutionBudget.make(width: 2_000, height: 1_103, sourceBytesPerRow: 8_000)
        XCTAssertLessThanOrEqual(Int64(belowLimit.estimatedPeakBytes), SuperResolutionBudget.maximumEstimatedBytes)
        assertFailure(.budgetExceeded, try SuperResolutionBudget.make(width: 2_000, height: 1_104, sourceBytesPerRow: 8_000))
        XCTAssertEqual(try SuperResolutionBudget.make(width: 8_192, height: 1, sourceBytesPerRow: 32_768).outputWidth, 16_384)
        assertFailure(.budgetExceeded, try SuperResolutionBudget.make(width: 8_193, height: 1, sourceBytesPerRow: 32_772))
        assertFailure(.budgetExceeded, try SuperResolutionBudget.make(width: 8_000, height: 1_001, sourceBytesPerRow: 32_000))
        assertFailure(.budgetExceeded, try SuperResolutionBudget.make(width: 1, height: 2, sourceBytesPerRow: Int.max))
        assertFailure(.invalidInput, try SuperResolutionBudget.make(width: 0, height: 1, sourceBytesPerRow: 4))
    }

    func testReflectDoesNotRepeatBoundaryAndHandlesOnePixel() {
        XCTAssertEqual((-5...8).map { SuperResolutionTile.reflected($0, length: 4) },
                       [1, 2, 3, 2, 1, 0, 1, 2, 3, 2, 1, 0, 1, 2])
        XCTAssertEqual((-50...50).map { SuperResolutionTile.reflected($0, length: 1) },
                       [Int](repeating: 0, count: 101))
    }

    func testPartialTilesCoverEveryOutputPixelExactlyOnce() {
        XCTAssertEqual(SuperResolutionTile.core, 88)
        for (width, height) in [(1, 1), (87, 89), (88, 88), (89, 177), (177, 89)] {
            let outputWidth = width * 2
            var visits = [UInt8](repeating: 0, count: outputWidth * height * 2)
            for y in stride(from: 0, to: height, by: SuperResolutionTile.core) {
                for x in stride(from: 0, to: width, by: SuperResolutionTile.core) {
                    let tile = SuperResolutionTile.at(x: x, y: y, pageWidth: width, pageHeight: height)
                    XCTAssertTrue((1...88).contains(tile.width))
                    XCTAssertTrue((1...88).contains(tile.height))
                    for row in 0..<(tile.height * 2) {
                        for column in 0..<(tile.width * 2) {
                            let index = (tile.y * 2 + row) * outputWidth + tile.x * 2 + column
                            visits[index] += 1
                        }
                    }
                }
            }
            XCTAssertTrue(visits.allSatisfy { $0 == 1 }, "incomplete or overlapping \(width) × \(height) page")
        }
        let last = SuperResolutionTile.at(x: 88, y: 88, pageWidth: 89, pageHeight: 89)
        XCTAssertEqual(last, SuperResolutionTile(x: 88, y: 88, width: 1, height: 1))
    }

    /// Custom backing storage ensures these tests do not accidentally depend on contiguous tensors.
    private func stridedArray(shape: [Int], strides: [Int]) throws -> MLMultiArray {
        let count = zip(shape, strides).reduce(1) { $0 + ($1.0 - 1) * $1.1 }
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: count * MemoryLayout<Float32>.stride, alignment: MemoryLayout<Float32>.alignment
        )
        storage.initializeMemory(as: Float32.self, repeating: 0, count: count)
        do {
            return try MLMultiArray(
                dataPointer: storage, shape: shape.map { NSNumber(value: $0) }, dataType: .float32,
                strides: strides.map { NSNumber(value: $0) }, deallocator: { $0.deallocate() }
            )
        } catch {
            storage.deallocate()
            throw error
        }
    }

    func testInputTileUsesReflectRGBAndActualStrides() throws {
        let rowStride = 258
        let channelStride = rowStride * 128
        let array = try stridedArray(shape: [1, 3, 128, 128], strides: [channelStride * 3, channelStride, rowStride, 2])
        let pixels: [UInt8] = [
            1, 2, 3, 255, 10, 11, 12, 255, 20, 21, 22, 255,
            100, 101, 102, 255, 110, 111, 112, 255, 120, 121, 122, 255
        ]
        let tile = SuperResolutionTile.at(x: 0, y: 0, pageWidth: 3, pageHeight: 2)
        try pixels.withUnsafeBufferPointer { buffer in
            try SuperResolutionService.fillInputArray(array, tile: tile, pageWidth: 3, pageHeight: 2, input: buffer.baseAddress!)
        }
        let values = array.dataPointer.assumingMemoryBound(to: Float32.self)
        func value(_ c: Int, _ y: Int, _ x: Int) -> Float32 {
            values[c * channelStride + y * rowStride + x * 2]
        }
        XCTAssertEqual(value(0, 20, 20), Float32(1) / 255, accuracy: 0.00001)
        XCTAssertEqual(value(1, 20, 20), Float32(2) / 255, accuracy: 0.00001)
        XCTAssertEqual(value(2, 20, 20), Float32(3) / 255, accuracy: 0.00001)
        XCTAssertEqual(value(0, 20, 19), Float32(10) / 255, accuracy: 0.00001)
        XCTAssertEqual(value(0, 19, 20), Float32(100) / 255, accuracy: 0.00001)
        XCTAssertEqual(value(0, 20, 23), Float32(10) / 255, accuracy: 0.00001)
        XCTAssertEqual(value(0, 22, 20), Float32(1) / 255, accuracy: 0.00001)
    }

    func testOutputCoreUsesStridesClampsAndRejectsNonFiniteHalo() throws {
        let rowStride = 520
        let channelStride = rowStride * 256
        let array = try stridedArray(shape: [1, 3, 256, 256], strides: [channelStride * 3, channelStride, rowStride, 2])
        let values = array.dataPointer.assumingMemoryBound(to: Float32.self)
        let firstCore = 40 * rowStride + 40 * 2
        values[firstCore] = -0.1
        values[channelStride + firstCore] = 0.5
        values[2 * channelStride + firstCore] = 1.1
        let tile = SuperResolutionTile.at(x: 88, y: 88, pageWidth: 89, pageHeight: 89)
        let outputWidth = 178
        var output = [UInt8](repeating: 7, count: outputWidth * outputWidth * 4)
        try output.withUnsafeMutableBufferPointer { buffer in
            try SuperResolutionService.copyOutputCore(array, tile: tile, pageWidth: 89, output: buffer.baseAddress!)
        }
        let index = (176 * outputWidth + 176) * 4
        XCTAssertEqual(Array(output[index..<(index + 4)]), [0, 128, 255, 255])
        XCTAssertEqual(Array(output[(index + 4)..<(index + 8)]), [0, 0, 0, 255])
        XCTAssertEqual(output[index - 1], 7)
        values[0] = .nan // The top-left halo is not copied, but must still be checked.
        XCTAssertThrowsError(try output.withUnsafeMutableBufferPointer { buffer in
            try SuperResolutionService.copyOutputCore(array, tile: tile, pageWidth: 89, output: buffer.baseAddress!)
        }) { error in
            XCTAssertEqual(error as? SuperResolutionError, .nonFiniteOutput)
        }
    }

    func testFullPageInputFillsReflectedRGBThroughStrides() throws {
        let rowStride = 10
        let channelStride = rowStride * 4
        let array = try stridedArray(
            shape: [1, 3, 4, 4], strides: [channelStride * 3, channelStride, rowStride, 2])
        let pixels: [UInt8] = [
            1, 2, 3, 255, 10, 11, 12, 255,
            100, 101, 102, 255, 110, 111, 112, 255
        ]
        try pixels.withUnsafeBufferPointer { buffer in
            try SuperResolutionService.fillFullPageInputArray(
                array, pageWidth: 2, pageHeight: 2,
                paddedWidth: 4, paddedHeight: 4, input: buffer.baseAddress!)
        }
        let values = array.dataPointer.assumingMemoryBound(to: Float32.self)
        func value(_ channel: Int, _ y: Int, _ x: Int) -> Float32 {
            values[channel * channelStride + y * rowStride + x * 2]
        }
        // x=3 and y=3 reflect to 1; x=2 reflects to 0.
        XCTAssertEqual(value(0, 3, 2), 100.0 / 255, accuracy: 0.00001)
        XCTAssertEqual(value(1, 3, 2), 101.0 / 255, accuracy: 0.00001)
        XCTAssertEqual(value(2, 3, 2), 102.0 / 255, accuracy: 0.00001)
        XCTAssertEqual(value(0, 0, 3), 10.0 / 255, accuracy: 0.00001)
        XCTAssertEqual(value(2, 1, 1), 112.0 / 255, accuracy: 0.00001)
        XCTAssertEqual(value(0, 1, 1), 110.0 / 255, accuracy: 0.00001)
    }

    func testFullPageOutputCropsPaddingAndChecksDiscardedPixels() throws {
        let rowStride = 20
        let channelStride = rowStride * 8
        let array = try stridedArray(
            shape: [1, 3, 8, 8], strides: [channelStride * 3, channelStride, rowStride, 2])
        let values = array.dataPointer.assumingMemoryBound(to: Float32.self)
        values[0] = -0.1
        values[channelStride] = 0.5
        values[2 * channelStride] = 1.1
        let source = 4 * rowStride + 5 * 2 // padded-only coordinate (x=5, y=4)
        let outputWidth = 4
        var output = [UInt8](repeating: 7, count: outputWidth * 4 * 4)
        try output.withUnsafeMutableBufferPointer { buffer in
            try SuperResolutionService.copyFullPageOutput(
                array, pageWidth: 2, pageHeight: 2,
                paddedWidth: 4, paddedHeight: 4, output: buffer.baseAddress!)
        }
        XCTAssertEqual(Array(output[0..<4]), [0, 128, 255, 255])
        // The crop keeps only the top-left 4×4 of the 8×8 padded output.
        XCTAssertEqual(output[3], 255)
        XCTAssertEqual(output[(1 * outputWidth + 1) * 4 + 3], 255)
        values[source] = .nan
        XCTAssertThrowsError(try output.withUnsafeMutableBufferPointer { buffer in
            try SuperResolutionService.copyFullPageOutput(
                array, pageWidth: 2, pageHeight: 2,
                paddedWidth: 4, paddedHeight: 4, output: buffer.baseAddress!)
        }) { error in
            XCTAssertEqual(error as? SuperResolutionError, .nonFiniteOutput)
        }
    }

    func testArrayShapeAndDataTypeAreChecked() throws {
        let wrongType = try MLMultiArray(shape: [1, 3, 128, 128], dataType: .double)
        assertFailure(.modelDescriptionMismatch, try SuperResolutionService.strides(wrongType, shape: [1, 3, 128, 128]))
        let wrongShape = try MLMultiArray(shape: [1, 3, 128, 127], dataType: .float32)
        assertFailure(.modelDescriptionMismatch, try SuperResolutionService.strides(wrongShape, shape: [1, 3, 128, 128]))
    }

    func testCancellationBeforeRegistrationAndWhileQueued() async throws {
        let image = try SuperResolutionService.makeOutputImage(bytes: [0, 0, 0, 255], width: 1, height: 1)
        let source = ReaderImageSource(image: image, dimensions: .init(width: 1, height: 1), fingerprint: "test")
        let job = SuperResolutionJob(source: source, preset: .color, onProgress: { _ in })
        for cancelBeforeRegistration in [true, false] {
            let token = SuperResolutionCancellation(job: job)
            if cancelBeforeRegistration { token.cancel() }
            do {
                let _: SuperResolutionResult = try await withCheckedThrowingContinuation { continuation in
                    token.register(continuation)
                    if !cancelBeforeRegistration { token.cancel() }
                }
                XCTFail("cancelled queued work must not return a result")
            } catch is CancellationError {
                XCTAssertNil(token.begin())
            } catch {
                XCTFail("expected CancellationError, got \(error)")
            }
        }
    }

    func testRunningCancellationWinsOverInferenceFailure() async throws {
        let image = try SuperResolutionService.makeOutputImage(bytes: [0, 0, 0, 255], width: 1, height: 1)
        let source = ReaderImageSource(image: image, dimensions: .init(width: 1, height: 1), fingerprint: "test")
        let token = SuperResolutionCancellation(job: .init(source: source, preset: .color, onProgress: { _ in }))
        do {
            let _: SuperResolutionResult = try await withCheckedThrowingContinuation { continuation in
                token.register(continuation)
                XCTAssertNotNil(token.begin())
                token.cancel()
                do {
                    try token.check()
                    XCTFail("running cancellation must be observable by the worker")
                } catch {
                    XCTAssertTrue(error is CancellationError)
                }
                token.complete(.failure(SuperResolutionError.inferenceFailed))
            }
            XCTFail("cancelled running work must not return a result")
        } catch is CancellationError {
            XCTAssertNil(token.begin())
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }

    func testRunningCancellationRemovesLateSuccessfulOutput() async throws {
        let image = try SuperResolutionService.makeOutputImage(bytes: [0, 0, 0, 255], width: 1, height: 1)
        let source = ReaderImageSource(image: image, dimensions: .init(width: 1, height: 1), fingerprint: "test")
        let token = SuperResolutionCancellation(job: .init(source: source, preset: .color, onProgress: { _ in }))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("output.png")
        try Data([1]).write(to: url)
        let result = SuperResolutionResult(
            image: image, model: descriptor(preset: .color, minimum: nil, maximum: nil),
            sourceFingerprint: "test", elapsedSeconds: 0, estimatedPeakBytes: 0,
            outputURL: url, outputByteCount: 1,
            requestedMode: .automatic, actualMode: .tiled, computeUnit: .all,
            fallbackReason: nil, paddedInputWidth: nil, paddedInputHeight: nil
        )
        do {
            let _: SuperResolutionResult = try await withCheckedThrowingContinuation { continuation in
                token.register(continuation)
                XCTAssertNotNil(token.begin())
                token.cancel()
                token.complete(.success(result))
            }
            XCTFail("cancelled work must not return its late result")
        } catch is CancellationError {
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }

    func testSRGBConversionCompositesTransparencyAndKeepsRowOrder() throws {
        let pixels: [UInt8] = [
            255, 0, 0, 255, 0, 128, 0, 128,
            0, 0, 0, 0, 0, 0, 255, 255
        ]
        let source = try SuperResolutionService.makeOutputImage(bytes: pixels, width: 2, height: 2)
        let converted = try SuperResolutionService.makeSRGBPixels(image: source, byteCount: 16)
        XCTAssertEqual(converted[3], 255)
        XCTAssertEqual(converted[7], 255)
        XCTAssertEqual(converted[11], 255)
        XCTAssertEqual(converted[15], 255)
        let actual = stride(from: 0, to: 16, by: 4).map { Array(converted[$0..<($0 + 4)]) }
        let expected: [[UInt8]] = [
            [255, 0, 0, 255], [127, 255, 127, 255], [255, 255, 255, 255], [0, 0, 255, 255]
        ]
        for pixel in expected {
            XCTAssertTrue(actual.contains { actualPixel in
                zip(actualPixel, pixel).allSatisfy { abs(Int($0.0) - Int($0.1)) <= 1 }
            })
        }
        let reconstructed = try SuperResolutionService.makeOutputImage(bytes: converted, width: 2, height: 2)
        XCTAssertEqual(try SuperResolutionService.makeSRGBPixels(image: reconstructed, byteCount: 16), converted)
    }
}
