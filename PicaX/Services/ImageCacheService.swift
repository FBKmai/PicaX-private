import CryptoKit
import Foundation
import ImageIO

nonisolated enum ImageCacheReadError: LocalizedError, Equatable {
    case invalidMaximumBytes
    case sizeLimitExceeded

    var errorDescription: String? {
        switch self {
        case .invalidMaximumBytes:
            "图片读取上限不能为负数。"
        case .sizeLimitExceeded:
            "图片编码数据超过读取上限。"
        }
    }
}

struct ImageCacheUsage: Equatable, Sendable {
    let memoryBytes: Int
    let diskBytes: Int

    var totalBytes: Int {
        memoryBytes + diskBytes
    }
}

enum ImageCacheService {
    nonisolated static let defaultMaxDiskSizeMB = 400
    nonisolated private static let lock = NSLock()
    nonisolated(unsafe) private static var diskCapacityBytes = defaultMaxDiskSizeMB * 1024 * 1024
    nonisolated(unsafe) private static var isStoreTrimScheduled = false
    private static var activeTrimTask: Task<Void, Never>?
    nonisolated private static let requestCoalescer = AsyncRequestCoalescer<Data>()
    @MainActor
    @discardableResult
    static func configure(defaults: UserDefaults = .standard) -> Task<Void, Never> {
        if defaults.object(forKey: ImageCacheSettingsKey.maxDiskSizeMB) == nil {
            defaults.set(defaultMaxDiskSizeMB, forKey: ImageCacheSettingsKey.maxDiskSizeMB)
        }

        let storedSize = defaults.integer(forKey: ImageCacheSettingsKey.maxDiskSizeMB)
        let diskCapacity = max(storedSize, 50) * 1024 * 1024
        URLCache.shared.removeAllCachedResponses()
        URLCache.shared = URLCache(memoryCapacity: 0, diskCapacity: 0)
        withDiskCacheLock {
            diskCapacityBytes = diskCapacity
            prepareDiskCacheDirectoryLocked()
        }
        activeTrimTask?.cancel()
        let trimTask = Task.detached(priority: .utility) {
            guard !Task.isCancelled else { return }
            withDiskCacheLock {
                trimDiskCacheIfNeededLocked()
            }
        }
        activeTrimTask = trimTask
        return trimTask
    }

    @MainActor
    static func clear() async {
        activeTrimTask?.cancel()
        URLCache.shared.removeAllCachedResponses()
        await Task.detached(priority: .utility) {
            withDiskCacheLock {
                let directoryURL = cacheDirectoryURL
                try? FileManager.default.removeItem(at: directoryURL)
                prepareDiskCacheDirectoryLocked()
            }
        }.value
    }

    nonisolated static func usage() async -> ImageCacheUsage {
        await Task.detached(priority: .utility) {
            withDiskCacheLock {
                ImageCacheUsage(memoryBytes: 0, diskBytes: Int(min(diskUsageBytesLocked(), Int64(Int.max))))
            }
        }.value
    }

    nonisolated static func formattedSize(_ bytes: Int) -> String {
        formattedSize(Int64(bytes))
    }

    nonisolated static func formattedSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    nonisolated static func data(
        for url: URL,
        storesInCache: Bool = true,
        maximumBytes: Int? = nil
    ) async throws -> Data {
        if let maximumBytes {
            guard maximumBytes >= 0 else { throw ImageCacheReadError.invalidMaximumBytes }
            try Task.checkCancellation()
        }
        if let fileURL = url.picaxLocalFileURL {
            if let maximumBytes {
                return try await boundedLocalFileData(for: fileURL, maximumBytes: maximumBytes)
            }
            return try await localFileData(for: fileURL)
        }
        // A bounded waiter must never join an unbounded request, or one with
        // a different limit: the shared operation itself has to honor its limit.
        let key = requestCoalescingKey(for: url, storesInCache: storesInCache, maximumBytes: maximumBytes)
        return try await requestCoalescer.value(for: key) {
            try await loadRemoteData(for: url, storesInCache: storesInCache, maximumBytes: maximumBytes)
        }
    }

    nonisolated static func requestCoalescingKey(for url: URL, storesInCache: Bool, maximumBytes: Int?) -> String {
        let address = url.absoluteString
        let limitKey = maximumBytes.map { String($0) } ?? "unbounded"
        return "\(address.utf8.count):\(address)#cache=\(storesInCache)#maximumBytes=\(limitKey)"
    }

