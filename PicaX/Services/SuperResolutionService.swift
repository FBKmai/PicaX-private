import CoreGraphics
import CoreML
import Foundation
import ImageIO
import OSLog
import UniformTypeIdentifiers

nonisolated struct SuperResolutionResult: @unchecked Sendable {
    let image: CGImage
    let model: SuperResolutionModel
    let sourceFingerprint: String
    let elapsedSeconds: Double
    /// A conservative planning estimate, not a measurement of process peak memory.
    let estimatedPeakBytes: Int
    let outputURL: URL
    let outputByteCount: Int
    let requestedMode: SuperResolutionInferenceMode
    let actualMode: SuperResolutionInferenceMode
    let computeUnit: SuperResolutionComputeUnit
    /// Set only when automatic mode stayed on tiled inference.
    let fallbackReason: String?
    /// The real dynamic input size for full-page inference; nil for tiled.
    let paddedInputWidth: Int?
    let paddedInputHeight: Int?
}

extension SuperResolutionComputeUnit {
    nonisolated var mlComputeUnits: MLComputeUnits {
        switch self {
        case .all: .all
        case .cpuAndGPU: .cpuAndGPU
        case .cpuOnly: .cpuOnly
        }
    }
}

nonisolated struct SuperResolutionBudget: Equatable, Sendable {
    static let maximumOutputPixels: Int64 = 32_000_000
    static let maximumSide = 16_384
    static let maximumEstimatedBytes: Int64 = 256 * 1024 * 1024
    static let workingAllowance: Int64 = 32 * 1024 * 1024
    static let comparisonAllowance: Int64 = 64 * 1024 * 1024
    static let storageAllowance: Int64 = 32 * 1024 * 1024

    let outputWidth: Int
    let outputHeight: Int
    let inputBytes: Int
    let outputBytes: Int
    let estimatedPeakBytes: Int
    let requiredFreeBytes: Int64

    static func make(width: Int, height: Int, sourceBytesPerRow: Int) throws -> Self {
        guard width > 0, height > 0, sourceBytesPerRow > 0 else {
            throw SuperResolutionError.invalidInput
        }
        guard width <= maximumSide / 2, height <= maximumSide / 2 else {
            throw SuperResolutionError.budgetExceeded
        }
        let pixels = Int64(width) * Int64(height)
        let outputPixels = pixels * 4
        guard pixels <= 12_000_000, outputPixels <= maximumOutputPixels else {
            throw SuperResolutionError.budgetExceeded
        }
        let inputBytes = pixels * 4
        let outputBytes = outputPixels * 4
        let (sourceBytes, sourceOverflow) = Int64(sourceBytesPerRow).multipliedReportingOverflow(by: Int64(height))
        guard !sourceOverflow, sourceBytes > 0 else { throw SuperResolutionError.budgetExceeded }
        // The UI may retain a traditional enhancement of up to 16 MP, so always
        // reserve at least 64 MiB for it, even if it is currently off. Also count
        // the source, two input rasters, four output-sized image/PNG buffers and
        // a tile/working reserve. Core ML/OS allocations are not measurable here.
        let sourceReserve = max(sourceBytes, inputBytes)
        let comparisonReserve = max(comparisonAllowance, max(sourceBytes, inputBytes * 2))
        let (retainedBytes, retainedOverflow) = sourceReserve.addingReportingOverflow(comparisonReserve)
        let (baseBytes, baseOverflow) = retainedBytes.addingReportingOverflow(inputBytes * 2)
        let (estimate, estimateOverflow) = baseBytes.addingReportingOverflow(outputBytes * 4 + workingAllowance)
        guard !retainedOverflow, !baseOverflow, !estimateOverflow, estimate <= maximumEstimatedBytes else {
            throw SuperResolutionError.budgetExceeded
        }
        // PNG can be slightly larger than raw pixels; leave a separate safety margin.
        let requiredFreeBytes = outputBytes * 2 + storageAllowance
        return Self(
            outputWidth: width * 2,
            outputHeight: height * 2,
            inputBytes: Int(inputBytes),
            outputBytes: Int(outputBytes),
            estimatedPeakBytes: Int(estimate),
            requiredFreeBytes: requiredFreeBytes
        )
    }
}

