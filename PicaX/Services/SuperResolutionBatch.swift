import Combine
import CoreGraphics
import Foundation

nonisolated enum ReaderBatchRenderScope: String, CaseIterable, Codable, Identifiable, Sendable, Hashable {
    case currentChapter
    case wholeBook

    var id: String { rawValue }

    var title: String {
        switch self {
        case .currentChapter: "当前章节"
        case .wholeBook: "整本（全部章节）"
        }
    }

    func chapterIndices(totalChapters: Int, currentChapterIndex: Int) -> [Int] {
        guard totalChapters > 0 else { return [] }
        switch self {
        case .currentChapter:
            return [min(max(currentChapterIndex, 0), totalChapters - 1)]
        case .wholeBook:
            return Array(0..<totalChapters)
        }
    }
}

nonisolated enum ReaderBatchRenderPhase: String, Codable, Sendable {
    case idle
    case running
    case cancelling
    case completed
    case cancelled
    case failed

    var title: String {
        switch self {
        case .idle: "未开始"
        case .running: "渲染中"
        case .cancelling: "取消中"
        case .completed: "已完成"
        case .cancelled: "已取消"
        case .failed: "已停止"
        }
    }
}

nonisolated enum ReaderBatchRenderPageStatus: String, Codable, Sendable {
    case succeeded
    case skipped
    case failed

    var title: String {
        switch self {
        case .succeeded: "成功"
        case .skipped: "跳过"
        case .failed: "失败"
        }
    }
}

nonisolated enum ReaderBatchRenderChapterStatus: String, Codable, Sendable {
    case succeeded
    case failed
}

nonisolated struct ReaderBatchRenderPageRecord: Codable, Equatable, Identifiable, Sendable {
    let chapterIndex: Int
    let chapterTitle: String
    let pageIndex: Int
    let sourceURLString: String
    var status: ReaderBatchRenderPageStatus = .failed
    var fileName: String? = nil
    var sourceWidth: Int? = nil
    var sourceHeight: Int? = nil
    var outputWidth: Int? = nil
    var outputHeight: Int? = nil
    var modelID: String? = nil
    var modelDisplayName: String? = nil
    var modelVersion: String? = nil
    var modelPrecision: String? = nil
    var requestedMode: String? = nil
    var actualMode: String? = nil
    var computeUnit: String? = nil
    var paddedInputWidth: Int? = nil
    var paddedInputHeight: Int? = nil
    var outputByteCount: Int? = nil
    var elapsedSeconds: Double? = nil
    var fallbackReason: String? = nil
    var errorDescription: String? = nil

    var id: String { "\(chapterIndex)-\(pageIndex)" }
}

nonisolated struct ReaderBatchRenderChapterRecord: Codable, Equatable, Identifiable, Sendable {
    let chapterIndex: Int
    let title: String
    var pageCount: Int = 0
    var status: ReaderBatchRenderChapterStatus = .failed
    var errorDescription: String? = nil

    var id: Int { chapterIndex }
}

nonisolated struct ReaderBatchRenderManifest: Codable, Equatable, Sendable {
    static let currentFormatVersion = 1

    let formatVersion: Int
    let bookID: String
    let bookTitle: String
    let scope: ReaderBatchRenderScope
    let preset: String
    let requestedMode: String
    let computeUnit: String
    let createdAt: Date
    var finishedAt: Date? = nil
    var status: ReaderBatchRenderPhase = .running
    var chapters: [ReaderBatchRenderChapterRecord] = []
    var pages: [ReaderBatchRenderPageRecord] = []

    init(
        bookID: String,
        bookTitle: String,
        scope: ReaderBatchRenderScope,
        preset: String,
        requestedMode: String,
        computeUnit: String,
        createdAt: Date
    ) {
        self.formatVersion = Self.currentFormatVersion
        self.bookID = bookID
        self.bookTitle = bookTitle
        self.scope = scope
        self.preset = preset
        self.requestedMode = requestedMode
        self.computeUnit = computeUnit
        self.createdAt = createdAt
    }
}

