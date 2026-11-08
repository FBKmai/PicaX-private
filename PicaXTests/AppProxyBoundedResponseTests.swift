import Foundation
import XCTest
@testable import PicaX

final class AppProxyBoundedResponseTests: XCTestCase {
    func testExactAndOversizeContentLength() throws {
        let exact = try decode("Content-Length: 5\r\n", body: "12345", limit: 5)
        XCTAssertEqual(exact.body, Data("12345".utf8))
        XCTAssertThrowsError(try decode("Content-Length: 6\r\n", body: "123456", limit: 5)) {
            guard case AppProxyError.responseTooLarge = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
        let headerOnly = BoundedResponseChannel(parts: [Data("HTTP/1.1 200 OK\r\nContent-Length: 999999\r\n\r\n".utf8)])
        XCTAssertThrowsError(try AppProxyHTTPCodec.readResponse(from: headerOnly, requestMethod: "GET", maximumBytes: 5))
        XCTAssertEqual(headerOnly.readCount, 1, "Reject the declared length before reading its body")
    }

    func testUnknownLengthRejectsBodyAlreadyBufferedWithHeaders() throws {
        XCTAssertEqual(try decode("", body: "12345", limit: 5).body.count, 5)
        XCTAssertThrowsError(try decode("", body: "123456", limit: 5)) {
            guard case AppProxyError.responseTooLarge = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
    }

    func testChunkedBodyHonorsCumulativeLimitAndRejectsHugeChunkBeforeRead() throws {
        let headers = "Transfer-Encoding: chunked\r\n"
        let exact = try decode(headers, body: "3\r\n123\r\n2\r\n45\r\n0\r\n\r\n", limit: 5)
        XCTAssertEqual(exact.body, Data("12345".utf8))
        XCTAssertThrowsError(try decode(headers, body: "3\r\n123\r\n3\r\n456\r\n0\r\n\r\n", limit: 5))
        let channel = BoundedResponseChannel(parts: [Data("HTTP/1.1 200 OK\r\n\(headers)\r\n7fffffff\r\n".utf8)])
        XCTAssertThrowsError(try AppProxyHTTPCodec.readResponse(from: channel, requestMethod: "GET", maximumBytes: 5)) {
            guard case AppProxyError.responseTooLarge = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
        XCTAssertEqual(channel.readCount, 1)
    }

    func testZeroLimitAndUnboundedCompatibility() throws {
        XCTAssertTrue(try decode("Content-Length: 0\r\n", body: "", limit: 0).body.isEmpty)
        XCTAssertThrowsError(try decode("", body: "x", limit: 0))
        XCTAssertEqual(try decode("", body: "ordinary reader", limit: nil).body, Data("ordinary reader".utf8))
    }

    func testInternalLimitHeaderNeverReachesOriginAndSurvivesCanonicalization() throws {
        var request = URLRequest(url: URL(string: "https://proxy-bound.invalid/image")!)
        request.setValue("64", forHTTPHeaderField: AppProxyHTTPCodec.maximumBodyHeaderName)
        request.setValue("route-token", forHTTPHeaderField: AppProxyRouteRegistry.headerName)
        request.setValue("Bearer example", forHTTPHeaderField: "Authorization")
        let canonical = AppProxyURLProtocol.canonicalRequest(for: request)
        XCTAssertEqual(canonical.value(forHTTPHeaderField: AppProxyHTTPCodec.maximumBodyHeaderName), "64")
        let encoded = try AppProxyHTTPCodec.encodedRequest(canonical, preservedBody: nil,
                                                          internalHeaderName: AppProxyRouteRegistry.headerName)
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(text.lowercased().contains("x-picax-"))
        XCTAssertTrue(text.contains("Authorization: Bearer example"))
    }

    private func decode(_ headers: String, body: String, limit: Int?) throws -> AppProxyHTTPResponse {
        try AppProxyHTTPCodec.readResponse(
            from: BoundedResponseChannel(parts: [Data("HTTP/1.1 200 OK\r\n\(headers)\r\n\(body)".utf8)]),
            requestMethod: "GET", maximumBytes: limit
        )
    }
}

private nonisolated final class BoundedResponseChannel: AppProxyHTTPChannel {
    private var parts: [Data]
    private(set) var readCount = 0
    init(parts: [Data]) { self.parts = parts }
    func write(_ data: Data) throws {}
    func read() throws -> Data {
        readCount += 1
        return parts.isEmpty ? Data() : parts.removeFirst()
    }
    func close() {}
}