nonisolated struct SuperResolutionFullPageBudget: Equatable, Sendable {
    /// Planning ceiling, not an observed process peak. A page is rejected before
    /// inference when the conservative estimate exceeds this value or half of
    /// the device's physical memory.
    static let maximumEstimatedBytes: Int64 = 4 * 1024 * 1024 * 1024
    static let modelOverhead: Int64 = 128 * 1024 * 1024
    static let comparisonAllowance: Int64 = 64 * 1024 * 1024
    static let storageAllowance: Int64 = 32 * 1024 * 1024

    let inputWidth: Int
    let inputHeight: Int
    let outputWidth: Int
    let outputHeight: Int
    let inputBytes: Int
    let outputBytes: Int
    let estimatedPeakBytes: Int
    let requiredFreeBytes: Int64

    static func make(
        width: Int,
        height: Int,
        sourceBytesPerRow: Int,
        capability: SuperResolutionFullPageCapability,
        physicalMemory: UInt64
    ) throws -> Self {
        guard width > 0, height > 0, sourceBytesPerRow > 0 else {
            throw SuperResolutionError.invalidInput
        }
        let (inputWidth, inputHeight) = try capability.inputDimensions(width: width, height: height)
        let outputWidth = width * 2
        let outputHeight = height * 2
        let pagePixels = Int64(width) * Int64(height)
        let alignedPixels = Int64(inputWidth) * Int64(inputHeight)
        // Source sRGB RGBA, aligned float32 input, model working set, output
        // RGBA, output image/PNG/comparison copies, and Core ML/OS overhead.
        let sourceRaster = max(Int64(sourceBytesPerRow) * Int64(height), pagePixels * 4)
        let inputBytes = alignedPixels * 12
        let workingBytes = alignedPixels * Int64(capability.estimatedWorkingBytesPerPixel)
        let outputBytes = pagePixels * 16
        let estimate = sourceRaster + inputBytes + workingBytes + outputBytes * 4
            + comparisonAllowance + modelOverhead
        let allowed = min(maximumEstimatedBytes, Int64(physicalMemory / 2))
        guard estimate <= allowed, outputWidth > 0, outputHeight > 0 else {
            throw SuperResolutionError.budgetExceeded
        }
        return Self(
            inputWidth: inputWidth,
            inputHeight: inputHeight,
            outputWidth: outputWidth,
            outputHeight: outputHeight,
            inputBytes: Int(inputBytes),
            outputBytes: Int(outputBytes),
            estimatedPeakBytes: Int(estimate),
            requiredFreeBytes: outputBytes * 2 + storageAllowance
        )
    }
}

nonisolated struct SuperResolutionTile: Equatable, Sendable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int

    static let size = 128
    static let halo = 20
    static let core = size - halo * 2
    static let scale = 2

    static func at(x: Int, y: Int, pageWidth: Int, pageHeight: Int) -> Self {
        Self(x: x, y: y, width: min(core, pageWidth - x), height: min(core, pageHeight - y))
    }

    /// Reflect without repeating the edge pixel, including one-pixel dimensions.
    static func reflected(_ coordinate: Int, length: Int) -> Int {
        precondition(length > 0)
        guard length > 1 else { return 0 }
        let period = (length - 1) * 2
        let remainder = coordinate % period
        let position = remainder < 0 ? remainder + period : remainder
        return position < length ? position : period - position
    }
}