nonisolated enum ReaderBatchRenderError: LocalizedError, Equatable {
    case documentsUnavailable
    case outputDirectoryUnavailable
    case manifestWriteFailed
    case outputFileExists(String)
    case outputFileMissing(String)
    case outputWriteFailed
    case noOutputFiles
    case archiveFailed
    case invalidPageURL

    var errorDescription: String? {
        switch self {
        case .documentsUnavailable:
            "无法访问 App 的文稿目录；批量结果未写入。"
        case .outputDirectoryUnavailable:
            "批量输出目录不可用；已停止并保留原图。"
        case .manifestWriteFailed:
            "无法写入批量清单；已停止并保留已完成页面。"
        case .outputFileExists(let name):
            "批量输出已存在同名文件：\(name)；未覆盖。"
        case .outputFileMissing(let name):
            "批量结果缺少文件：\(name)；未继续打包。"
        case .outputWriteFailed:
            "无法把页面结果写入批量目录；该页未标记成功。"
        case .noOutputFiles:
            "没有可打包的批量结果。"
        case .archiveFailed:
            "无法生成批量 ZIP；原 PNG 仍保留在输出目录。"
        case .invalidPageURL:
            "页面地址无效，未读取或推理；原图未修改。"
        }
    }
}

nonisolated enum ReaderBatchRenderStore {
    static let rootFolderName = "SuperResolution"
    static let manifestName = "manifest.json"
    static let readmeName = "README.txt"
    static let exportFolderName = "PicaX-SuperResolutionExports"

    static func pageFileName(chapterIndex: Int, pageIndex: Int) -> String {
        String(format: "E%03d-P%04d.png", chapterIndex + 1, pageIndex + 1)
    }

    static func archiveFileName(bookTitle: String) -> String {
        "PicaX-\(safeFileName(bookTitle))-2x.zip"
    }

    static func safeFileName(_ value: String, maximumLength: Int = 80) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\?%*|\"<>:")
            .union(.newlines)
            .union(.controlCharacters)
        let cleaned = value
            .components(separatedBy: invalidCharacters)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "untitled" }
        // Limit by UTF-8 bytes, not Characters: 80 CJK characters would be
        // 240 bytes before the timestamp suffix and can exceed NAME_MAX.
        var result = ""
        for character in cleaned {
            let candidate = result + String(character)
            guard candidate.utf8.count <= maximumLength else { break }
            result = candidate
        }
        return result.isEmpty ? "untitled" : result
    }

    static func createOutputDirectory(
        bookTitle: String,
        now: Date = Date(),
        root: URL? = nil
    ) throws -> URL {
        let fileManager = FileManager.default
        let baseRoot: URL
        if let root {
            baseRoot = root
        } else {
            guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
                throw ReaderBatchRenderError.documentsUnavailable
            }
            baseRoot = documents.appendingPathComponent(rootFolderName, isDirectory: true)
        }
        do {
            try fileManager.createDirectory(at: baseRoot, withIntermediateDirectories: true)
        } catch {
            throw ReaderBatchRenderError.documentsUnavailable
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let baseName = "\(safeFileName(bookTitle))-\(formatter.string(from: now))"
        var directory = baseRoot.appendingPathComponent(baseName, isDirectory: true)
        if fileManager.fileExists(atPath: directory.path) {
            directory = baseRoot.appendingPathComponent(
                "\(baseName)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        } catch {
            throw ReaderBatchRenderError.outputDirectoryUnavailable
        }
        return directory
    }

    static func writeManifest(_ manifest: ReaderBatchRenderManifest, to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(manifest)
            try data.write(
                to: directory.appendingPathComponent(manifestName, isDirectory: false),
                options: .atomic)
        } catch {
            throw ReaderBatchRenderError.manifestWriteFailed
        }
    }

    static func writeReadme(_ text: String, to directory: URL) throws {
        do {
            try Data(text.utf8).write(
                to: directory.appendingPathComponent(readmeName, isDirectory: false),
                options: .atomic)
        } catch {
            throw ReaderBatchRenderError.outputWriteFailed
        }
    }

    static func readmeText(
        bookTitle: String,
        scope: ReaderBatchRenderScope,
        preset: SuperResolutionPreset,
        requestedMode: SuperResolutionInferenceMode,
        chapterCount: Int,
        createdAt: Date
    ) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return """
        PicaX 整本 2x 超分输出

        漫画：\(bookTitle)
        范围：\(scope.title)（\(chapterCount) 章）
        模型预设：\(preset.title)
        请求推理模式：\(requestedMode.title)
        计算单元：仅 CPU（固定；批量不使用 CPU+GPU/全部）
        开始时间：\(formatter.string(from: createdAt))

        本目录的 PNG 是逐页 Core ML 输出，原图未被覆盖或修改。
        每页实际模型、版本、精度、输入/输出尺寸、耗时、回退原因和失败原因
        见 manifest.json。标记为 skipped/failed 的页面没有生成 PNG。

        仅限个人非商业使用。模型署名与许可（彩色模型为 CC BY-NC 4.0）
        见应用内的 SuperResolutionAttribution.txt。
        """
    }

    /// Move a completed service trial into the retained batch directory. The
    /// service always writes under PicaX-SuperResolutionTrials; only that
    /// app-generated directory is ever removed.
    static func retainOutput(_ outputURL: URL, in directory: URL, fileName: String) throws -> Int {
        let fileManager = FileManager.default
        guard fileName == safeFileName(fileName), !fileName.isEmpty else {
            throw ReaderBatchRenderError.outputWriteFailed
        }
        let destination = directory.appendingPathComponent(fileName, isDirectory: false)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw ReaderBatchRenderError.outputFileExists(fileName)
        }

        do {
            try fileManager.moveItem(at: outputURL, to: destination)
            removeTrialDirectory(outputURL.deletingLastPathComponent())
        } catch {
            do {
                try fileManager.copyItem(at: outputURL, to: destination)
            } catch {
                throw ReaderBatchRenderError.outputWriteFailed
            }
            removeTrialDirectory(outputURL.deletingLastPathComponent())
        }

        let values = try destination.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0 else {
            try? fileManager.removeItem(at: destination)
            throw ReaderBatchRenderError.outputWriteFailed
        }
        return size
    }

    static func makeArchive(
        directory: URL,
        fileNames: [String],
        archiveName: String
    ) throws -> URL {
        let fileManager = FileManager.default
        var entries: [StoredZipFileEntry] = []
        var seen = Set<String>()
        for name in [manifestName, readmeName] + fileNames {
            guard seen.insert(name).inserted else { continue }
            guard !name.isEmpty, name == (name as NSString).lastPathComponent else {
                throw ReaderBatchRenderError.outputFileMissing(name)
            }
            let url = directory.appendingPathComponent(name, isDirectory: false)
            guard fileManager.fileExists(atPath: url.path) else {
                if name == manifestName || name == readmeName { continue }
                throw ReaderBatchRenderError.outputFileMissing(name)
            }
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, let size = values.fileSize, size > 0 else {
                throw ReaderBatchRenderError.outputFileMissing(name)
            }
            entries.append(StoredZipFileEntry(
                path: name, fileURL: url, size: UInt64(size)))
        }
        guard !entries.isEmpty else { throw ReaderBatchRenderError.noOutputFiles }

        let container = fileManager.temporaryDirectory
            .appendingPathComponent(exportFolderName, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(at: container, withIntermediateDirectories: true)
        } catch {
            throw ReaderBatchRenderError.archiveFailed
        }
        let outputURL = container.appendingPathComponent(
            safeFileName(archiveName, maximumLength: 200), isDirectory: false)
        do {
            try StoredZipArchive.makeArchive(entries: [], fileEntries: entries, at: outputURL)
            return outputURL
        } catch {
            try? fileManager.removeItem(at: container)
            throw ReaderBatchRenderError.archiveFailed
        }
    }

    static func removeTemporaryArchive(_ url: URL) {
        let fileManager = FileManager.default
        let container = url.deletingLastPathComponent()
        let root = fileManager.temporaryDirectory
            .appendingPathComponent(exportFolderName, isDirectory: true)
            .standardizedFileURL
        guard container.deletingLastPathComponent().standardizedFileURL == root else { return }
        try? fileManager.removeItem(at: container)
    }

    /// Remove only the service-owned trial directory for a result that was
    /// produced after cancellation but never retained in the batch folder.
    static func discardTrialOutput(_ outputURL: URL) {
        removeTrialDirectory(outputURL.deletingLastPathComponent())
    }

    private static func removeTrialDirectory(_ directory: URL) {
        guard directory.deletingLastPathComponent().lastPathComponent == "PicaX-SuperResolutionTrials" else {
            return
        }
        try? FileManager.default.removeItem(at: directory)
    }
}