    private nonisolated static func loadRemoteData(
        for url: URL,
        storesInCache: Bool,
        maximumBytes: Int?
    ) async throws -> Data {
        if storesInCache {
            if let maximumBytes {
                if let cachedData = try await boundedCachedImageData(for: url, maximumBytes: maximumBytes) {
                    return cachedData
                }
            } else if let cachedData = await cachedImageData(for: url) {
                return cachedData
            }
        }

        if EhentaiLazyImageResolver.isLazyImageURL(url) {
            let data = try await EhentaiLazyImageResolver.shared.data(for: url, maximumBytes: maximumBytes)
            guard isDecodableImageData(data) else {
                throw URLError(.cannotDecodeContentData)
            }
            if storesInCache {
                await storeImageData(data, for: url)
            }
            return data
        }

        guard url.picaxSupportsURLCache else {
            throw URLError(.unsupportedURL)
        }

        let result: (Data, URLResponse)
        if let maximumBytes {
            result = try await boundedUncachedData(for: url, maximumBytes: maximumBytes)
        } else {
            result = try await uncachedData(for: url)
        }
        let (data, response) = result
        if maximumBytes != nil { try Task.checkCancellation() }
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw URLError(.badServerResponse)
        }
        guard isDecodableImageData(data) else {
            throw URLError(.cannotDecodeContentData)
        }
        if maximumBytes != nil { try Task.checkCancellation() }
        if storesInCache {
            await storeImageData(data, for: url)
        }
        if maximumBytes != nil { try Task.checkCancellation() }
        return data
    }

    nonisolated static func storeDecodedImageData(_ data: Data, for url: URL) {
        guard url.picaxLocalFileURL == nil,
              url.picaxSupportsURLCache,
              isDecodableImageData(data) else {
            return
        }
        prepareDiskCacheDirectoryLocked()
        let fileURL = cacheFileURL(for: url)
        try? data.write(to: fileURL, options: [.atomic])
        touchCacheFileLocked(fileURL)
        let shouldScheduleTrim = withDiskCacheLock {
            guard !isStoreTrimScheduled else { return false }
            isStoreTrimScheduled = true
            return true
        }
        guard shouldScheduleTrim else { return }
        scheduleStoreTrim()
    }

    nonisolated static func removeCachedImageData(for url: URL) {
        guard url.picaxSupportsURLCache else { return }
        withDiskCacheLock {
            try? FileManager.default.removeItem(at: cacheFileURL(for: url))
        }
    }

    nonisolated static func prefetchImageData(for url: URL) async throws {
        _ = try await data(for: url)
    }

    private nonisolated static func uncachedData(for url: URL) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        do {
            return try await AppProxyNetwork.shared.data(for: request, purpose: .image)
        } catch {
            guard error.isTaskCancellation else {
                throw error
            }
            throw CancellationError()
        }
    }

    private nonisolated static func boundedUncachedData(
        for url: URL,
        maximumBytes: Int
    ) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        return try await AppProxyNetwork.shared.data(for: request, purpose: .image, maximumBytes: maximumBytes)
    }

    private nonisolated static func localFileData(for fileURL: URL) async throws -> Data {
        try await Task.detached(priority: .utility) {
            try Data(contentsOf: fileURL)
        }.value
    }

    private nonisolated static func boundedLocalFileData(for fileURL: URL, maximumBytes: Int) async throws -> Data {
        let task = Task.detached(priority: .utility) {
            try BoundedImageDataReader.file(at: fileURL, maximumBytes: maximumBytes)
        }
        return try await withTaskCancellationHandler {
            let data = try await task.value
            try Task.checkCancellation()
            return data
        } onCancel: {
            task.cancel()
        }
    }

    private nonisolated static func cachedImageData(for url: URL) async -> Data? {
        await Task.detached(priority: .utility) {
            diskCachedImageData(for: url)
        }.value
    }

    private nonisolated static func boundedCachedImageData(for url: URL, maximumBytes: Int) async throws -> Data? {
        let task = Task.detached(priority: .utility) {
            try diskBoundedCachedImageData(for: url, maximumBytes: maximumBytes)
        }
        return try await withTaskCancellationHandler {
            let data = try await task.value
            try Task.checkCancellation()
            return data
        } onCancel: {
            task.cancel()
        }
    }

    private nonisolated static func storeImageData(_ data: Data, for url: URL) async {
        await Task.detached(priority: .utility) {
            storeDecodedImageData(data, for: url)
        }.value
    }

    private nonisolated static func diskCachedImageData(for url: URL) -> Data? {
        guard url.picaxLocalFileURL == nil, url.picaxSupportsURLCache else {
            return nil
        }

        let fileURL = cacheFileURL(for: url)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        guard let data = try? Data(contentsOf: fileURL), isDecodableImageData(data) else {
            withDiskCacheLock {
                try? FileManager.default.removeItem(at: fileURL)
            }
            return nil
        }

        touchCacheFileLocked(fileURL)
        return data
    }

    private nonisolated static func diskBoundedCachedImageData(for url: URL, maximumBytes: Int) throws -> Data? {
        guard url.picaxLocalFileURL == nil, url.picaxSupportsURLCache else { return nil }
        let fileURL = cacheFileURL(for: url)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }

        let data: Data
        do {
            data = try BoundedImageDataReader.file(at: fileURL, maximumBytes: maximumBytes)
        } catch ImageCacheReadError.sizeLimitExceeded {
            // A valid large cache entry is not corrupt, and retrying the network
            // would not make this particular bounded read safe.
            throw ImageCacheReadError.sizeLimitExceeded
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            withDiskCacheLock {
                try? FileManager.default.removeItem(at: fileURL)
            }
            return nil
        }
        try Task.checkCancellation()
        guard isDecodableImageData(data) else {
            try Task.checkCancellation()
            withDiskCacheLock {
                try? FileManager.default.removeItem(at: fileURL)
            }
            return nil
        }
        touchCacheFileLocked(fileURL)
        return data
    }

    private nonisolated static func isDecodableImageData(_ data: Data) -> Bool {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return false
        }
        return CGImageSourceGetCount(source) > 0
    }

    private nonisolated static func withDiskCacheLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private nonisolated static func scheduleStoreTrim() {
        Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 250_000_000)
            withDiskCacheLock {
                defer { isStoreTrimScheduled = false }
                trimDiskCacheIfNeededLocked()
            }
        }
    }

    private nonisolated static var cacheDirectoryURL: URL {
        let baseURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return baseURL.appendingPathComponent("ImageCache", isDirectory: true)
    }

    private nonisolated static func cacheFileURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return cacheDirectoryURL.appendingPathComponent(digest, isDirectory: false)
    }

    private nonisolated static func prepareDiskCacheDirectoryLocked() {
        try? FileManager.default.createDirectory(at: cacheDirectoryURL, withIntermediateDirectories: true)
    }

    private nonisolated static func touchCacheFileLocked(_ fileURL: URL) {
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: fileURL.path
        )
    }

    private nonisolated static func trimDiskCacheIfNeededLocked() {
        guard !Task.isCancelled else { return }
        let files = cacheFilesLocked()
        var totalBytes = files.reduce(Int64(0)) { $0 + $1.byteCount }
        guard totalBytes > Int64(diskCapacityBytes) else { return }

        for file in files.sorted(by: { $0.modificationDate < $1.modificationDate }) {
            guard !Task.isCancelled else { return }
            try? FileManager.default.removeItem(at: file.url)
            totalBytes -= file.byteCount
            if totalBytes <= Int64(diskCapacityBytes) {
                break
            }
        }
    }

    private nonisolated static func diskUsageBytesLocked() -> Int64 {
        cacheFilesLocked().reduce(Int64(0)) { $0 + $1.byteCount }
    }

    private nonisolated static func cacheFilesLocked() -> [DiskCacheFile] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: cacheDirectoryURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )) ?? []

        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else {
                return nil
            }
            return DiskCacheFile(
                url: url,
                byteCount: Int64(values.fileSize ?? 0),
                modificationDate: values.contentModificationDate ?? .distantPast
            )
        }
    }

    private nonisolated struct DiskCacheFile {
        let url: URL
        let byteCount: Int64
        let modificationDate: Date
    }
}