/// All calls share one worker. No work runs until process is explicitly called.
nonisolated final class SuperResolutionService: @unchecked Sendable {
    static let shared = SuperResolutionService()
    private let queue = DispatchQueue(label: "PicaX.SuperResolutionService", qos: .userInitiated)
    private static let logger = Logger(subsystem: "PicaX", category: "SuperResolution")

    private init() {}

    func process(
        source: ReaderImageSource,
        preset: SuperResolutionPreset,
        mode: SuperResolutionInferenceMode = .automatic,
        computeUnit: SuperResolutionComputeUnit = .all,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> SuperResolutionResult {
        let token = SuperResolutionCancellation(job: SuperResolutionJob(
            source: source, preset: preset, mode: mode, computeUnit: computeUnit,
            onProgress: onProgress
        ))
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result: SuperResolutionResult = try await withCheckedThrowingContinuation { continuation in
                token.register(continuation)
                queue.async {
                    guard let job = token.begin() else { return }
                    do {
                        let result = try self.run(
                            source: job.source, preset: job.preset, mode: job.mode,
                            computeUnit: job.computeUnit, token: token, onProgress: job.onProgress
                        )
                        token.complete(.success(result))
                    } catch {
                        token.complete(.failure(error))
                    }
                }
            }
            // Cancellation can race the worker handing the result to this task.
            if Task.isCancelled {
                try? FileManager.default.removeItem(at: result.outputURL.deletingLastPathComponent())
                throw CancellationError()
            }
            return result
        } onCancel: {
            token.cancel()
        }
    }

    private func run(
        source: ReaderImageSource,
        preset: SuperResolutionPreset,
        mode: SuperResolutionInferenceMode,
        computeUnit: SuperResolutionComputeUnit,
        token: SuperResolutionCancellation,
        onProgress: @Sendable (Double) -> Void
    ) throws -> SuperResolutionResult {
        let started = ProcessInfo.processInfo.systemUptime
        try token.check()
        guard #available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *) else {
            throw SuperResolutionError.unsupportedOS
        }
        let width = source.dimensions.width
        let height = source.dimensions.height
        guard source.image.width == width, source.image.height == height else {
            throw SuperResolutionError.invalidInput
        }
        try SuperResolutionModelSelection.validatePage(width: width, height: height, preset: preset)
        let selected = try Self.findModel(preset: preset, width: width, height: height)
        let resolution = try SuperResolutionModelSelection.resolveMode(
            requested: mode, model: selected.descriptor, width: width, height: height)
        if let reason = resolution.fallbackReason {
            Self.logger.notice("Super-resolution fallback: requested=\(mode.rawValue, privacy: .public) actual=\(resolution.actual.rawValue, privacy: .public) reason=\(reason, privacy: .public)")
        }
        Self.logger.notice("Super-resolution start: model=\(selected.descriptor.id, privacy: .public) actual=\(resolution.actual.rawValue, privacy: .public) units=\(computeUnit.rawValue, privacy: .public) page=\(width)x\(height)")

        let requiredFreeBytes: Int64
        var fullPageBudget: SuperResolutionFullPageBudget?
        switch resolution.actual {
        case .fullPage:
            guard let capability = selected.descriptor.fullPage else {
                throw SuperResolutionError.fullPageUnavailable
            }
            let budget = try SuperResolutionFullPageBudget.make(
                width: width, height: height,
                sourceBytesPerRow: source.image.bytesPerRow,
                capability: capability,
                physicalMemory: ProcessInfo.processInfo.physicalMemory
            )
            requiredFreeBytes = budget.requiredFreeBytes
            fullPageBudget = budget
        case .tiled:
            let budget = try SuperResolutionBudget.make(
                width: width, height: height, sourceBytesPerRow: source.image.bytesPerRow
            )
            requiredFreeBytes = budget.requiredFreeBytes
        case .automatic:
            throw SuperResolutionError.inferenceFailed
        }
        try Self.checkStorage(requiredBytes: requiredFreeBytes)
        try token.check()

        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnit.mlComputeUnits
        let model: MLModel
        do {
            model = try MLModel(contentsOf: selected.url, configuration: configuration)
        } catch {
            throw SuperResolutionError.modelLoadFailed
        }
        try token.check()
        onProgress(0)

        switch resolution.actual {
        case .fullPage:
            guard let fullPageBudget else { throw SuperResolutionError.fullPageUnavailable }
            return try runFullPage(
                source: source, width: width, height: height, budget: fullPageBudget,
                model: model, descriptor: selected.descriptor, resolution: resolution,
                computeUnit: computeUnit, started: started, token: token, onProgress: onProgress
            )
        case .tiled:
            let budget = try SuperResolutionBudget.make(
                width: width, height: height, sourceBytesPerRow: source.image.bytesPerRow
            )
            try Self.validateTiledDescription(model.modelDescription, descriptor: selected.descriptor)
            return try runTiled(
                source: source, width: width, height: height, budget: budget,
                model: model, descriptor: selected.descriptor, resolution: resolution,
                computeUnit: computeUnit, started: started, token: token, onProgress: onProgress
            )
        case .automatic:
            throw SuperResolutionError.inferenceFailed
        }
    }

    private func runTiled(
        source: ReaderImageSource,
        width: Int,
        height: Int,
        budget: SuperResolutionBudget,
        model: MLModel,
        descriptor: SuperResolutionModel,
        resolution: SuperResolutionModeResolution,
        computeUnit: SuperResolutionComputeUnit,
        started: Double,
        token: SuperResolutionCancellation,
        onProgress: @Sendable (Double) -> Void
    ) throws -> SuperResolutionResult {
        let input = try Self.makeSRGBPixels(image: source.image, byteCount: budget.inputBytes)
        try token.check()
        var output = [UInt8](repeating: 0, count: budget.outputBytes)
        let columns = (width + SuperResolutionTile.core - 1) / SuperResolutionTile.core
        let rows = (height + SuperResolutionTile.core - 1) / SuperResolutionTile.core
        let tileCount = columns * rows
        var completedTiles = 0

        try input.withUnsafeBytes { inputBytes in
            try output.withUnsafeMutableBytes { outputBytes in
                guard let inputBase = inputBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let outputBase = outputBytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    throw SuperResolutionError.imageConversionFailed
                }
                for row in 0..<rows {
                    for column in 0..<columns {
                        try token.check()
                        let tile = SuperResolutionTile.at(
                            x: column * SuperResolutionTile.core,
                            y: row * SuperResolutionTile.core,
                            pageWidth: width,
                            pageHeight: height
                        )
                        try autoreleasepool {
                            try Self.predictTile(
                                tile, pageWidth: width, pageHeight: height,
                                input: inputBase, output: outputBase,
                                model: model, descriptor: descriptor, token: token
                            )
                        }
                        try token.check()
                        completedTiles += 1
                        onProgress(0.95 * Double(completedTiles) / Double(tileCount))
                    }
                }
            }
        }
        try token.check()
        return try finalizeOutput(
            bytes: output, width: budget.outputWidth, height: budget.outputHeight,
            source: source, descriptor: descriptor, resolution: resolution,
            computeUnit: computeUnit, paddedInput: nil, started: started,
            estimatedPeakBytes: budget.estimatedPeakBytes,
            requiredFreeBytes: budget.requiredFreeBytes, token: token, onProgress: onProgress
        )
    }

    private func runFullPage(
        source: ReaderImageSource,
        width: Int,
        height: Int,
        budget: SuperResolutionFullPageBudget,
        model: MLModel,
        descriptor: SuperResolutionModel,
        resolution: SuperResolutionModeResolution,
        computeUnit: SuperResolutionComputeUnit,
        started: Double,
        token: SuperResolutionCancellation,
        onProgress: @Sendable (Double) -> Void
    ) throws -> SuperResolutionResult {
        try Self.validateFullPageDescription(
            model.modelDescription, descriptor: descriptor,
            inputWidth: budget.inputWidth, inputHeight: budget.inputHeight
        )
        try token.check()
        let pixels = try Self.makeSRGBPixels(image: source.image, byteCount: width * height * 4)
        try token.check()
        onProgress(0.05)
        let output: [UInt8] = try autoreleasepool {
            let inputArray: MLMultiArray
            do {
                inputArray = try MLMultiArray(
                    shape: [NSNumber(value: 1), NSNumber(value: 3),
                            NSNumber(value: budget.inputHeight), NSNumber(value: budget.inputWidth)],
                    dataType: .float32)
            } catch {
                throw SuperResolutionError.budgetExceeded
            }
            try pixels.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    throw SuperResolutionError.imageConversionFailed
                }
                try Self.fillFullPageInputArray(
                    inputArray, pageWidth: width, pageHeight: height,
                    paddedWidth: budget.inputWidth, paddedHeight: budget.inputHeight, input: base
                )
            }
            try token.check()
            onProgress(0.15)
            let prediction: MLFeatureProvider
            do {
                let features = try MLDictionaryFeatureProvider(dictionary: [
                    descriptor.inputName: MLFeatureValue(multiArray: inputArray)
                ])
                prediction = try model.prediction(from: features)
            } catch {
                throw SuperResolutionError.inferenceFailed
            }
            // Core ML cannot be interrupted mid-call. Check immediately after it
            // returns so a cancelled job never continues to output or PNG work.
            try token.check()
            guard let result = prediction.featureValue(for: descriptor.outputName)?.multiArrayValue else {
                throw SuperResolutionError.modelDescriptionMismatch
            }
            var bytes = [UInt8](repeating: 0, count: budget.outputBytes)
            try bytes.withUnsafeMutableBytes { buffer in
                guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    throw SuperResolutionError.imageConversionFailed
                }
                try Self.copyFullPageOutput(
                    result, pageWidth: width, pageHeight: height,
                    paddedWidth: budget.inputWidth, paddedHeight: budget.inputHeight, output: base
                )
            }
            return bytes
        }
        try token.check()
        onProgress(0.95)
        return try finalizeOutput(
            bytes: output, width: budget.outputWidth, height: budget.outputHeight,
            source: source, descriptor: descriptor, resolution: resolution,
            computeUnit: computeUnit,
            paddedInput: (width: budget.inputWidth, height: budget.inputHeight),
            started: started, estimatedPeakBytes: budget.estimatedPeakBytes,
            requiredFreeBytes: budget.requiredFreeBytes, token: token, onProgress: onProgress
        )
    }

    private func finalizeOutput(
        bytes: [UInt8],
        width: Int,
        height: Int,
        source: ReaderImageSource,
        descriptor: SuperResolutionModel,
        resolution: SuperResolutionModeResolution,
        computeUnit: SuperResolutionComputeUnit,
        paddedInput: (width: Int, height: Int)?,
        started: Double,
        estimatedPeakBytes: Int,
        requiredFreeBytes: Int64,
        token: SuperResolutionCancellation,
        onProgress: @Sendable (Double) -> Void
    ) throws -> SuperResolutionResult {
        try token.check()
        let image = try Self.makeOutputImage(bytes: bytes, width: width, height: height)
        try token.check()
        // Storage may have changed during inference.
        try Self.checkStorage(requiredBytes: requiredFreeBytes)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PicaX-SuperResolutionTrials", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let outputURL = directory.appendingPathComponent("output.png", isDirectory: false)
        var successful = false
        defer {
            if !successful { try? FileManager.default.removeItem(at: directory) }
        }
        try token.check()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try token.check()
            guard let destination = CGImageDestinationCreateWithURL(
                outputURL as CFURL, UTType.png.identifier as CFString, 1, nil
            ) else { throw SuperResolutionError.outputWriteFailed }
            CGImageDestinationAddImage(destination, image, nil)
            try token.check()
            guard CGImageDestinationFinalize(destination) else { throw SuperResolutionError.outputWriteFailed }
            try token.check()
            let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
            guard let size = attributes[.size] as? NSNumber, size.int64Value > 0,
                  size.int64Value <= Int64(Int.max) else { throw SuperResolutionError.outputWriteFailed }
            try token.check()
            let result = SuperResolutionResult(
                image: image,
                model: descriptor,
                sourceFingerprint: source.fingerprint,
                elapsedSeconds: ProcessInfo.processInfo.systemUptime - started,
                estimatedPeakBytes: estimatedPeakBytes,
                outputURL: outputURL,
                outputByteCount: size.intValue,
                requestedMode: resolution.requested,
                actualMode: resolution.actual,
                computeUnit: computeUnit,
                fallbackReason: resolution.fallbackReason,
                paddedInputWidth: paddedInput?.width,
                paddedInputHeight: paddedInput?.height
            )
            successful = true
            onProgress(1)
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SuperResolutionError.outputWriteFailed
        }
    }

    nonisolated struct BundledModel {
        let descriptor: SuperResolutionModel
        let url: URL
    }

    private static func findModel(preset: SuperResolutionPreset, width: Int, height: Int) throws -> BundledModel {
        let urls = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? []
        let descriptors: [SuperResolutionModel] = urls.compactMap { resourceURL in
            let url = resourceURL as URL
            guard url.lastPathComponent.hasSuffix(".superresolution.json"),
                  let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(SuperResolutionModel.self, from: data)
        }
        return try selectBundledModel(
            descriptors: descriptors, preset: preset, width: width, height: height,
            resourceURL: { compiledModelURL(named: $0) }
        )
    }

    /// Injecting resource lookup keeps catalog behavior testable without a model.
    static func selectBundledModel(
        descriptors: [SuperResolutionModel], preset: SuperResolutionPreset,
        width: Int, height: Int, resourceURL: (String) -> URL?
    ) throws -> BundledModel {
        var available: [BundledModel] = []
        var rangeError: SuperResolutionError?
        for descriptor in descriptors where descriptor.preset == preset && descriptor.validated {
            do {
                try descriptor.validate()
            } catch let error as SuperResolutionError {
                if (error == .missingMangaHeightRange || error == .invalidMangaHeightRange),
                   resourceURL(descriptor.resourceName) != nil {
                    rangeError = error
                }
                continue
            } catch {
                continue
            }
            guard let modelURL = resourceURL(descriptor.resourceName) else { continue }
            available.append(BundledModel(descriptor: descriptor, url: modelURL))
        }
        if let rangeError { throw rangeError }
        let descriptor = try SuperResolutionModelSelection.select(
            from: available.map(\.descriptor), preset: preset, width: width, height: height
        )
        // Selection rejects ambiguous duplicate descriptors/ranges.
        guard let chosen = available.first(where: { $0.descriptor == descriptor }) else {
            throw SuperResolutionError.modelUnavailable
        }
        return chosen
    }

    private static func compiledModelURL(named resourceName: String) -> URL? {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "mlmodelc") else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return url
    }

    private static func checkStorage(requiredBytes: Int64) throws {
        let temporary = FileManager.default.temporaryDirectory
        let values = try? temporary.resourceValues(forKeys: [
            .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey
        ])
        let ordinary = values?.volumeAvailableCapacity.map { Int64($0) }
        let important = values?.volumeAvailableCapacityForImportantUsage
        let available: Int64?
        if let ordinary, let important {
            available = min(ordinary, important)
        } else {
            available = ordinary ?? important
        }
        guard let available, available >= requiredBytes else { throw SuperResolutionError.insufficientStorage }
    }

    private static func validateTiledDescription(
        _ description: MLModelDescription,
        descriptor: SuperResolutionModel
    ) throws {
        let input = description.inputDescriptionsByName[descriptor.inputName]
        let output = description.outputDescriptionsByName[descriptor.outputName]
        guard description.inputDescriptionsByName.count == 1,
              description.outputDescriptionsByName.count == 1,
              let input, let output,
              isFloat32MultiArray(input, shape: [1, 3, 128, 128]),
              isFloat32MultiArray(output, shape: [1, 3, 256, 256]) else {
            throw SuperResolutionError.modelDescriptionMismatch
        }
    }

    private static func validateFullPageDescription(
        _ description: MLModelDescription,
        descriptor: SuperResolutionModel,
        inputWidth: Int,
        inputHeight: Int
    ) throws {
        guard description.inputDescriptionsByName.count == 1,
              description.outputDescriptionsByName.count == 1,
              let input = description.inputDescriptionsByName[descriptor.inputName],
              let output = description.outputDescriptionsByName[descriptor.outputName],
              input.type == .multiArray, let inputConstraint = input.multiArrayConstraint,
              output.type == .multiArray, let outputConstraint = output.multiArrayConstraint,
              inputConstraint.dataType == .float32,
              outputConstraint.dataType == .float32 else {
            throw SuperResolutionError.modelDescriptionMismatch
        }
        if #available(iOS 15.0, macOS 12.0, tvOS 15.0, watchOS 8.0, *) {
            // A converted ML Program does not necessarily publish a shape
            // constraint for a dynamic output. The exact 2x output shape and
            // strides are therefore checked on the prediction result in
            // copyFullPageOutput, before any pixel is written.
            guard accepts(inputConstraint, width: inputWidth, height: inputHeight) else {
                throw SuperResolutionError.modelDescriptionMismatch
            }
        } else {
            throw SuperResolutionError.modelDescriptionMismatch
        }
    }

    @available(iOS 15.0, macOS 12.0, tvOS 15.0, watchOS 8.0, *)
    private static func accepts(
        _ constraint: MLMultiArrayConstraint,
        width: Int,
        height: Int
    ) -> Bool {
        let expected = [1, 3, height, width]
        let fixedShapeMatches = constraint.shape.map(\.intValue) == expected
        switch constraint.shapeConstraint.type {
        case .range:
            let ranges = constraint.shapeConstraint.sizeRangeForDimension
            guard ranges.count == expected.count else { return false }
            for index in expected.indices {
                let range = ranges[index].rangeValue
                guard range.location <= expected[index],
                      expected[index] < range.location + range.length else { return false }
            }
            return true
        case .enumerated:
            return constraint.shapeConstraint.enumeratedShapes.contains { shape in
                shape.map(\.intValue) == expected
            }
        case .unspecified:
            return fixedShapeMatches
        @unknown default:
            return false
        }
    }

    private static func isFloat32MultiArray(_ feature: MLFeatureDescription, shape: [Int]) -> Bool {
        guard feature.type == .multiArray, let constraint = feature.multiArrayConstraint else { return false }
        return constraint.dataType == .float32 && constraint.shape.map(\.intValue) == shape
    }

    /// RGBA bytes in sRGB; compositing over white removes transparency before inference.
    static func makeSRGBPixels(image: CGImage, byteCount: Int) throws -> [UInt8] {
        guard image.width > 0, image.height > 0,
              image.width <= SuperResolutionBudget.maximumSide,
              image.height <= SuperResolutionBudget.maximumSide,
              byteCount == image.width * image.height * 4,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw SuperResolutionError.imageConversionFailed
        }
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let success = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
            return true
        }
        guard success else { throw SuperResolutionError.imageConversionFailed }
        return bytes
    }

    static func makeOutputImage(bytes: [UInt8], width: Int, height: Int) throws -> CGImage {
        guard width > 0, height > 0,
              width <= SuperResolutionBudget.maximumSide, height <= SuperResolutionBudget.maximumSide,
              bytes.count == width * height * 4,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ) else { throw SuperResolutionError.imageConversionFailed }
        return image
    }

    static func strides(_ array: MLMultiArray, shape: [Int]) throws -> [Int] {
        guard array.dataType == .float32, array.shape.map(\.intValue) == shape,
              array.strides.count == shape.count else { throw SuperResolutionError.modelDescriptionMismatch }
        let strides = array.strides.map(\.intValue)
        var maximumOffset = 0
        for index in shape.indices {
            guard strides[index] >= 0, shape[index] == 1 || strides[index] > 0 else {
                throw SuperResolutionError.modelDescriptionMismatch
            }
            let (part, multiplyOverflow) = (shape[index] - 1).multipliedReportingOverflow(by: strides[index])
            let (next, addOverflow) = maximumOffset.addingReportingOverflow(part)
            guard !multiplyOverflow, !addOverflow else { throw SuperResolutionError.modelDescriptionMismatch }
            maximumOffset = next
        }
        return strides
    }

    private static func predictTile(
        _ tile: SuperResolutionTile,
        pageWidth: Int,
        pageHeight: Int,
        input: UnsafePointer<UInt8>,
        output: UnsafeMutablePointer<UInt8>,
        model: MLModel,
        descriptor: SuperResolutionModel,
        token: SuperResolutionCancellation
    ) throws {
        let inputArray: MLMultiArray
        do {
            inputArray = try MLMultiArray(shape: [1, 3, 128, 128], dataType: .float32)
        } catch {
            throw SuperResolutionError.inferenceFailed
        }
        try fillInputArray(inputArray, tile: tile, pageWidth: pageWidth, pageHeight: pageHeight, input: input)
        try token.check()
        let prediction: MLFeatureProvider
        do {
            let features = try MLDictionaryFeatureProvider(dictionary: [
                descriptor.inputName: MLFeatureValue(multiArray: inputArray)
            ])
            prediction = try model.prediction(from: features)
        } catch {
            throw SuperResolutionError.inferenceFailed
        }
        try token.check()
        guard let result = prediction.featureValue(for: descriptor.outputName)?.multiArrayValue else {
            throw SuperResolutionError.modelDescriptionMismatch
        }
        try copyOutputCore(result, tile: tile, pageWidth: pageWidth, output: output)
    }

    /// Uses the MLMultiArray's real strides, including for non-contiguous arrays.
    static func fillInputArray(
        _ array: MLMultiArray,
        tile: SuperResolutionTile,
        pageWidth: Int,
        pageHeight: Int,
        input: UnsafePointer<UInt8>
    ) throws {
        let inputStrides = try strides(array, shape: [1, 3, 128, 128])
        let inputFloats = array.dataPointer.assumingMemoryBound(to: Float32.self)
        let xs = (0..<128).map { SuperResolutionTile.reflected(tile.x + $0 - 20, length: pageWidth) }
        let ys = (0..<128).map { SuperResolutionTile.reflected(tile.y + $0 - 20, length: pageHeight) }
        for y in 0..<128 {
            for x in 0..<128 {
                let pixel = (ys[y] * pageWidth + xs[x]) * 4
                let destination = y * inputStrides[2] + x * inputStrides[3]
                inputFloats[destination] = Float32(input[pixel]) / 255
                inputFloats[inputStrides[1] + destination] = Float32(input[pixel + 1]) / 255
                inputFloats[2 * inputStrides[1] + destination] = Float32(input[pixel + 2]) / 255
            }
        }
    }

    static func copyOutputCore(
        _ result: MLMultiArray,
        tile: SuperResolutionTile,
        pageWidth: Int,
        output: UnsafeMutablePointer<UInt8>
    ) throws {
        let outputStrides = try strides(result, shape: [1, 3, 256, 256])
        let values = result.dataPointer.assumingMemoryBound(to: Float32.self)
        let pageOutputWidth = pageWidth * 2
        let halo = SuperResolutionTile.halo * SuperResolutionTile.scale
        // Validate the complete output, including the halo that will be discarded.
        for y in 0..<256 {
            for x in 0..<256 {
                let source = y * outputStrides[2] + x * outputStrides[3]
                let red = values[source]
                let green = values[outputStrides[1] + source]
                let blue = values[2 * outputStrides[1] + source]
                guard red.isFinite, green.isFinite, blue.isFinite else {
                    throw SuperResolutionError.nonFiniteOutput
                }
                let coreX = x - halo
                let coreY = y - halo
                guard coreX >= 0, coreX < tile.width * 2,
                      coreY >= 0, coreY < tile.height * 2 else { continue }
                let destination = ((tile.y * 2 + coreY) * pageOutputWidth + tile.x * 2 + coreX) * 4
                output[destination] = UInt8((min(max(red, 0), 1) * 255).rounded())
                output[destination + 1] = UInt8((min(max(green, 0), 1) * 255).rounded())
                output[destination + 2] = UInt8((min(max(blue, 0), 1) * 255).rounded())
                output[destination + 3] = 255
            }
        }
    }

    /// One dynamic input array for the whole page: reflect-pad right/bottom only.
    static func fillFullPageInputArray(
        _ array: MLMultiArray,
        pageWidth: Int,
        pageHeight: Int,
        paddedWidth: Int,
        paddedHeight: Int,
        input: UnsafePointer<UInt8>
    ) throws {
        guard pageWidth > 0, pageHeight > 0, paddedWidth >= pageWidth, paddedHeight >= pageHeight else {
            throw SuperResolutionError.invalidInput
        }
        let inputStrides = try strides(array, shape: [1, 3, paddedHeight, paddedWidth])
        let inputFloats = array.dataPointer.assumingMemoryBound(to: Float32.self)
        let xs = (0..<paddedWidth).map { SuperResolutionTile.reflected($0, length: pageWidth) }
        let ys = (0..<paddedHeight).map { SuperResolutionTile.reflected($0, length: pageHeight) }
        for y in 0..<paddedHeight {
            let row = ys[y] * pageWidth
            for x in 0..<paddedWidth {
                let pixel = (row + xs[x]) * 4
                let destination = y * inputStrides[2] + x * inputStrides[3]
                inputFloats[destination] = Float32(input[pixel]) / 255
                inputFloats[inputStrides[1] + destination] = Float32(input[pixel + 1]) / 255
                inputFloats[2 * inputStrides[1] + destination] = Float32(input[pixel + 2]) / 255
            }
        }
    }

    /// Checks the complete dynamic output, including the padding discarded by the
    /// 2× page crop. Reads through the MLMultiArray's advertised strides.
    static func copyFullPageOutput(
        _ result: MLMultiArray,
        pageWidth: Int,
        pageHeight: Int,
        paddedWidth: Int,
        paddedHeight: Int,
        output: UnsafeMutablePointer<UInt8>
    ) throws {
        guard pageWidth > 0, pageHeight > 0, paddedWidth >= pageWidth, paddedHeight >= pageHeight else {
            throw SuperResolutionError.invalidInput
        }
        let outputStrides = try strides(
            result, shape: [1, 3, paddedHeight * 2, paddedWidth * 2])
        let values = result.dataPointer.assumingMemoryBound(to: Float32.self)
        let pageOutputWidth = pageWidth * 2
        let validWidth = pageWidth * 2
        let validHeight = pageHeight * 2
        for y in 0..<(paddedHeight * 2) {
            for x in 0..<(paddedWidth * 2) {
                let source = y * outputStrides[2] + x * outputStrides[3]
                let red = values[source]
                let green = values[outputStrides[1] + source]
                let blue = values[2 * outputStrides[1] + source]
                guard red.isFinite, green.isFinite, blue.isFinite else {
                    throw SuperResolutionError.nonFiniteOutput
                }
                guard x < validWidth, y < validHeight else { continue }
                let destination = (y * pageOutputWidth + x) * 4
                output[destination] = UInt8((min(max(red, 0), 1) * 255).rounded())
                output[destination + 1] = UInt8((min(max(green, 0), 1) * 255).rounded())
                output[destination + 2] = UInt8((min(max(blue, 0), 1) * 255).rounded())
                output[destination + 3] = 255
            }
        }
    }
}

