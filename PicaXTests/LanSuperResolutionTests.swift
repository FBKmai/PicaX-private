import XCTest
@testable import PicaX

@MainActor
final class LanSuperResolutionTests: XCTestCase {
    private let jobID = "11111111-1111-4111-8111-111111111111"
    private let serverID = "22222222-2222-4222-8222-222222222222"

    private func model(native: Int = 4) throws -> LanSRModelCapability {
        let id = native == 4 ? "illustrationjanai-v3detail-fdat-xl-4x-float32" : "illustrationjanai-v3detail-fdat-m-2x-float32"
        let known = try XCTUnwrap(LanSRContract.models[id])
        return LanSRModelCapability(id: id, name: "Test", sha256: known.sha, nativeScale: known.scale,
            deliveryScales: native == 4 ? [2, 4] : [2], alignment: 16, minimumSide: 64,
            maximumSide: 4096, maximumInputPixels: 4_000_000, precision: "float32", mode: "fullPage", ready: true, error: nil)
    }
    private func page() -> LanSRPage {
        LanSRPage(id: "e0000-p0000", chapterIndex: 0, chapterTitle: "Chapter", pageIndex: 0,
                  width: 256, height: 384, bytes: 100, sha256: String(repeating: "a", count: 64))
    }
    private func spec(scale: Int = 2) throws -> LanSRJobSpec {
        let model = try model()
        return LanSRJobSpec(version: 1, jobID: jobID, sourceRecordID: "source", title: "Test",
            modelID: model.id, modelSHA256: model.sha256, nativeScale: 4, deliveryScale: scale, mode: "fullPage", pages: [page()])
    }
    private func result(scale: Int = 2, width: Int? = nil, hash: String? = nil) throws -> LanSRResult {
        let model = try model()
        return LanSRResult(modelID: model.id, modelSHA256: model.sha256, nativeScale: 4, deliveryScale: scale,
            width: width ?? 256 * scale, height: 384 * scale, bytes: 100, sha256: hash ?? String(repeating: "b", count: 64),
            engine: "PyTorch", device: "cuda", deviceName: "Test GPU", precision: "float32", torchVersion: "test",
            cudaVersion: "test", license: "CC-BY-NC-4.0", sourceURL: "https://github.com/the-database/MangaJaNai/releases/tag/3.0.0",
            mode: "fullPage", downsampling: scale == 2 ? "lanczos" : "none", seconds: 1)
    }

    func testLANAddressAndPublicHostRejection() {
        for host in ["192.168.5.8", "10.0.0.1", "172.31.0.1", "fc00::1"] { XCTAssertTrue(LanSRContract.isLAN(host), host) }
        for host in ["8.8.8.8", "127.0.0.1", "0.0.0.0", "::1", "224.0.0.1", "example.local", "192.168.1.1@evil.test"] {
            XCTAssertFalse(LanSRContract.isLAN(host), host)
        }
    }
    func testPairingExpirationAndPinAreMandatory() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func payload(host: String = "192.168.1.2", pin: String = String(repeating: "a", count: 64), expiry: Double = 1_700_000_300) throws -> String {
            let value = LanSRPairingPayload(version: 1, host: host, port: 18443, serverID: serverID,
                certificateSHA256: pin, pairingSecret: String(repeating: "x", count: 43), expiresAt: expiry)
            return String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        }
        XCTAssertEqual(try LanSRPairingPayload.parse(payload(), now: now).serverID, serverID)
        XCTAssertThrowsError(try LanSRPairingPayload.parse(payload(host: "8.8.8.8"), now: now))
        XCTAssertThrowsError(try LanSRPairingPayload.parse(payload(pin: "short"), now: now))
        XCTAssertThrowsError(try LanSRPairingPayload.parse(payload(expiry: now.timeIntervalSince1970), now: now))
        XCTAssertThrowsError(try LanSRPairingPayload.parse(payload(expiry: now.timeIntervalSince1970 + 601), now: now))
    }
    func testPinnedEndpointCannotRedirectOrUsePublicHost() throws {
        let server = LanSRServer(host: "192.168.5.8", port: 18443, serverID: serverID, certificateSHA256: String(repeating: "a", count: 64))
        XCTAssertEqual(try server.url(path: "/v1/capabilities").scheme, "https")
        XCTAssertThrowsError(try server.url(path: "/v1/../elsewhere"))
        XCTAssertThrowsError(try server.url(path: "/v1/jobs?redirect=1"))
        let ipv6 = LanSRServer(host: "fc00::1", port: 18443, serverID: serverID, certificateSHA256: String(repeating: "a", count: 64))
        XCTAssertTrue(try ipv6.url(path: "/v1/capabilities").absoluteString.contains("[fc00::1]"))
    }
    func testNativeFourWithDeliveryTwoOrFour() throws {
        try model().validatePage(width: 1000, height: 1500, scale: 2)
        try result().validate(spec: spec(), page: page())
        try result(scale: 4).validate(spec: spec(scale: 4), page: page())
        XCTAssertThrowsError(try result(width: 1024).validate(spec: spec(), page: page()))
        XCTAssertThrowsError(try result(hash: "invalid").validate(spec: spec(), page: page()))
    }
    func testAlignmentAndFourfoldPixelBudget() throws {
        XCTAssertThrowsError(try model().validatePage(width: 1500, height: 1500, scale: 4))
        XCTAssertThrowsError(try model().validatePage(width: 8192, height: 1, scale: 2))
        XCTAssertThrowsError(try model(native: 2).validatePage(width: 100, height: 100, scale: 4))
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
        XCTAssertFalse(decoded.submitted)
        job.prepared.append(page())
        XCTAssertThrowsError(try job.validateJournal())
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
