import Foundation
import Darwin

nonisolated enum LanSRError: LocalizedError {
    case message(String)
    case http(Int, String)
    var errorDescription: String? {
        switch self {
        case .message(let text): text
        case .http(let status, let text): "电脑返回 \(status)：\(text)"
        }
    }
}

nonisolated enum LanSRContract {
    static let maximumJSON = 8 * 1024 * 1024
    static let maximumInputBytes = 64 * 1024 * 1024
    static let maximumOutputBytes = 128 * 1024 * 1024
    static let maximumOutputPixels = 32_000_000
    static let models: [String: (sha: String, scale: Int)] = [
        "illustrationjanai-v3detail-hat-l-4x-float32": ("38c00c9ff871ae292617ae1127edc150f81c4e0f8f98685e48ff9c9cd87fba3b", 4),
        "illustrationjanai-v3denoise-dat2-4x-float32": ("430d5e58053be88d250b6ee2c1016a19f919baafb9b6bda0f45c14b54453fb12", 4),
        "illustrationjanai-v3detail-fdat-xl-4x-float32": ("fbafec1f5a126c251de8a21e177e5a710ba2e75c7fd88fe989eb8df0508790c9", 4),
        "illustrationjanai-v3detail-fdat-m-2x-float32": ("8ff2ba0b970e6939f3711077f5260fcded16b8388a939a27f153c687ff5da3e0", 2)
    ]
    static func isSHA(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func isUUID(_ value: String) -> Bool { UUID(uuidString: value)?.uuidString.lowercased() == value }
    static func isLAN(_ host: String) -> Bool {
        // Literal addresses only: no DNS rebinding, URL credentials or public hosts.
        var v4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            let bytes = withUnsafeBytes(of: v4) { Array($0) }
            return bytes[0] == 10 || (bytes[0] == 172 && (16...31).contains(bytes[1]))
                || (bytes[0] == 192 && bytes[1] == 168) || (bytes[0] == 169 && bytes[1] == 254)
        }
        var v6 = in6_addr()
        if host.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 {
            let bytes = withUnsafeBytes(of: v6) { Array($0) }
            return bytes[0] & 0xfe == 0xfc || (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80)
        }
        return false
    }
    static func pageID(chapter: Int, page: Int) -> String {
        String(format: "e%04d-p%04d", chapter, page)
    }
    static func readme(modelID: String, modelSHA256: String, nativeScale: Int, deliveryScale: Int) -> String {
        """
        PicaX LAN AI super-resolution
        Model: \(modelID)
        SHA-256: \(modelSHA256)
        Native: \(nativeScale)x; delivered: \(deliveryScale)x
        \(deliveryScale < nativeScale ? "Lanczos downsampling after AI inference" : "Native AI output")
        Per-page engine/device/versions (when complete): LAN-SuperResolution.json
        Author: the-database
        Source: https://github.com/the-database/MangaJaNai/releases/tag/3.0.0
        License: CC-BY-NC-4.0 https://creativecommons.org/licenses/by-nc/4.0/
        Original downloads are unchanged. Partial exports contain only the available pages.

        """
    }
}

nonisolated struct LanSRPairingPayload: Codable, Sendable {
    let version: Int
    let host: String
    let port: Int
    let serverID: String
    let certificateSHA256: String
    let pairingSecret: String
    let expiresAt: Double

    static func parse(_ text: String, now: Date = Date()) throws -> Self {
        guard text.utf8.count <= 4096 else { throw LanSRError.message("连接信息过长。") }
        let value = try JSONDecoder().decode(Self.self, from: Data(text.utf8))
        guard value.version == 1, LanSRContract.isLAN(value.host), (1...65535).contains(value.port),
              LanSRContract.isUUID(value.serverID), LanSRContract.isSHA(value.certificateSHA256),
              (32...128).contains(value.pairingSecret.utf8.count),
              value.pairingSecret.utf8.allSatisfy({ (45...122).contains($0) && ($0 == 45 || $0 == 95 || (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)) }),
              value.expiresAt.isFinite, value.expiresAt > now.timeIntervalSince1970,
              value.expiresAt <= now.timeIntervalSince1970 + 600 else {
            throw LanSRError.message("连接信息无效或已过期；请在电脑重新显示配对二维码。")
        }
        return value
    }
}

