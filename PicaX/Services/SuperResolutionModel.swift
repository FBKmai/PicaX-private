import Foundation

nonisolated enum SuperResolutionPreset: String, CaseIterable, Codable, Sendable, Identifiable {
    case manga
    case color

    var id: String { rawValue }

    var title: String {
        switch self {
        case .manga: "黑白漫画"
        case .color: "彩色"
        }
    }
}

nonisolated enum SuperResolutionInferenceMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case automatic
    case fullPage
    case tiled

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "自动（整页优先）"
        case .fullPage: "整页（单次推理）"
        case .tiled: "分块（128）"
        }
    }
}

nonisolated enum SuperResolutionComputeUnit: String, CaseIterable, Codable, Sendable, Identifiable {
    case all
    case cpuAndGPU
    case cpuOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "全部（系统选择）"
        case .cpuAndGPU: "CPU + GPU"
        case .cpuOnly: "仅 CPU"
        }
    }
}

/// Optional dynamic-shape capability. Old tiled-only descriptors decode `fullPage` as nil.
nonisolated struct SuperResolutionFullPageCapability: Decodable, Equatable, Sendable {
    nonisolated enum ShapeMode: String, Decodable, Sendable {
        case range
        case enumerated
    }

    let validated: Bool
    let shapeMode: ShapeMode
    let alignment: Int
    let minimumWidth: Int
    let minimumHeight: Int
    let maximumWidth: Int
    let maximumHeight: Int
    let maximumPixels: Int
    let estimatedWorkingBytesPerPixel: Int
    let enumeratedSizes: [[Int]]?

    func validate() throws {
        guard alignment > 0, alignment & (alignment - 1) == 0,
              minimumWidth > 0, minimumHeight > 0,
              maximumWidth >= minimumWidth, maximumHeight >= minimumHeight,
              maximumWidth <= 16_384, maximumHeight <= 16_384,
              maximumPixels > 0,
              estimatedWorkingBytesPerPixel > 0,
              estimatedWorkingBytesPerPixel <= 65_536,
              let minimumPixels = Self.product(minimumWidth, minimumHeight),
              maximumPixels >= minimumPixels else {
            throw SuperResolutionError.invalidDescriptor
        }
        switch shapeMode {
        case .range:
            guard enumeratedSizes == nil else { throw SuperResolutionError.invalidDescriptor }
        case .enumerated:
            guard let enumeratedSizes, !enumeratedSizes.isEmpty else {
                throw SuperResolutionError.invalidDescriptor
            }
            var seen = Set<[Int]>()
            for size in enumeratedSizes {
                guard size.count == 2 else { throw SuperResolutionError.invalidDescriptor }
                let (width, height) = (size[0], size[1])
                guard width >= minimumWidth, height >= minimumHeight,
                      width <= maximumWidth, height <= maximumHeight,
                      width % alignment == 0, height % alignment == 0,
                      let pixels = Self.product(width, height), pixels <= maximumPixels,
                      seen.insert(size).inserted else {
                    throw SuperResolutionError.invalidDescriptor
                }
            }
        }
    }

    /// The exact ML input size. Range mode pads only to the alignment; enumerated
    /// mode chooses the smallest declared shape that covers the page.
    func inputDimensions(width: Int, height: Int) throws -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { throw SuperResolutionError.invalidInput }
        let alignedWidth = try Self.align(width, to: alignment)
        let alignedHeight = try Self.align(height, to: alignment)
        let requiredWidth = max(alignedWidth, minimumWidth)
        let requiredHeight = max(alignedHeight, minimumHeight)
        switch shapeMode {
        case .range:
            guard requiredWidth <= maximumWidth, requiredHeight <= maximumHeight,
                  let pixels = Self.product(requiredWidth, requiredHeight),
                  pixels <= maximumPixels else {
                throw SuperResolutionError.fullPagePageUnsupported
            }
            return (requiredWidth, requiredHeight)
        case .enumerated:
            let candidates = (enumeratedSizes ?? []).compactMap { size -> (Int, Int, Int)? in
                guard size.count == 2, size[0] >= requiredWidth, size[1] >= requiredHeight,
                      let pixels = Self.product(size[0], size[1]) else { return nil }
                return (size[0], size[1], pixels)
            }
            guard let chosen = candidates.min(by: { first, second in
                first.2 == second.2 ? (first.0, first.1) < (second.0, second.1) : first.2 < second.2
            }) else { throw SuperResolutionError.fullPagePageUnsupported }
            return (chosen.0, chosen.1)
        }
    }

    static func align(_ value: Int, to alignment: Int) throws -> Int {
        guard value > 0, alignment > 0 else { throw SuperResolutionError.invalidInput }
        let (sum, overflow) = value.addingReportingOverflow(alignment - 1)
        guard !overflow else { throw SuperResolutionError.fullPagePageUnsupported }
        let (aligned, multiplyOverflow) = (sum / alignment).multipliedReportingOverflow(by: alignment)
        guard !multiplyOverflow, aligned > 0 else { throw SuperResolutionError.fullPagePageUnsupported }
        return aligned
    }

    static func product(_ first: Int, _ second: Int) -> Int? {
        guard first > 0, second > 0 else { return nil }
        let (value, overflow) = first.multipliedReportingOverflow(by: second)
        return overflow ? nil : value
    }
}