nonisolated struct SuperResolutionJob: @unchecked Sendable {
    let source: ReaderImageSource
    let preset: SuperResolutionPreset
    let mode: SuperResolutionInferenceMode
    let computeUnit: SuperResolutionComputeUnit
    let onProgress: @Sendable (Double) -> Void

    init(
        source: ReaderImageSource,
        preset: SuperResolutionPreset,
        mode: SuperResolutionInferenceMode = .automatic,
        computeUnit: SuperResolutionComputeUnit = .all,
        onProgress: @escaping @Sendable (Double) -> Void
    ) {
        self.source = source
        self.preset = preset
        self.mode = mode
        self.computeUnit = computeUnit
        self.onProgress = onProgress
    }
}

/// A queued cancellation resumes immediately and releases the captured image;
/// a running cancellation waits for the worker to clean up before resuming.
nonisolated final class SuperResolutionCancellation: @unchecked Sendable {
    private nonisolated enum State: Equatable { case pending, running, finished }
    private let lock = NSLock()
    private var state: State = .pending
    private var cancelled = false
    private var continuation: CheckedContinuation<SuperResolutionResult, Error>?
    private var job: SuperResolutionJob?

    init(job: SuperResolutionJob) {
        self.job = job
    }

    func register(_ continuation: CheckedContinuation<SuperResolutionResult, Error>) {
        lock.lock()
        if cancelled {
            state = .finished
            job = nil
            lock.unlock()
            continuation.resume(throwing: CancellationError())
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func begin() -> SuperResolutionJob? {
        lock.lock()
        defer { lock.unlock() }
        guard state == .pending, !cancelled, continuation != nil, let job else { return nil }
        state = .running
        self.job = nil
        return job
    }

    func check() throws {
        lock.lock()
        let isCancelled = cancelled
        lock.unlock()
        if isCancelled { throw CancellationError() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        var waiting: CheckedContinuation<SuperResolutionResult, Error>?
        if state == .pending {
            job = nil
            if let continuation {
                state = .finished
                waiting = continuation
                self.continuation = nil
            }
        }
        lock.unlock()
        waiting?.resume(throwing: CancellationError())
    }

    func complete(_ result: Result<SuperResolutionResult, Error>) {
        lock.lock()
        guard state == .running, let continuation else {
            lock.unlock()
            return
        }
        state = .finished
        self.continuation = nil
        let isCancelled = cancelled
        lock.unlock()
        if isCancelled {
            if case let .success(output) = result {
                try? FileManager.default.removeItem(at: output.outputURL.deletingLastPathComponent())
            }
            continuation.resume(throwing: CancellationError())
        } else {
            continuation.resume(with: result)
        }
    }
}