struct ReaderBatchRenderRequest: Identifiable {
    let id = UUID()
    let bookID: String
    let bookTitle: String
    let chapters: [ComicChapter]
    let initialChapterIndex: Int
    let loadChapterImages: @MainActor (Int) async throws -> [ComicChapterImage]
}

@MainActor
final class ReaderBatchRenderModel: ObservableObject {
    @Published private(set) var phase: ReaderBatchRenderPhase = .idle
    @Published private(set) var scope: ReaderBatchRenderScope = .wholeBook
    @Published private(set) var preset: SuperResolutionPreset = .color
    @Published private(set) var requestedMode: SuperResolutionInferenceMode = .automatic
    @Published private(set) var message = "尚未开始；不会修改下载原图。"
    @Published private(set) var fatalMessage: String?
    @Published private(set) var chapterRecords: [ReaderBatchRenderChapterRecord] = []
    @Published private(set) var pageRecords: [ReaderBatchRenderPageRecord] = []
    @Published private(set) var pageSuccessCount = 0
    @Published private(set) var pageSkippedCount = 0
    @Published private(set) var pageFailureCount = 0
    @Published private(set) var currentChapterOrdinal = 0
    @Published private(set) var currentChapterTitle = ""
    @Published private(set) var currentPageOrdinal = 0
    @Published private(set) var currentChapterPageCount = 0
    @Published private(set) var scopeChapterCount = 0
    @Published private(set) var currentPageProgress = 0.0
    @Published private(set) var overallProgress = 0.0
    @Published private(set) var elapsedSeconds = 0.0
    @Published private(set) var outputDirectory: URL?
    @Published private(set) var archiveURL: URL?
    @Published private(set) var archiveMessage: String?
    @Published private(set) var isArchiving = false

