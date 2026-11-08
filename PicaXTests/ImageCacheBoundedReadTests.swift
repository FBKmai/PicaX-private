import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import XCTest
@testable import PicaX

@MainActor
final class ImageCacheBoundedReadTests: XCTestCase {
    func testLocalFileExactLimitOversizeAndUnbounded() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("page.bin")
        let data = Data(repeating: 0x5a, count: 32_769)
        try data.write(to: url)

        let exact = try await ImageCacheService.data(for: url, maximumBytes: data.count)
        XCTAssertEqual(exact, data)
        do {
            _ = try await ImageCacheService.data(for: url, maximumBytes: data.count - 1)
            XCTFail("Expected a bounded read to reject the extra byte")
        } catch ImageCacheReadError.sizeLimitExceeded {}
        let ordinary = try await ImageCacheService.data(for: url)
        XCTAssertEqual(ordinary, data)
        XCTAssertEqual(try Data(contentsOf: url), data)

        do {
            _ = try await ImageCacheService.data(for: url, maximumBytes: -1)
            XCTFail("Expected a negative limit to be rejected")
        } catch ImageCacheReadError.invalidMaximumBytes {}
    }

    func testEmptyFileAndPortableDownloadUseBoundedFileReader() async throws {
        let root = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
            .appendingPathComponent("PicaX/Downloads", isDirectory: true)
        let name = UUID().uuidString
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("page.bin")
        try Data().write(to: file)
        let portable = try XCTUnwrap(URL(string: "picax-download:///\(name)/page.bin"))
        let empty = try await ImageCacheService.data(for: portable, maximumBytes: 0)
        XCTAssertEqual(empty, Data())
        try Data([1]).write(to: file)
        do {
            _ = try await ImageCacheService.data(for: portable, maximumBytes: 0)
            XCTFail("Expected the first byte to exceed a zero limit")
        } catch ImageCacheReadError.sizeLimitExceeded {}
    }

    func testOversizeCachedEHImageIsNotDeletedOrRedownloaded() async throws {
        let url = try XCTUnwrap(URL(string: "picax-ehentai-image://image/\(UUID().uuidString)/1.jpg"))
        defer { ImageCacheService.removeCachedImageData(for: url) }
        let data = try imageData()
        ImageCacheService.storeDecodedImageData(data, for: url)

        let exact = try await ImageCacheService.data(for: url, maximumBytes: data.count)
        XCTAssertEqual(exact, data)
        do {
            _ = try await ImageCacheService.data(for: url, maximumBytes: data.count - 1)
            XCTFail("Expected the cache read to reject an oversized entry")
        } catch ImageCacheReadError.sizeLimitExceeded {}
        // The fake lazy-image context cannot resolve over the network. A
        // successful ordinary read therefore also proves the cache survived.
        let ordinary = try await ImageCacheService.data(for: url)
        XCTAssertEqual(ordinary, data)
        do {
            _ = try await ImageCacheService.data(for: url, storesInCache: false, maximumBytes: data.count)
            XCTFail("A cache-bypassing bounded EH request must not return the cache")
        } catch ComicContentError.invalidResponse {}
        let stillCached = try await ImageCacheService.data(for: url)
        XCTAssertEqual(stillCached, data)
    }

    func testCorruptCachedEHImageIsRemovedBeforeResolutionFailure() async throws {
        let url = try XCTUnwrap(URL(string: "picax-ehentai-image://image/\(UUID().uuidString)/1.jpg"))
        let file = cacheFile(for: url)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0, 1, 2]).write(to: file)
        defer { ImageCacheService.removeCachedImageData(for: url) }
        do {
            _ = try await ImageCacheService.data(for: url, maximumBytes: 16)
            XCTFail("The synthetic EH context is unregistered, so a bounded miss must fail resolution")
        } catch ComicContentError.invalidResponse {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testProxySizeLimitSurvivesNSErrorTransport() {
        let error = AppProxyTransportError(AppProxyError.responseTooLarge) as NSError
        XCTAssertEqual(error.domain, AppProxyTransportError.errorDomain)
        XCTAssertEqual(error.code, AppProxyTransportError.responseTooLargeCode)
    }

    func testAlreadyCancelledFileRequestDoesNotRead() async throws {
        let task = Task { @MainActor in
            try await ImageCacheService.data(
                for: URL(fileURLWithPath: "/missing-cancelled-file"), maximumBytes: 8
            )
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation before attempting to open the file")
        } catch is CancellationError {}
    }

    func testCoalescingSeparatesLimitsAndCachePolicies() throws {
        let url = try XCTUnwrap(URL(string: "https://bounded-image.invalid/page"))
        let key: (Bool, Int?) -> String = {
            ImageCacheService.requestCoalescingKey(for: url, storesInCache: $0, maximumBytes: $1)
        }
        XCTAssertEqual(key(true, 8), key(true, 8))
        XCTAssertNotEqual(key(true, nil), key(true, 8))
        XCTAssertNotEqual(key(true, 8), key(true, 9))
        XCTAssertNotEqual(key(true, 8), key(false, 8))
        let other = try XCTUnwrap(URL(string: "https://bounded-image.invalid/page#cache=true"))
        XCTAssertNotEqual(key(true, nil), ImageCacheService.requestCoalescingKey(for: other, storesInCache: true, maximumBytes: nil))
    }

    func testBoundedWaiterDoesNotJoinAnUnboundedPendingRequest() async throws {
        let coalescer = AsyncRequestCoalescer<Data>()
        let url = try XCTUnwrap(URL(string: "https://bounded-image.invalid/page"))
        let started = expectation(description: "unbounded request is pending")
        let boundedStarted = expectation(description: "bounded request starts separately")
        let gate = ImageCacheTestGate()
        let unbounded = Task {
            try await coalescer.value(for: ImageCacheService.requestCoalescingKey(for: url, storesInCache: true, maximumBytes: nil)) {
                started.fulfill()
                await gate.wait()
                return Data(repeating: 1, count: 32)
            }
        }
        await fulfillment(of: [started], timeout: 3)
        let bounded = Task {
            try await coalescer.value(
                for: ImageCacheService.requestCoalescingKey(for: url, storesInCache: true, maximumBytes: 8)
            ) {
                boundedStarted.fulfill()
                return Data(repeating: 2, count: 8)
            }
        }
        await fulfillment(of: [boundedStarted], timeout: 3)
        await gate.open()
        let boundedResult = try await bounded.value
        XCTAssertEqual(boundedResult, Data(repeating: 2, count: 8))
        let unboundedResult = try await unbounded.value
        XCTAssertEqual(unboundedResult.count, 32)
    }

    func testStreamAcceptsExactLengthWithoutContentLength() async throws {
        let fixture = BoundedImageFixture(chunks: [Data([1, 2, 3]), Data([4, 5])])
        let session = makeSession(fixture)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: fixture.url)
        request.setValue("Bearer test-token", forHTTPHeaderField: "Authorization")
        request.setValue("https://bounded-image.invalid/reader", forHTTPHeaderField: "Referer")
        let (data, _) = try await BoundedImageDataReader.network(request: request, session: session, maximumBytes: 5)
        XCTAssertEqual(data, Data([1, 2, 3, 4, 5]))
        XCTAssertEqual(fixture.requestHeader("Authorization"), "Bearer test-token")
        XCTAssertEqual(fixture.requestHeader("Referer"), "https://bounded-image.invalid/reader")
    }

    func testStreamStopsOnOverflowWithoutTrustingLengthHeader() async throws {
        for headers in [[:], ["Content-Length": "1"]] {
            let stopped = expectation(description: "oversized transfer was cancelled")
            let fixture = BoundedImageFixture(
                // AsyncBytes may prefetch a Foundation-sized buffer before
                // yielding its first byte. Use a body larger than that bounded
                // prefetch to verify cancellation stops the remaining transfer.
                chunks: Array(repeating: Data(repeating: 1, count: 16 * 1024), count: 20),
                headers: headers,
                onStop: { stopped.fulfill() }
            )
            let session = makeSession(fixture)
            defer { session.invalidateAndCancel() }
            do {
                _ = try await BoundedImageDataReader.network(
                    request: URLRequest(url: fixture.url), session: session, maximumBytes: 5
                )
                XCTFail("Expected the sixth byte to be rejected")
            } catch ImageCacheReadError.sizeLimitExceeded {}
            await fulfillment(of: [stopped], timeout: 3)
            XCTAssertLessThan(fixture.sentChunkCount, fixture.chunks.count)
        }
    }

    func testCancellingStreamCancelsUnderlyingTask() async throws {
        let started = expectation(description: "request started")
        let stopped = expectation(description: "request cancelled")
        let fixture = BoundedImageFixture(chunks: [Data([1])], finishes: false,
                                          onFirstChunk: { started.fulfill() }, onStop: { stopped.fulfill() })
        let session = makeSession(fixture)
        defer { session.invalidateAndCancel() }
        let task = Task {
            try await BoundedImageDataReader.network(request: URLRequest(url: fixture.url), session: session, maximumBytes: 16)
        }
        await fulfillment(of: [started], timeout: 3)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        await fulfillment(of: [stopped], timeout: 3)
    }

    private func makeSession(_ fixture: BoundedImageFixture) -> URLSession {
        BoundedImageURLProtocol.register(fixture)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoundedImageURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func imageData() throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func cacheFile(for url: URL) -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return base.appendingPathComponent("ImageCache", isDirectory: true).appendingPathComponent(digest)
    }
}

