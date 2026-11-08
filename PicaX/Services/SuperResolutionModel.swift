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
        }
    }
}

/// Selection is deterministic and never derives model thresholds from a page.
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
