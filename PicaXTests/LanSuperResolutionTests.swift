import XCTest
@testable import PicaX

@MainActor
final class LanSuperResolutionTests: XCTestCase {
    private let jobID = "11111111-1111-4111-8111-111111111111"
    private let serverID = "22222222-2222-4222-8222-222222222222"

    private func model(native: Int = 4, inputPixels: Int = 4_000_000, maximumSide: Int = 4096,
                       precision: String = "float32", supportedPrecisions: [String]? = nil) throws -> LanSRModelCapability {
        let id = native == 4 ? "illustrationjanai-v3detail-fdat-xl-4x-float32" : "illustrationjanai-v3detail-fdat-m-2x-float32"
        let known = try XCTUnwrap(LanSRContract.models[id])
        return LanSRModelCapability(id: id, name: "Test", sha256: known.sha, nativeScale: known.scale,
            deliveryScales: native == 4 ? [2, 4] : [2], alignment: 16, minimumSide: 64,
            maximumSide: maximumSide, maximumInputPixels: inputPixels, precision: precision, mode: "fullPage", ready: true, error: nil,
            supportedPrecisions: supportedPrecisions)
    }
    private func page() -> LanSRPage {
        LanSRPage(id: "e0000-p0000", chapterIndex: 0, chapterTitle: "Chapter", pageIndex: 0,
                  width: 256, height: 384, bytes: 100, sha256: String(repeating: "a", count: 64))
    }
    private func spec(scale: Int = 2, precision: String? = nil) throws -> LanSRJobSpec {
        let model = try model()
        return LanSRJobSpec(version: 1, jobID: jobID, sourceRecordID: "source", title: "Test",
            modelID: model.id, modelSHA256: model.sha256, nativeScale: 4, deliveryScale: scale, mode: "fullPage", pages: [page()],
            precision: precision)
    }
    private func result(scale: Int = 2, width: Int? = nil, hash: String? = nil, precision: String = "float32") throws -> LanSRResult {
        let model = try model()
        return LanSRResult(modelID: model.id, modelSHA256: model.sha256, nativeScale: 4, deliveryScale: scale,
            width: width ?? 256 * scale, height: 384 * scale, bytes: 100, sha256: hash ?? String(repeating: "b", count: 64),
            engine: "PyTorch", device: "cuda", deviceName: "Test GPU", precision: precision, torchVersion: "test",
            cudaVersion: "test", license: "CC-BY-NC-4.0", sourceURL: "https://github.com/the-database/MangaJaNai/releases/tag/3.0.0",
            mode: "fullPage", downsampling: scale == 2 ? "lanczos" : "none", seconds: 1)
    }