private actor ImageCacheTestGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private nonisolated final class BoundedImageFixture: @unchecked Sendable {
    let url = URL(string: "https://bounded-image.invalid/\(UUID().uuidString)")!
    let chunks: [Data]
    let headers: [String: String]
    let finishes: Bool
    let onFirstChunk: (@Sendable () -> Void)?
    let onStop: (@Sendable () -> Void)?
    private let lock = NSLock()
    private var delivered = 0
    private var recordedRequest: URLRequest?

    init(chunks: [Data], headers: [String: String] = [:], finishes: Bool = true,
         onFirstChunk: (@Sendable () -> Void)? = nil, onStop: (@Sendable () -> Void)? = nil) {
        self.chunks = chunks
        self.headers = headers
        self.finishes = finishes
        self.onFirstChunk = onFirstChunk
        self.onStop = onStop
    }

    var sentChunkCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return delivered
    }

    func recordChunk() {
        lock.lock()
        delivered += 1
        lock.unlock()
    }

    func recordRequest(_ request: URLRequest) {
        lock.lock()
        recordedRequest = request
        lock.unlock()
    }

    func requestHeader(_ name: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequest?.value(forHTTPHeaderField: name)
    }
}

private nonisolated final class BoundedImageURLProtocol: URLProtocol, @unchecked Sendable {
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var fixtures: [URL: BoundedImageFixture] = [:]
    private let stateLock = NSLock()
    private var stopped = false
    private var fixture: BoundedImageFixture?

    static func register(_ fixture: BoundedImageFixture) {
        registryLock.lock()
        fixtures[fixture.url] = fixture
        registryLock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "bounded-image.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.registryLock.lock()
        let fixture = Self.fixtures.removeValue(forKey: url)
        Self.registryLock.unlock()
        guard let fixture else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        stateLock.lock()
        self.fixture = fixture
        stateLock.unlock()
        fixture.recordRequest(request)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: fixture.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        deliver(fixture, index: 0)
    }

    override func stopLoading() {
        stateLock.lock()
        let shouldNotify = !stopped
        stopped = true
        let fixture = self.fixture
        stateLock.unlock()
        if shouldNotify { fixture?.onStop?() }
    }

    private func deliver(_ fixture: BoundedImageFixture, index: Int) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let stopped = self.stopped
            self.stateLock.unlock()
            guard !stopped else { return }
            if index < fixture.chunks.count {
                fixture.recordChunk()
                self.client?.urlProtocol(self, didLoad: fixture.chunks[index])
                if index == 0 { fixture.onFirstChunk?() }
                self.deliver(fixture, index: index + 1)
            } else if fixture.finishes {
                self.client?.urlProtocolDidFinishLoading(self)
            }
        }
    }
}