/// Only the returned Data is accumulated; neither a file's size nor an HTTP
/// Content-Length is trusted. The next byte beyond the limit is a sentinel and
/// is never appended to the result.
nonisolated enum BoundedImageDataReader {
    private static let chunkSize = 16 * 1024

    static func file(at url: URL, maximumBytes: Int) throws -> Data {
        guard maximumBytes >= 0 else { throw ImageCacheReadError.invalidMaximumBytes }
        try Task.checkCancellation()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var result = Data()
        var remaining = maximumBytes
        while true {
            try Task.checkCancellation()
            // When close to the limit, read at most one byte beyond it so an
            // exactly-sized file still succeeds and a growing file cannot race
            // a preliminary metadata check.
            let count = remaining >= chunkSize ? chunkSize : remaining + 1
            let chunk = try handle.read(upToCount: count) ?? Data()
            guard !chunk.isEmpty else { return result }
            guard chunk.count <= remaining else { throw ImageCacheReadError.sizeLimitExceeded }
            result.append(chunk)
            remaining -= chunk.count
        }
    }

    static func network(
        request: URLRequest,
        session: URLSession,
        maximumBytes: Int
    ) async throws -> (Data, URLResponse) {
        guard maximumBytes >= 0 else { throw ImageCacheReadError.invalidMaximumBytes }
        do {
            try Task.checkCancellation()
            let (bytes, response) = try await session.bytes(for: request)
            let task = bytes.task
            defer { task.cancel() }
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                // A failed HTTP response is handled by the caller; there is no
                // reason to collect its (potentially unbounded) error body.
                if let response = response as? HTTPURLResponse,
                   !(200...299).contains(response.statusCode) {
                    return (Data(), response)
                }
                var result = Data()
                var buffer = [UInt8]()
                buffer.reserveCapacity(min(chunkSize, maximumBytes))
                var remaining = maximumBytes
                for try await byte in bytes {
                    guard remaining > 0 else { throw ImageCacheReadError.sizeLimitExceeded }
                    buffer.append(byte)
                    remaining -= 1
                    if buffer.count == chunkSize {
                        try Task.checkCancellation()
                        result.append(contentsOf: buffer)
                        buffer.removeAll(keepingCapacity: true)
                    }
                }
                try Task.checkCancellation()
                result.append(contentsOf: buffer)
                return (result, response)
            } onCancel: {
                task.cancel()
            }
        } catch where error.isTaskCancellation || Task.isCancelled {
            throw CancellationError()
        }
    }
}