/// Metadata supplied alongside the compiled model. The weight hash documents the
/// original weights; it is not a hash of Core ML's compiled model directory.
nonisolated struct SuperResolutionModel: Decodable, Equatable, Sendable {
    let id: String
    let preset: SuperResolutionPreset
    let displayName: String
    let version: String
    let resourceName: String
    let sourceURL: String
    let license: String
    let weightSHA256: String
    let inputName: String
    let outputName: String
    let tileSize: Int
    let overlap: Int
    let scale: Int
    let minimumPageHeight: Int?
    let maximumPageHeight: Int?
    let precision: String
    let validated: Bool
    let fullPage: SuperResolutionFullPageCapability?

    init(
        id: String,
        preset: SuperResolutionPreset,
        displayName: String,
        version: String,
        resourceName: String,
        sourceURL: String,
        license: String,
        weightSHA256: String,
        inputName: String,
        outputName: String,
        tileSize: Int,
        overlap: Int,
        scale: Int,
        minimumPageHeight: Int?,
        maximumPageHeight: Int?,
        precision: String,
        validated: Bool,
        fullPage: SuperResolutionFullPageCapability? = nil
    ) {
        self.id = id
        self.preset = preset
        self.displayName = displayName
        self.version = version
        self.resourceName = resourceName
        self.sourceURL = sourceURL
        self.license = license
        self.weightSHA256 = weightSHA256
        self.inputName = inputName
        self.outputName = outputName
        self.tileSize = tileSize
        self.overlap = overlap
        self.scale = scale
        self.minimumPageHeight = minimumPageHeight
        self.maximumPageHeight = maximumPageHeight
        self.precision = precision
        self.validated = validated
        self.fullPage = fullPage
    }

    func validate() throws {
        let requiredStrings = [id, displayName, version, resourceName, sourceURL, license, inputName, outputName]
        guard validated,
              requiredStrings.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              resourceName.utf8.count <= 160,
              resourceName.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }),
              inputName == "input", outputName == "output",
              let source = URL(string: sourceURL),
              source.scheme?.lowercased() == "https",
              let host = source.host, !host.isEmpty,
              // validated is a human assertion that the exact weight license,
              // numerical output and tiling were independently verified. It is
              // not permission to substitute the conversion code's license.
              // Unknown/UNRESOLVED licenses remain disabled regardless of it.
              ["CC-BY-NC-4.0", "CC-BY-NC-SA-4.0"].contains(license),
              weightSHA256.utf8.count == 64,
              weightSHA256.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
              tileSize == 128, overlap == 20, scale == 2,
              precision == "float32" || (preset == .color && precision == "float16") else {
            throw SuperResolutionError.invalidDescriptor
        }
        if let fullPage { try fullPage.validate() }

        if preset == .manga, minimumPageHeight == nil || maximumPageHeight == nil {
            throw SuperResolutionError.missingMangaHeightRange
        }
        switch (minimumPageHeight, maximumPageHeight) {
        case (nil, nil):
            break
        case let (minimum?, maximum?) where minimum > 0 && maximum >= minimum:
            break
        default:
            throw preset == .manga ? SuperResolutionError.invalidMangaHeightRange : SuperResolutionError.invalidDescriptor
        }
    }
}

nonisolated enum SuperResolutionError: LocalizedError, Equatable {
    case modelUnavailable
    case unsupportedOS
    case invalidDescriptor
    case missingMangaHeightRange
    case invalidMangaHeightRange
    case overlappingMangaRanges
    case noMangaModelForHeight
    case ambiguousColorModels
    case longPage
    case unsuitableMangaPage
    case invalidInput
    case budgetExceeded
    case insufficientStorage
    case modelDescriptionMismatch
    case modelLoadFailed
    case inferenceFailed
    case nonFiniteOutput
    case imageConversionFailed
    case outputWriteFailed
    case fullPageUnavailable
    case fullPagePageUnsupported

    var errorDescription: String? {
        switch self {
        case .modelUnavailable: "尚未安装或验证超分辨率模型；原图未修改。"
        case .unsupportedOS: "此超分模型需要 iOS 16 或更新系统；原图未修改。"
        case .invalidDescriptor: "超分模型描述文件无效或不符合要求；原图未修改。"
        case .missingMangaHeightRange: "漫画模型缺少明确的页面高度范围；原图未修改。"
        case .invalidMangaHeightRange: "漫画模型的页面高度范围无效；原图未修改。"
        case .overlappingMangaRanges: "已安装漫画模型的页面高度范围重叠，无法确定模型；原图未修改。"
        case .noMangaModelForHeight: "没有与原始页面高度匹配的已验证漫画模型；原图未修改。"
        case .ambiguousColorModels: "存在多个可用的彩色模型，无法确定模型；原图未修改。"
        case .longPage: "长条图片不适合本轮超分处理，已跳过；原图未修改。"
        case .unsuitableMangaPage: "横版或异常漫画页面不适合本轮超分处理，已跳过；原图未修改。"
        case .invalidInput: "无法处理此原图的像素或尺寸；原图未修改。"
        case .budgetExceeded: "图片超出本轮超分的尺寸或预估内存预算，已跳过；原图未修改。"
        case .insufficientStorage: "临时存储空间不足或无法检查，已跳过；原图未修改。"
        case .modelDescriptionMismatch: "模型的输入或输出名称、形状或类型不符合要求；原图未修改。"
        case .modelLoadFailed: "无法载入已验证的本地超分模型；原图未修改。"
        case .inferenceFailed: "超分模型推理失败；原图未修改。"
        case .nonFiniteOutput: "超分模型输出包含非有限数值；原图未修改。"
        case .imageConversionFailed: "无法创建超分所需的 sRGB 图片；原图未修改。"
        case .outputWriteFailed: "无法写入临时无损 PNG；原图未修改。"
        case .fullPageUnavailable: "此模型未声明或未验证整页推理能力；请改用分块模式。"
        case .fullPagePageUnsupported: "原页尺寸超出已验证的整页输入范围；未执行整页推理。"
        }
    }
}

