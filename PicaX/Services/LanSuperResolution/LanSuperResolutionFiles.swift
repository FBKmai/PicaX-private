import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum LanSRFiles {
    static func root() throws -> URL {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw LanSRError.message("无法打开局域网任务目录。")
        }
        var root = base.appendingPathComponent("PicaX/LanSuperResolution", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try root.setResourceValues(values)
        return root
    }
    static func staging(jobID: String, pageID: String, result: Bool = false) throws -> URL {
        guard LanSRContract.isUUID(jobID), pageID.range(of: "^e[0-9]{4}-p[0-9]{4}$", options: .regularExpression) != nil else {
            throw LanSRError.message("本地任务标识无效。")
        }
        let directory = try root().appendingPathComponent(jobID, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(pageID)-\(result ? "result" : "source").part")
    }
    static func hash(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let block = try file.read(upToCount: 256 * 1024), !block.isEmpty { hash.update(data: block) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func size(_ url: URL) throws -> Int { try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 }
    static func checkSpace(at url: URL, required: Int64) throws {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: url.path)
        guard let free = attributes[.systemFreeSize] as? NSNumber, free.int64Value > required + 64 * 1024 * 1024 else {
            throw LanSRError.message("手机剩余空间不足，任务已暂停。")
        }
    }

    static func export(sourceURL: URL, destination: URL, chapter: Int, chapterTitle: String, page: Int,
                       model: LanSRModelCapability, scale: Int) async throws -> LanSRPage {
        guard sourceURL.picaxLocalFileURL != nil else { throw LanSRError.message("只允许发送已下载的本地页面。") }
        let source = try await ReaderImageSourceLoader.load(url: sourceURL)
        let task = Task.detached(priority: .utility) {
            let width = source.dimensions.width, height = source.dimensions.height
            try model.validatePage(width: width, height: height, scale: scale)
            try checkSpace(at: destination.deletingLastPathComponent(), required: Int64(width * height * 8))
            try Task.checkCancellation()
            let bytes = try SuperResolutionService.makeSRGBPixels(image: source.image, byteCount: width * height * 4)
            let image = try SuperResolutionService.makeOutputImage(bytes: bytes, width: width, height: height)
            guard let encoder = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                throw LanSRError.message("无法创建上传 PNG。")
            }
            CGImageDestinationAddImage(encoder, image, nil)
            guard CGImageDestinationFinalize(encoder) else { throw LanSRError.message("写入上传 PNG 失败。") }
            try Task.checkCancellation()
            let count = try size(destination)
            guard count > 0, count <= LanSRContract.maximumInputBytes else { throw LanSRError.message("规范化 PNG 超过 64 MiB。") }
            return LanSRPage(id: LanSRContract.pageID(chapter: chapter, page: page), chapterIndex: chapter,
                             chapterTitle: chapterTitle, pageIndex: page, width: width, height: height,
                             bytes: count, sha256: try hash(destination))
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    static func validateResultFile(_ url: URL, result: LanSRResult) throws {
        guard try size(url) == result.bytes, try hash(url) == result.sha256 else {
            throw LanSRError.message("结果文件大小或 SHA-256 不匹配，未导入。")
        }
        let file = try FileHandle(forReadingFrom: url)
        let header = try file.read(upToCount: 33) ?? Data()
        try file.close()
        let bytes = Array(header)
        guard bytes.count == 33, Array(bytes[0..<8]) == [137, 80, 78, 71, 13, 10, 26, 10],
              Array(bytes[8..<16]) == [0, 0, 0, 13, 73, 72, 68, 82], bytes[24] == 8,
              [2, 6].contains(bytes[25]), bytes[26] == 0, bytes[27] == 0, bytes[28] <= 1 else {
            throw LanSRError.message("结果不是受支持的 RGB PNG。")
        }
        func integer(_ offset: Int) -> Int { bytes[offset..<(offset + 4)].reduce(0) { $0 * 256 + Int($1) } }
        guard integer(16) == result.width, integer(20) == result.height,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == result.width,
              (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == result.height else {
            throw LanSRError.message("结果 PNG 的实际尺寸不匹配。")
        }
    }

    static func discard(_ url: URL) { try? FileManager.default.removeItem(at: url) }
}