nonisolated struct LanSRServer: Codable, Equatable, Sendable {
    let host: String
    let port: Int
    let serverID: String
    let certificateSHA256: String
    var address: String { "\(host):\(port)" }
    func url(path: String) throws -> URL {
        guard LanSRContract.isLAN(host), (1...65535).contains(port),
              LanSRContract.isUUID(serverID), LanSRContract.isSHA(certificateSHA256),
              path.hasPrefix("/v1/"), !path.contains(".."), !path.contains("?"), !path.contains("#") else {
            throw LanSRError.message("拒绝无效的电脑地址或路径。")
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host.contains(":") ? "[\(host)]" : host
        components.port = port
        components.path = path
        guard let url = components.url else { throw LanSRError.message("无法生成局域网地址。") }
        return url
    }
}

nonisolated struct LanSRCredential: Codable, Sendable {
    let server: LanSRServer
    let clientID: String
    let token: String
}

nonisolated struct LanSRModelCapability: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let sha256: String
    let nativeScale: Int
    let deliveryScales: [Int]
    let alignment: Int
    let minimumSide: Int
    let maximumSide: Int
    let maximumInputPixels: Int
    let precision: String
    let mode: String
    let ready: Bool
    let error: String?

    func validate() throws {
        guard let known = LanSRContract.models[id], known.sha == sha256, known.scale == nativeScale,
              !deliveryScales.isEmpty, Set(deliveryScales).isSubset(of: nativeScale == 4 ? [2, 4] : [2]),
              [16, 64].contains(alignment), minimumSide == 64,
              (64...8192).contains(maximumSide), (4096...8_000_000).contains(maximumInputPixels),
              precision == "float32", mode == "fullPage" else {
            throw LanSRError.message("电脑模型配置与手机允许列表不匹配。")
        }
    }
    func validatePage(width: Int, height: Int, scale: Int) throws {
        try validate()
        guard width > 0, height > 0, width <= maximumSide, height <= maximumSide, deliveryScales.contains(scale) else {
            throw LanSRError.message("页面尺寸或回传倍率不受当前模型支持。")
        }
        let pw = max(64, (width + alignment - 1) / alignment * alignment)
        let ph = max(64, (height + alignment - 1) / alignment * alignment)
        guard pw <= maximumSide, ph <= maximumSide, pw * ph <= maximumInputPixels,
              pw * ph * nativeScale * nativeScale <= 64_000_000,
              max(width, height) * scale <= 16384,
              width * height * scale * scale <= LanSRContract.maximumOutputPixels else {
            throw LanSRError.message("页面超出所选模型的整页/回传像素预算；原图未修改。")
        }
    }
}

nonisolated struct LanSRCapabilities: Decodable, Sendable {
    let version: Int
    let serverID: String
    let models: [LanSRModelCapability]
    let defaultModelID: String?
    let defaultDeliveryScale: Int
}

nonisolated struct LanSRPage: Codable, Equatable, Sendable {
    let id: String
    let chapterIndex: Int
    let chapterTitle: String
    let pageIndex: Int
    let width: Int
    let height: Int
    let bytes: Int
    let sha256: String
}

nonisolated struct LanSRJobSpec: Codable, Sendable {
    let version: Int
    let jobID: String
    let sourceRecordID: String
    let title: String
    let modelID: String
    let modelSHA256: String
    let nativeScale: Int
    let deliveryScale: Int
    let mode: String
    let pages: [LanSRPage]
}

nonisolated struct LanSRResult: Codable, Sendable {
    let modelID: String
    let modelSHA256: String
    let nativeScale: Int
    let deliveryScale: Int
    let width: Int
    let height: Int
    let bytes: Int
    let sha256: String
    let engine: String
    let device: String
    let deviceName: String
    let precision: String
    let torchVersion: String
    let cudaVersion: String
    let license: String
    let sourceURL: String
    let mode: String
    let downsampling: String
    let seconds: Double

    func validate(spec: LanSRJobSpec, page: LanSRPage) throws {
        guard modelID == spec.modelID, modelSHA256 == spec.modelSHA256,
              nativeScale == spec.nativeScale, deliveryScale == spec.deliveryScale,
              width == page.width * deliveryScale, height == page.height * deliveryScale,
              (1...LanSRContract.maximumOutputBytes).contains(bytes), LanSRContract.isSHA(sha256),
              width > 0, height > 0, max(width, height) <= 16384,
              width * height <= LanSRContract.maximumOutputPixels,
              engine == "PyTorch", ["cuda", "cpu"].contains(device), precision == "float32", mode == "fullPage",
              license == "CC-BY-NC-4.0", sourceURL == "https://github.com/the-database/MangaJaNai/releases/tag/3.0.0",
              downsampling == (deliveryScale < nativeScale ? "lanczos" : "none"), seconds.isFinite, seconds >= 0 else {
            throw LanSRError.message("电脑结果的模型、倍率或尺寸校验失败，未导入。")
        }
    }
}

