import Foundation
import XCTest
@testable import PicaX

@MainActor
final class EhentaiBoundedReadTests: XCTestCase {
    func testBoundedImageRetainsAuthAndDoesNotRetryOverflowOrChangeOrdinaryPolicy() async throws {
        let fixture = EhBoundedFixture(imageBytes: 2048)
        let session = makeSession(fixture)
        defer { session.invalidateAndCancel() }
        let resolver = EhentaiLazyImageResolver(session: session)
        let url = try await lazyURL(resolver, fixture)
        do {
            _ = try await resolver.data(for: url, maximumBytes: 1024)
            XCTFail("The image stream must be capped")
        } catch ImageCacheReadError.sizeLimitExceeded {}
        XCTAssertEqual(fixture.requestCount(path: "/image.jpg"), 1, "Size failures must not follow the NL retry path")
        let imageRequest = try XCTUnwrap(fixture.requests.last { $0.url?.path == "/image.jpg" })
        XCTAssertEqual(imageRequest.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
        XCTAssertEqual(imageRequest.value(forHTTPHeaderField: "Referer"), fixture.base + "/s/image-key/1-1")
        let ordinary = try await resolver.data(for: url)
        XCTAssertEqual(ordinary.count, 2048, "The registered context must retain its ordinary unbounded policy")
    }

    func testBoundAlsoAppliesToLazyResolutionMetadataAndIsNotRetried() async throws {
        let fixture = EhBoundedFixture(imageBytes: 5, oversizedMetadata: true)
        let session = makeSession(fixture)
        defer { session.invalidateAndCancel() }
        let resolver = EhentaiLazyImageResolver(session: session)
        let url = try await lazyURL(resolver, fixture)
        do {
            _ = try await resolver.data(for: url, maximumBytes: 1024)
            XCTFail("Gallery HTML must not be fully buffered before the image limit is applied")
        } catch ImageCacheReadError.sizeLimitExceeded {}
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testBoundedImageAcceptsValidBodyWithNoLengthHeader() async throws {
        let fixture = EhBoundedFixture(imageBytes: 1024)
        let session = makeSession(fixture)
        defer { session.invalidateAndCancel() }
        let resolver = EhentaiLazyImageResolver(session: session)
        let url = try await lazyURL(resolver, fixture)
        let data = try await resolver.data(for: url, maximumBytes: 1024)
        XCTAssertEqual(data, Data(repeating: 0x5a, count: 1024))
    }

    private func lazyURL(_ resolver: EhentaiLazyImageResolver, _ fixture: EhBoundedFixture) async throws -> URL {
        let links = try await resolver.registerGallery(
            galleryURLString: fixture.base + "/g/1/token/", pageCount: 1,
            baseURLString: fixture.base, apiURLString: fixture.base + "/api.php",
            headers: ["Authorization": "Bearer fixture"], prefersOriginalImage: false
        )
        return try XCTUnwrap(links.first.flatMap(URL.init(string:)))
    }

    private func makeSession(_ fixture: EhBoundedFixture) -> URLSession {
        EhBoundedURLProtocol.register(fixture)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EhBoundedURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private nonisolated final class EhBoundedFixture: @unchecked Sendable {
    let host = UUID().uuidString.lowercased() + ".eh-bounded.invalid"
    var base: String { "https://" + host }
    let imageBytes: Int
    let oversizedMetadata: Bool
    private let lock = NSLock()
    private var recorded: [URLRequest] = []

    init(imageBytes: Int, oversizedMetadata: Bool = false) {
        self.imageBytes = imageBytes
        self.oversizedMetadata = oversizedMetadata
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func requestCount(path: String) -> Int { requests.filter { $0.url?.path == path }.count }

    func data(for request: URLRequest) throws -> Data {
        lock.lock()
        recorded.append(request)
        lock.unlock()
        switch request.url?.path {
        case "/g/1/token", "/g/1/token/":
            return Data((oversizedMetadata ? String(repeating: "x", count: 2048) :
                "<a href=\"/s/image-key/1-1\">page</a>").utf8)
        case "/s/image-key/1-1":
            return Data("<script>showkey=\"fixture-key\";</script>".utf8)
        case "/api.php":
            return try JSONSerialization.data(withJSONObject: [
                "i3": "<img src=\"\(base)/image.jpg\">", "i6": "nl('fixture-nl')"
            ])
        case "/image.jpg": return Data(repeating: 0x5a, count: imageBytes)
        default: throw URLError(.fileDoesNotExist)
        }
    }
}

private nonisolated final class EhBoundedURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fixtures: [String: EhBoundedFixture] = [:]

    static func register(_ fixture: EhBoundedFixture) {
        lock.lock()
        fixtures[fixture.host] = fixture
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".eh-bounded.invalid") == true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let host = request.url?.host
        let fixture = host.flatMap { Self.fixtures[$0] }
        Self.lock.unlock()
        do {
            guard let fixture, let url = request.url else { throw URLError(.badURL) }
            let data = try fixture.data(for: request)
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}