    private(set) var request: ReaderBatchRenderRequest?
    private var task: Task<Void, Never>?
    private var archiveTask: Task<Void, Never>?
    private var manifest: ReaderBatchRenderManifest?
    private var batchStartedAt: Date?

    var isRunning: Bool {
        phase == .running || phase == .cancelling
    }

    var elapsedText: String {
        let total = max(Int(elapsedSeconds.rounded()), 0)
        let minutes = total / 60
        let seconds = total % 60
        return minutes > 0 ? "\(minutes) 分 \(seconds) 秒" : "\(seconds) 秒"
    }

    var problemPageRecords: [ReaderBatchRenderPageRecord] {
        pageRecords.filter { $0.status != .succeeded }
    }

    var failedChapterRecords: [ReaderBatchRenderChapterRecord] {
        chapterRecords.filter { $0.status == .failed }
    }

    func prepare(request: ReaderBatchRenderRequest) {
        guard self.request == nil else { return }
        self.request = request
        message = request.chapters.isEmpty
            ? "当前漫画没有章节，无法批量渲染。"
            : "尚未开始；不会修改下载原图。"
    }

    func start(
        scope: ReaderBatchRenderScope,
        preset: SuperResolutionPreset,
        mode: SuperResolutionInferenceMode
    ) {
        guard let request, !isRunning else { return }
        let indices = scope.chapterIndices(
            totalChapters: request.chapters.count,
            currentChapterIndex: request.initialChapterIndex)
        guard !indices.isEmpty else {
            phase = .failed
            fatalMessage = "没有可处理的章节。"
            message = "没有可处理的章节；原图未修改。"
            return
        }

        resetBatchState()
        self.scope = scope
        self.preset = preset
        requestedMode = mode
        scopeChapterCount = indices.count
        currentChapterTitle = request.chapters[min(
            max(request.initialChapterIndex, 0), request.chapters.count - 1)].title
        phase = .running
        message = "正在创建输出目录…"
        batchStartedAt = Date()
        elapsedSeconds = 0

        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.run(
                    request: request, indices: indices, scope: scope, preset: preset, mode: mode)
            } catch is CancellationError {
                self.finalizeManifest(status: .cancelled)
                self.phase = .cancelled
                self.message = "已取消：\(self.pageSuccessCount) 页已完成并保留；已完成页面不会标记为失败。"
            } catch {
                self.finalizeManifest(status: .failed)
                self.phase = .failed
                self.fatalMessage = error.localizedDescription
                self.message = "批量渲染停止：\(error.localizedDescription)"
            }
            self.refreshElapsed()
            self.currentPageProgress = 0
            self.task = nil
        }
    }

    func cancel() {
        guard phase == .running else { return }
        phase = .cancelling
        message = "正在取消；当前 Core ML 调用返回后停止。已完成页面会保留。"
        task?.cancel()
    }

    func resetForNewBatch() {
        guard !isRunning else { return }
        resetBatchState()
        message = request?.chapters.isEmpty == false
            ? "尚未开始；不会修改下载原图。"
            : "当前漫画没有章节，无法批量渲染。"
    }

    func prepareArchive() {
        guard let directory = outputDirectory,
              !isRunning,
              !isArchiving,
              archiveURL == nil,
              pageRecords.contains(where: { $0.fileName != nil }) else {
            return
        }
        isArchiving = true
        archiveMessage = "正在打包 ZIP…"
        let fileNames = pageRecords.compactMap(\.fileName)
        let archiveName = ReaderBatchRenderStore.archiveFileName(
            bookTitle: request?.bookTitle ?? "PicaX")
        archiveTask = Task { [weak self] in
            let url: URL
            do {
                url = try await Task.detached(priority: .userInitiated) {
                    try ReaderBatchRenderStore.makeArchive(
                        directory: directory, fileNames: fileNames, archiveName: archiveName)
                }.value
            } catch {
                self?.isArchiving = false
                self?.archiveMessage = "ZIP 生成失败：\(error.localizedDescription)"
                return
            }
            guard let self else {
                ReaderBatchRenderStore.removeTemporaryArchive(url)
                return
            }
            self.isArchiving = false
            if Task.isCancelled {
                ReaderBatchRenderStore.removeTemporaryArchive(url)
                return
            }
            self.archiveURL = url
            self.archiveMessage = "ZIP 已生成；可在分享面板保存到文件 App。"
            self.archiveTask = nil
        }
    }

    func discardTemporaryArchive() {
        archiveTask?.cancel()
        archiveTask = nil
        isArchiving = false
        if let archiveURL {
            ReaderBatchRenderStore.removeTemporaryArchive(archiveURL)
            self.archiveURL = nil
        }
    }

    nonisolated static func isSkipped(_ error: Error) -> Bool {
        if let error = error as? SuperResolutionError {
            switch error {
            case .fullPagePageUnsupported, .longPage, .unsuitableMangaPage,
                 .budgetExceeded, .insufficientStorage:
                return true
            default:
                return false
            }
        }
        if let error = error as? ReaderImageSourceError, case .budgetExceeded = error {
            return true
        }
        return false
    }

    /// Model/OS/storage failures will repeat for every page; abort instead of
    /// walking through an entire book producing identical failed records.
    nonisolated static func isFatal(_ error: Error) -> Bool {
        guard let error = error as? SuperResolutionError else { return false }
        switch error {
        case .modelUnavailable, .modelLoadFailed, .unsupportedOS,
             .modelDescriptionMismatch, .fullPageUnavailable, .insufficientStorage:
            return true
        default:
            return false
        }
    }

    private func run(
        request: ReaderBatchRenderRequest,
        indices: [Int],
        scope: ReaderBatchRenderScope,
        preset: SuperResolutionPreset,
        mode: SuperResolutionInferenceMode
    ) async throws {
        let clock = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.isRunning else { return }
                self.refreshElapsed()
            }
        }
        defer {
            clock.cancel()
            refreshElapsed()
        }

        let directory = try ReaderBatchRenderStore.createOutputDirectory(
            bookTitle: request.bookTitle)
        outputDirectory = directory
        try ReaderBatchRenderStore.writeReadme(
            ReaderBatchRenderStore.readmeText(
                bookTitle: request.bookTitle,
                scope: scope,
                preset: preset,
                requestedMode: mode,
                chapterCount: indices.count,
                createdAt: batchStartedAt ?? Date()),
            to: directory)

        var manifest = ReaderBatchRenderManifest(
            bookID: request.bookID,
            bookTitle: request.bookTitle,
            scope: scope,
            preset: preset.rawValue,
            requestedMode: mode.rawValue,
            computeUnit: SuperResolutionComputeUnit.cpuOnly.rawValue,
            createdAt: batchStartedAt ?? Date())
        self.manifest = manifest
        try persist(manifest)
        message = "输出目录已创建，开始逐页渲染。"

        for (offset, chapterIndex) in indices.enumerated() {
            try Task.checkCancellation()
            let chapter = request.chapters[chapterIndex]
            currentChapterOrdinal = offset + 1
            currentChapterTitle = chapter.title
            currentPageOrdinal = 0
            currentChapterPageCount = 0
            currentPageProgress = 0
            overallProgress = Double(offset) / Double(indices.count)
            message = "读取章节 \(offset + 1)/\(indices.count)：\(chapter.title)"

            let images: [ComicChapterImage]
            do {
                images = try await request.loadChapterImages(chapterIndex)
            } catch {
                if Task.isCancelled || error.isTaskCancellation {
                    throw CancellationError()
                }
                let record = ReaderBatchRenderChapterRecord(
                    chapterIndex: chapterIndex,
                    title: chapter.title,
                    pageCount: 0,
                    status: .failed,
                    errorDescription: error.localizedDescription)
                chapterRecords.append(record)
                manifest.chapters.append(record)
                self.manifest = manifest
                try persist(manifest)
                overallProgress = Double(offset + 1) / Double(indices.count)
                message = "章节读取失败，已跳过：\(chapter.title)"
                continue
            }
            try Task.checkCancellation()

            currentChapterPageCount = images.count
            let chapterRecord = ReaderBatchRenderChapterRecord(
                chapterIndex: chapterIndex,
                title: chapter.title,
                pageCount: images.count,
                status: .succeeded)
            chapterRecords.append(chapterRecord)
            manifest.chapters.append(chapterRecord)
            self.manifest = manifest
            try persist(manifest)

            if images.isEmpty {
                overallProgress = Double(offset + 1) / Double(indices.count)
                message = "章节没有页面，已跳过：\(chapter.title)"
                continue
            }

            for (pageIndex, image) in images.enumerated() {
                try Task.checkCancellation()
                currentPageOrdinal = pageIndex + 1
                currentPageProgress = 0
                updateOverallProgress(chapterOffset: offset, chapterCount: indices.count)
                let fileName = ReaderBatchRenderStore.pageFileName(
                    chapterIndex: chapterIndex, pageIndex: pageIndex)
                message = "E\(chapterIndex + 1) · P\(pageIndex + 1)/\(images.count)：读取原图…"

                var acceptedRecord: ReaderBatchRenderPageRecord?
                do {
                    guard let url = URL.picaxResolved(from: image.urlString) else {
                        throw ReaderBatchRenderError.invalidPageURL
                    }
                    let source = try await ReaderImageSourceLoader.load(url: url)
                    try Task.checkCancellation()
                    message = "E\(chapterIndex + 1) · P\(pageIndex + 1)/\(images.count)：Core ML 推理（仅 CPU）…"
                    let result = try await SuperResolutionService.shared.process(
                        source: source,
                        preset: preset,
                        mode: mode,
                        computeUnit: .cpuOnly
                    ) { [weak self] value in
                        Task { @MainActor [weak self] in
                            guard let self, self.isRunning else { return }
                            self.currentPageProgress = min(max(value, 0), 1)
                            self.updateOverallProgress(
                                chapterOffset: offset, chapterCount: indices.count)
                        }
                    }
                    if Task.isCancelled {
                        ReaderBatchRenderStore.discardTrialOutput(result.outputURL)
                        throw CancellationError()
                    }
                    let outputByteCount = try ReaderBatchRenderStore.retainOutput(
                        result.outputURL, in: directory, fileName: fileName)

                    var record = ReaderBatchRenderPageRecord(
                        chapterIndex: chapterIndex,
                        chapterTitle: chapter.title,
                        pageIndex: pageIndex,
                        sourceURLString: image.urlString,
                        status: .succeeded,
                        fileName: fileName)
                    record.sourceWidth = source.dimensions.width
                    record.sourceHeight = source.dimensions.height
                    record.outputWidth = result.image.width
                    record.outputHeight = result.image.height
                    record.modelID = result.model.id
                    record.modelDisplayName = result.model.displayName
                    record.modelVersion = result.model.version
                    record.modelPrecision = result.model.precision
                    record.requestedMode = result.requestedMode.rawValue
                    record.actualMode = result.actualMode.rawValue
                    record.computeUnit = result.computeUnit.rawValue
                    record.paddedInputWidth = result.paddedInputWidth
                    record.paddedInputHeight = result.paddedInputHeight
                    record.outputByteCount = outputByteCount
                    record.elapsedSeconds = result.elapsedSeconds
                    record.fallbackReason = result.fallbackReason
                    acceptedRecord = record
                    pageRecords.append(record)
                    manifest.pages.append(record)
                    pageSuccessCount += 1
                    self.manifest = manifest
                    try persist(manifest)
                    currentPageProgress = 1
                    updateOverallProgress(chapterOffset: offset, chapterCount: indices.count)
                    message = "已完成 E\(chapterIndex + 1) · P\(pageIndex + 1)/\(images.count)，继续下一页。"
                } catch {
                    if Task.isCancelled || error.isTaskCancellation {
                        throw CancellationError()
                    }
                    // A manifest write failure happens after the page itself
                    // succeeded; never relabel that PNG as a failed page.
                    if acceptedRecord != nil { throw error }

                    let status = Self.isSkipped(error) ? ReaderBatchRenderPageStatus.skipped : .failed
                    var record = ReaderBatchRenderPageRecord(
                        chapterIndex: chapterIndex,
                        chapterTitle: chapter.title,
                        pageIndex: pageIndex,
                        sourceURLString: image.urlString,
                        status: status)
                    record.errorDescription = error.localizedDescription
                    pageRecords.append(record)
                    manifest.pages.append(record)
                    switch status {
                    case .succeeded: break
                    case .skipped: pageSkippedCount += 1
                    case .failed: pageFailureCount += 1
                    }
                    self.manifest = manifest
                    try persist(manifest)
                    if Self.isFatal(error) { throw error }
                    updateOverallProgress(chapterOffset: offset, chapterCount: indices.count)
                    message = "\(status.title)：E\(chapterIndex + 1) · P\(pageIndex + 1)/\(images.count)；已继续下一页。"
                }
                refreshElapsed()
            }
            overallProgress = Double(offset + 1) / Double(indices.count)
            currentPageProgress = 0
            refreshElapsed()
        }

        manifest.status = .completed
        manifest.finishedAt = Date()
        self.manifest = manifest
        try persist(manifest)
        overallProgress = 1
        phase = .completed
        message = "批量渲染完成：\(pageSuccessCount) 页成功，\(pageSkippedCount) 页跳过，\(pageFailureCount) 页失败。PNG 与 manifest 已保留。"
    }

    private func persist(_ manifest: ReaderBatchRenderManifest) throws {
        guard let outputDirectory else {
            throw ReaderBatchRenderError.outputDirectoryUnavailable
        }
        do {
            try ReaderBatchRenderStore.writeManifest(manifest, to: outputDirectory)
        } catch {
            throw ReaderBatchRenderError.manifestWriteFailed
        }
    }

    private func finalizeManifest(status: ReaderBatchRenderPhase) {
        guard var manifest, let outputDirectory else { return }
        manifest.status = status
        manifest.finishedAt = Date()
        self.manifest = manifest
        try? ReaderBatchRenderStore.writeManifest(manifest, to: outputDirectory)
    }

    private func resetBatchState() {
        discardTemporaryArchive()
        phase = .idle
        scopeChapterCount = 0
        currentChapterOrdinal = 0
        currentChapterTitle = ""
        currentPageOrdinal = 0
        currentChapterPageCount = 0
        currentPageProgress = 0
        overallProgress = 0
        elapsedSeconds = 0
        batchStartedAt = nil
        chapterRecords = []
        pageRecords = []
        pageSuccessCount = 0
        pageSkippedCount = 0
        pageFailureCount = 0
        outputDirectory = nil
        manifest = nil
        fatalMessage = nil
        archiveMessage = nil
    }

    private func updateOverallProgress(chapterOffset: Int, chapterCount: Int) {
        guard chapterCount > 0 else {
            overallProgress = 0
            return
        }
        let pageFraction: Double
        if currentChapterPageCount > 0 {
            pageFraction = (Double(max(currentPageOrdinal - 1, 0)) + currentPageProgress)
                / Double(currentChapterPageCount)
        } else {
            pageFraction = 0
        }
        let value = (Double(chapterOffset) + pageFraction) / Double(chapterCount)
        overallProgress = min(max(value, 0), 1)
    }

    private func refreshElapsed() {
        guard let batchStartedAt else { return }
        elapsedSeconds = max(Date().timeIntervalSince(batchStartedAt), 0)
    }
}