nonisolated struct LanSRPageStatus: Decodable, Sendable {
    let id: String
    let state: String
    let result: LanSRResult?
    let error: String?
    let acknowledged: Bool
}
nonisolated struct LanSRJobStatus: Decodable, Sendable {
    let jobID: String
    let state: String
    let pages: [LanSRPageStatus]

    func validate(spec: LanSRJobSpec) throws {
        guard jobID == spec.jobID,
              ["uploading", "queued", "running", "partial", "completed", "acknowledged", "cancelled"].contains(state),
              pages.count == spec.pages.count, Set(pages.map(\.id)).count == pages.count,
              Set(pages.map(\.id)) == Set(spec.pages.map(\.id)) else {
            throw LanSRError.message("电脑任务的状态或页面清单与手机不一致。")
        }
        let expected = Dictionary(uniqueKeysWithValues: spec.pages.map { ($0.id, $0) })
        for page in pages {
            guard ["missing", "uploaded", "running", "succeeded", "failed"].contains(page.state),
                  !page.acknowledged || page.state == "succeeded" else {
                throw LanSRError.message("电脑返回无效的页面状态。")
            }
            if page.state == "succeeded" {
                guard let result = page.result, let original = expected[page.id] else {
                    throw LanSRError.message("成功页面缺少结果元数据。")
                }
                try result.validate(spec: spec, page: original)
            }
        }
    }
}

// Local-only journal values. ComicChapter remains the existing main-actor type.
struct LanSRLocalJob: Codable, Identifiable {
    let id: String
    let serverID: String
    let sourceRecordID: String
    let title: String
    let chapters: [ComicChapter]
    let sourceChapterIndexes: [Int]
    let pageCounts: [Int]
    let model: LanSRModelCapability
    let deliveryScale: Int
    var spec: LanSRJobSpec?
    var prepared: [LanSRPage] = []
    var sourceURLs: [String: String] = [:]
    var imported: [String: String] = [:]
    var results: [String: LanSRResult] = [:]
    var phase = "准备中"
    var message = ""
    var finished = false
    var targetCreated = false
    var submitted = false
    var cancelRequested = false
    var retryRequested = false

    func validateJournal() throws {
        guard LanSRContract.isUUID(id), LanSRContract.isUUID(serverID),
              !chapters.isEmpty, chapters.count <= 4096,
              chapters.count == sourceChapterIndexes.count, chapters.count == pageCounts.count,
              Set(sourceChapterIndexes).count == sourceChapterIndexes.count,
              sourceChapterIndexes.allSatisfy({ (0...9999).contains($0) }),
              pageCounts.allSatisfy({ (1...4096).contains($0) }),
              pageCounts.reduce(0, +) <= 4096,
              model.deliveryScales.contains(deliveryScale),
              prepared.count <= pageCounts.reduce(0, +), Set(prepared.map(\.id)).count == prepared.count else {
            throw LanSRError.message("局域网任务日志中的章节或页数无效，已停止恢复。")
        }
        try model.validate()
        for page in prepared {
            guard chapters.indices.contains(page.chapterIndex),
                  (0..<pageCounts[page.chapterIndex]).contains(page.pageIndex),
                  page.id == LanSRContract.pageID(chapter: page.chapterIndex, page: page.pageIndex),
                  (1...LanSRContract.maximumInputBytes).contains(page.bytes), LanSRContract.isSHA(page.sha256) else {
                throw LanSRError.message("局域网任务日志中的页面映射无效。")
            }
            try model.validatePage(width: page.width, height: page.height, scale: deliveryScale)
        }
        if let spec {
            guard spec.version == 1, spec.jobID == id, spec.sourceRecordID == sourceRecordID,
                  spec.modelID == model.id, spec.modelSHA256 == model.sha256,
                  spec.nativeScale == model.nativeScale, spec.deliveryScale == deliveryScale,
                  spec.mode == "fullPage", spec.pages.count == pageCounts.reduce(0, +),
                  spec.pages == prepared.sorted(by: { $0.id < $1.id }) else {
                throw LanSRError.message("局域网任务日志中的协议清单不匹配。")
            }
        } else if submitted || !imported.isEmpty || !results.isEmpty {
            throw LanSRError.message("局域网任务日志缺少已提交的页面清单。")
        }
        let ids = Set(prepared.map(\.id))
        guard Set(sourceURLs.keys) == ids, Set(imported.keys).isSubset(of: ids),
              Set(results.keys).isSubset(of: ids), imported.values.allSatisfy(LanSRContract.isSHA) else {
            throw LanSRError.message("局域网任务日志中的来源或结果映射无效。")
        }
        if let spec {
            let pages = Dictionary(uniqueKeysWithValues: spec.pages.map { ($0.id, $0) })
            for (id, result) in results {
                guard let page = pages[id] else { throw LanSRError.message("结果日志缺少页面映射。") }
                try result.validate(spec: spec, page: page)
            }
        }
        guard imported.allSatisfy({ results[$0.key]?.sha256 == $0.value }) else {
            throw LanSRError.message("已收取页面的日志与结果散列不匹配。")
        }
    }
}