/// Selection is deterministic and never derives model thresholds from a page.
nonisolated struct SuperResolutionModeResolution: Equatable, Sendable {
    let requested: SuperResolutionInferenceMode
    let actual: SuperResolutionInferenceMode
    /// Non-nil only when automatic mode deliberately stayed on tiled inference.
    let fallbackReason: String?
}

nonisolated enum SuperResolutionModelSelection {
    static func validatePage(width: Int, height: Int, preset: SuperResolutionPreset) throws {
        guard width > 0, height > 0 else { throw SuperResolutionError.invalidInput }
        // This also makes the long-page multiplication below safe.
        guard width <= 16_384, height <= 16_384 else { throw SuperResolutionError.budgetExceeded }
        guard height <= width * 4 else { throw SuperResolutionError.longPage }
        if preset == .manga, height <= width {
            throw SuperResolutionError.unsuitableMangaPage
        }
    }

    /// Explicit full page never silently degrades; automatic may fall back to
    /// tiled but records the user-visible reason.
    static func resolveMode(
        requested: SuperResolutionInferenceMode,
        model: SuperResolutionModel,
        width: Int,
        height: Int
    ) throws -> SuperResolutionModeResolution {
        switch requested {
        case .tiled:
            return SuperResolutionModeResolution(requested: .tiled, actual: .tiled, fallbackReason: nil)
        case .fullPage:
            guard let capability = model.fullPage, capability.validated else {
                throw SuperResolutionError.fullPageUnavailable
            }
            _ = try capability.inputDimensions(width: width, height: height)
            return SuperResolutionModeResolution(
                requested: .fullPage, actual: .fullPage, fallbackReason: nil)
        case .automatic:
            guard let capability = model.fullPage else {
                return SuperResolutionModeResolution(
                    requested: .automatic, actual: .tiled,
                    fallbackReason: "模型未声明整页推理能力，使用分块模式")
            }
            guard capability.validated else {
                return SuperResolutionModeResolution(
                    requested: .automatic, actual: .tiled,
                    fallbackReason: "整页推理能力尚未验证，使用分块模式")
            }
            do {
                _ = try capability.inputDimensions(width: width, height: height)
                return SuperResolutionModeResolution(
                    requested: .automatic, actual: .fullPage, fallbackReason: nil)
            } catch {
                return SuperResolutionModeResolution(
                    requested: .automatic, actual: .tiled,
                    fallbackReason: "原页尺寸超出整页输入范围，使用分块模式")
            }
        }
    }

    static func select(
        from models: [SuperResolutionModel],
        preset: SuperResolutionPreset,
        width: Int,
        height: Int
    ) throws -> SuperResolutionModel {
        try validatePage(width: width, height: height, preset: preset)
        let candidates = models.filter { $0.preset == preset && $0.validated }
        guard !candidates.isEmpty else { throw SuperResolutionError.modelUnavailable }
        for candidate in candidates { try candidate.validate() }
        guard Set(candidates.map(\.id)).count == candidates.count,
              Set(candidates.map(\.resourceName)).count == candidates.count else {
            throw SuperResolutionError.invalidDescriptor
        }

        switch preset {
        case .color:
            guard candidates.count == 1 else { throw SuperResolutionError.ambiguousColorModels }
            return candidates[0]
        case .manga:
            // validate() above guarantees both bounds exist and are ordered.
            let sorted = candidates.sorted { $0.minimumPageHeight! < $1.minimumPageHeight! }
            if sorted.count > 1 {
                for index in 1..<sorted.count {
                    if sorted[index].minimumPageHeight! <= sorted[index - 1].maximumPageHeight! {
                        throw SuperResolutionError.overlappingMangaRanges
                    }
                }
            }
            guard let chosen = sorted.first(where: {
                $0.minimumPageHeight! <= height && height <= $0.maximumPageHeight!
            }) else { throw SuperResolutionError.noMangaModelForHeight }
            return chosen
        }
    }
}