    func testLANAddressAndPublicHostRejection() {
        for host in ["192.168.5.8", "10.0.0.1", "172.31.0.1", "fc00::1"] { XCTAssertTrue(LanSRContract.isLAN(host), host) }
        for host in ["8.8.8.8", "127.0.0.1", "0.0.0.0", "::1", "224.0.0.1", "example.local", "192.168.1.1@evil.test"] {
            XCTAssertFalse(LanSRContract.isLAN(host), host)
        }
    }
    func testConnectionAcceptsIPURLAndOldQRWithoutExpiryOrPin() throws {
        let expected = LanSRConnectionAddress(host: "192.168.5.8", port: 18443)
        for text in ["192.168.5.8", "192.168.5.8:18443", "http://192.168.5.8:18443/", " 192.168.5.8 \n"] {
            XCTAssertEqual(try LanSRConnectionAddress.parse(text), expected)
        }
        let oldQR = #"{"version":1,"host":"192.168.5.8","port":18443,"serverID":"old","certificateSHA256":"unused","pairingSecret":"expired","expiresAt":0}"#
        XCTAssertEqual(try LanSRConnectionAddress.parse(oldQR), expected)
        XCTAssertEqual(try LanSRConnectionAddress.parse(#"{"host":"192.168.5.8","port":18443}"#), expected)
        XCTAssertThrowsError(try LanSRConnectionAddress.parse("http://8.8.8.8:18443"))
        XCTAssertThrowsError(try LanSRConnectionAddress.parse("192.168.5.8:0"))
        XCTAssertThrowsError(try LanSRConnectionAddress.parse("http://user:password@192.168.5.8"))
    }
    func testEndpointUsesHTTPWithoutCertificateFields() throws {
        let server = LanSRServer(host: "192.168.5.8", port: 18443, serverID: serverID)
        XCTAssertEqual(try server.url(path: "/v1/capabilities").absoluteString, "http://192.168.5.8:18443/v1/capabilities")
        XCTAssertThrowsError(try server.url(path: "/v1/../elsewhere"))
        XCTAssertThrowsError(try server.url(path: "/v1/jobs?redirect=1"))
        let ipv6 = LanSRServer(host: "fc00::1", port: 18443, serverID: serverID)
        XCTAssertTrue(try ipv6.url(path: "/v1/capabilities").absoluteString.contains("[fc00::1]"))
        XCTAssertEqual(try LanSRConnectionAddress.parse("http://[fc00::1]:18443"), LanSRConnectionAddress(host: "fc00::1", port: 18443))
        XCTAssertEqual(try LanSRConnectionAddress.parse("fc00::1").port, 18443)
    }
    func testLegacySavedConnectionIgnoresTokenAndCertificate() throws {
        let text = #"{"server":{"host":"192.168.5.8","port":18443,"serverID":"22222222-2222-4222-8222-222222222222","certificateSHA256":"old"},"clientID":"phone-id","token":"no-longer-used"}"#
        let connection = try JSONDecoder().decode(LanSRConnection.self, from: Data(text.utf8))
        XCTAssertEqual(connection.server.serverID, serverID)
        XCTAssertEqual(connection.clientID, "phone-id")
        let encoded = String(decoding: try JSONEncoder().encode(connection), as: UTF8.self)
        XCTAssertFalse(encoded.contains("token"))
        XCTAssertFalse(encoded.contains("certificate"))
    }
    func testLocalHTTPTransportPolicyIncludesPrivateIPRanges() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        let ats = try XCTUnwrap(info["NSAppTransportSecurity"] as? [String: Any])
        XCTAssertEqual(ats["NSAllowsLocalNetworking"] as? Bool, true)
        let exceptions = try XCTUnwrap(ats["NSExceptionDomains"] as? [String: [String: Any]])
        for network in ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "fc00::/7", "fe80::/10"] {
            XCTAssertEqual(exceptions[network]?["NSExceptionAllowsInsecureHTTPLoads"] as? Bool, true, network)
        }
        XCTAssertNotEqual(ats["NSAllowsArbitraryLoads"] as? Bool, true)
    }
    func testConnectionFailureIncludesAddressInsteadOfBareCanceled() {
        let error = LanSRHTTPTransfer.connectionError(URLError(.cancelled), address: "192.168.5.8:18443")
        XCTAssertTrue(error.localizedDescription.contains("192.168.5.8:18443"))
        XCTAssertTrue(error.localizedDescription.contains("连接已中断"))
    }
    func testNativeFourWithDeliveryTwoOrFour() throws {
        try model().validatePage(width: 1000, height: 1500, scale: 2)
        try result().validate(spec: spec(), page: page())
        try result(scale: 4).validate(spec: spec(scale: 4), page: page())
        XCTAssertThrowsError(try result(width: 1024).validate(spec: spec(), page: page()))
        XCTAssertThrowsError(try result(hash: "invalid").validate(spec: spec(), page: page()))
    }
    func testPrecisionCapabilitiesAndLegacyWireShape() throws {
        let legacy = try JSONDecoder().decode(LanSRModelCapability.self, from: JSONEncoder().encode(model()))
        XCTAssertNil(legacy.supportedPrecisions)
        XCTAssertEqual(legacy.selectablePrecisions, ["float32"])
        XCTAssertNoThrow(try legacy.validate())
        let current = try model(precision: "bfloat16", supportedPrecisions: ["float32", "bfloat16"])
        XCTAssertNoThrow(try current.validate())
        XCTAssertEqual(current.selectablePrecisions, ["float32", "bfloat16"])
        XCTAssertThrowsError(try model(precision: "bfloat16").validate())
        for supported in [[], ["float32", "float16"], ["float32", "float32"]] {
            XCTAssertThrowsError(try model(supportedPrecisions: supported).validate())
        }
        let oldWire = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(spec())) as? [String: Any])
        XCTAssertNil(oldWire["precision"])
        let newWire = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(spec(precision: "bfloat16"))) as? [String: Any])
        XCTAssertEqual(newWire["precision"] as? String, "bfloat16")
    }
    func testResultPrecisionMustMatchPinnedJob() throws {
        try result(precision: "bfloat16").validate(spec: spec(precision: "bfloat16"), page: page())
        XCTAssertThrowsError(try result().validate(spec: spec(precision: "bfloat16"), page: page()))
        XCTAssertThrowsError(try result(precision: "bfloat16").validate(spec: spec(), page: page()))
        XCTAssertThrowsError(try result(precision: "float16").validate(spec: spec(precision: "float16"), page: page()))
    }
    func testPageValidationIgnoresCachedPCInputAndVRAMEstimates() throws {
        let cached = try model(inputPixels: 400_000, maximumSide: 64)
        for (width, height) in [(1280, 1864), (2000, 3000), (2000, 4000), (8192, 1)] {
            XCTAssertNoThrow(try cached.validatePage(width: width, height: height, scale: 2))
        }
        // HAT-L needs 64-pixel alignment, but it must not become a phone-side veto.
        let id = "illustrationjanai-v3detail-hat-l-4x-float32"
        let known = try XCTUnwrap(LanSRContract.models[id])
        let hat = LanSRModelCapability(id: id, name: "HAT test", sha256: known.sha, nativeScale: 4,
            deliveryScales: [2, 4], alignment: 64, minimumSide: 64, maximumSide: 4096,
            maximumInputPixels: 400_000, precision: "float32", mode: "fullPage", ready: true, error: nil)
        XCTAssertNoThrow(try hat.validatePage(width: 2000, height: 4000, scale: 2))
    }
    func testDeliveredImageLimitsAndUnsupportedScalesRemainEnforced() throws {
        XCTAssertNoThrow(try model().validatePage(width: 1000, height: 2000, scale: 4))
        for (width, height, scale) in [(1500, 1500, 4), (2001, 4000, 2), (8193, 1, 2), (4097, 1, 4)] {
            XCTAssertThrowsError(try model().validatePage(width: width, height: height, scale: scale)) { error in
                XCTAssertTrue(error.localizedDescription.contains("手机接收范围"))
                XCTAssertTrue(error.localizedDescription.contains("不是电脑输入或显存限制"))
            }
        }
        XCTAssertThrowsError(try model(native: 2).validatePage(width: 100, height: 100, scale: 4))
    }
    func testInvalidPageDimensionsAndScalesDoNotOverflow() throws {
        for (width, height) in [(0, 1), (-1, 1), (1, 0), (1, -1), (Int.max, 1), (1, Int.max)] {
            XCTAssertThrowsError(try model().validatePage(width: width, height: height, scale: 2))
        }
        for scale in [0, -1, 3, Int.max] {
            XCTAssertThrowsError(try model().validatePage(width: 64, height: 64, scale: scale))
        }
    }
    func testStatusCannotClaimUnlistedOrDuplicatePages() throws {
        let valid = LanSRPageStatus(id: page().id, state: "succeeded", result: try result(), error: nil, acknowledged: false)
        try LanSRJobStatus(jobID: jobID, state: "completed", pages: [valid]).validate(spec: spec())
        XCTAssertThrowsError(try LanSRJobStatus(jobID: jobID, state: "completed", pages: [valid, valid]).validate(spec: spec()))
        let missing = LanSRPageStatus(id: page().id, state: "succeeded", result: nil, error: nil, acknowledged: false)
        XCTAssertThrowsError(try LanSRJobStatus(jobID: jobID, state: "completed", pages: [missing]).validate(spec: spec()))
    }
    func testJournalRoundTripKeepsNoncontiguousSourceChapterIndex() throws {
        var job = LanSRLocalJob(id: jobID, serverID: serverID, sourceRecordID: "source", title: "Test",
            chapters: [ComicChapter(id: "chapter-9", title: "Chapter", subtitle: nil)],
            sourceChapterIndexes: [9], pageCounts: [1], model: try model(), deliveryScale: 2)
        job.prepared = [page()]
        job.spec = try spec()
        job.sourceURLs[page().id] = "picax-download/test/page.png"
        try job.validateJournal()
        let decoded = try JSONDecoder().decode(LanSRLocalJob.self, from: JSONEncoder().encode(job))
        try decoded.validateJournal()
        XCTAssertEqual(decoded.sourceChapterIndexes, [9])
        XCTAssertNil(decoded.precision)
        XCTAssertNil(decoded.spec?.precision)
        XCTAssertFalse(decoded.submitted)
        job.prepared.append(page())
        XCTAssertThrowsError(try job.validateJournal())
    }
    func testJournalPersistsSelectedPrecisionIndependentlyOfDefault() throws {
        var job = LanSRLocalJob(id: jobID, serverID: serverID, sourceRecordID: "source", title: "Test",
            chapters: [ComicChapter(id: "chapter", title: "Chapter", subtitle: nil)],
            sourceChapterIndexes: [0], pageCounts: [1],
            model: try model(supportedPrecisions: ["float32", "bfloat16"]), deliveryScale: 2, precision: "bfloat16")
        job.prepared = [page()]
        job.spec = try spec(precision: "bfloat16")
        job.sourceURLs[page().id] = "picax-download/test/page.png"
        job.results[page().id] = try result(precision: "bfloat16")
        try job.validateJournal()
        let decoded = try JSONDecoder().decode(LanSRLocalJob.self, from: JSONEncoder().encode(job))
        try decoded.validateJournal()
        XCTAssertEqual(decoded.model.precision, "float32")
        XCTAssertEqual(decoded.precision, "bfloat16")
        XCTAssertEqual(decoded.spec?.precision, "bfloat16")
        job.precision = "float32"
        XCTAssertThrowsError(try job.validateJournal())
        job.precision = "float16"
        XCTAssertThrowsError(try job.validateJournal())
    }
    func testCachedInputEstimateDoesNotPreventJournalRecovery() throws {
        var job = LanSRLocalJob(id: jobID, serverID: serverID, sourceRecordID: "source", title: "Test",
            chapters: [ComicChapter(id: "chapter", title: "Chapter", subtitle: nil)],
            sourceChapterIndexes: [0], pageCounts: [1], model: try model(inputPixels: 400_000), deliveryScale: 2)
        let largePage = LanSRPage(id: "e0000-p0000", chapterIndex: 0, chapterTitle: "Chapter", pageIndex: 0,
                                 width: 2000, height: 3000, bytes: 100, sha256: String(repeating: "a", count: 64))
        job.prepared = [largePage]
        job.sourceURLs[largePage.id] = "picax-download/test/page.png"
        try job.validateJournal()
        let decoded = try JSONDecoder().decode(LanSRLocalJob.self, from: JSONEncoder().encode(job))
        XCTAssertNoThrow(try decoded.validateJournal())
        XCTAssertEqual(decoded.prepared[0].width, 2000)
        XCTAssertEqual(decoded.prepared[0].height, 3000)
    }
    func testJournalRejectsMissingSourceAndUnmatchedImportedHash() throws {
        var job = LanSRLocalJob(id: jobID, serverID: serverID, sourceRecordID: "source", title: "Test",
            chapters: [ComicChapter(id: "chapter", title: "Chapter", subtitle: nil)],
            sourceChapterIndexes: [0], pageCounts: [1], model: try model(), deliveryScale: 2)
        job.prepared = [page()]
        job.spec = try spec()
        XCTAssertThrowsError(try job.validateJournal())
        job.sourceURLs[page().id] = "picax-download/test/page.png"
        job.imported[page().id] = String(repeating: "b", count: 64)
        XCTAssertThrowsError(try job.validateJournal())
        job.results[page().id] = try result()
        try job.validateJournal()
        job.imported[page().id] = String(repeating: "c", count: 64)
        XCTAssertThrowsError(try job.validateJournal())
    }
    func testExportAttributionDistinguishesNativeAndDeliveredScales() throws {
        let model = try model()
        let text = LanSRContract.readme(modelID: model.id, modelSHA256: model.sha256, nativeScale: 4, deliveryScale: 2)
        XCTAssertTrue(text.contains("Native: 4x; delivered: 2x"))
        XCTAssertTrue(text.contains("Lanczos downsampling after AI inference"))
        XCTAssertTrue(text.contains("CC-BY-NC-4.0"))
        XCTAssertTrue(text.contains(model.sha256))
        XCTAssertFalse(text.contains("Core ML"))
    }
    func testLegacyLocalMetadataAndLANMetadataRoundTrip() throws {
        var info = SuperResolutionDownloadInfo(sourceRecordID: "source", sourceItemID: "item", sourcePlatform: .picacg,
            sourceTitle: "Test", createdAt: .distantPast, completedAt: nil)
        let old = try JSONDecoder().decode(SuperResolutionDownloadInfo.self, from: JSONEncoder().encode(info))
        XCTAssertNil(old.backend)
        info.backend = "lan"; info.serverID = serverID; info.jobID = jobID
        info.modelID = try model().id; info.nativeScale = 4; info.deliveryScale = 2
        XCTAssertEqual(try JSONDecoder().decode(SuperResolutionDownloadInfo.self, from: JSONEncoder().encode(info)), info)
    }
}
