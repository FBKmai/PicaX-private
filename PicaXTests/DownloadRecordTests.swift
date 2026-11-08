import XCTest
@testable import PicaX

@MainActor
final class DownloadRecordTests: XCTestCase {
    func testFullyDownloadedRequiresEveryKnownChapter() {
        XCTAssertFalse(makeRecord(totalChapterCount: 0, downloadedChapterCount: 0).isFullyDownloaded)
        XCTAssertFalse(makeRecord(totalChapterCount: 2, downloadedChapterCount: 1).isFullyDownloaded)
        XCTAssertTrue(makeRecord(totalChapterCount: 2, downloadedChapterCount: 2).isFullyDownloaded)
    }

    func testLegacyRecordWithoutSuperResolutionStillDecodes() throws {
        let record = makeRecord(totalChapterCount: 1, downloadedChapterCount: 1)
        let data = try JSONEncoder().encode(record)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "superResolution")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(DownloadRecord.self, from: legacyData)
        XCTAssertNil(decoded.superResolution)
        XCTAssertFalse(decoded.isSuperResolution)
        XCTAssertEqual(decoded.statusText, "已下载 1 页")
    }

    func testSuperResolutionInfoRoundTripsAndShapesStatus() throws {
        let source = makeRecord(totalChapterCount: 1, downloadedChapterCount: 1)
        let srItem = DownloadService.superResolutionItem(for: source.item)
        XCTAssertEqual(srItem.id, "picax-sr-download-test")
        XCTAssertEqual(srItem.platform, source.item.platform)
        XCTAssertEqual(srItem.title, source.item.title)

        let info = SuperResolutionDownloadInfo(
            sourceRecordID: source.id,
            sourceItemID: source.item.id,
            sourcePlatform: source.item.platform,
            sourceTitle: source.item.title,
            createdAt: .distantPast,
            completedAt: nil,
            expectedPageCounts: [0: 2])
        let record = DownloadRecord(
            item: srItem,
            chapters: source.chapters,
            totalChapterCount: 1,
            totalBytes: 1,
            directoryName: DownloadService.directoryName(for: srItem),
            coverFileName: nil,
            detail: nil,
            comments: [],
            updatedAt: .distantPast,
            superResolution: info)

        XCTAssertTrue(record.isSuperResolution)
        XCTAssertFalse(record.isFullyDownloaded)
        XCTAssertEqual(record.statusText, "超分中断 1 页")

        let decoded = try JSONDecoder().decode(
            DownloadRecord.self,
            from: JSONEncoder().encode(record))
        XCTAssertEqual(decoded.superResolution, info)
        XCTAssertTrue(decoded.isSuperResolution)

        var completed = record
        completed.superResolution?.completedAt = .distantPast
        XCTAssertFalse(completed.isFullyDownloaded)
        XCTAssertEqual(completed.statusText, "超分部分完成 1 页")

        completed.chapters[0].pageCount = 2
        XCTAssertTrue(completed.isFullyDownloaded)
        XCTAssertEqual(completed.statusText, "超分完成 2 页")
    }

    func testPageFilesAcceptNormalAndSuperResolutionNames() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PicaX-PageFiles-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try Data().write(to: directory.appendingPathComponent("0001.jpg"))
        try Data().write(to: directory.appendingPathComponent("P0002.png"))
        try Data().write(to: directory.appendingPathComponent("cover.jpg"))
        try Data().write(to: directory.appendingPathComponent("README.txt"))

        let pages = try DownloadImageValidation.pageFiles(in: directory)
        XCTAssertEqual(Set(pages.keys), [0, 1])
        XCTAssertEqual(pages[0]?.lastPathComponent, "0001.jpg")
        XCTAssertEqual(pages[1]?.lastPathComponent, "P0002.png")
    }

    private func makeRecord(totalChapterCount: Int, downloadedChapterCount: Int) -> DownloadRecord {
        let item = ComicListItem(
            id: "download-test",
            platform: .picacg,
            title: "下载测试",
            subtitle: "",
            coverURLString: "",
            tags: [],
            pageCount: nil,
            likesCount: nil,
            favoriteDate: nil
        )
        let chapters = (0..<downloadedChapterCount).map { index in
            DownloadedChapterRecord(
                index: index,
                chapter: ComicChapter(id: "chapter-\(index)", title: "第 \(index + 1) 章", subtitle: nil),
                pageCount: 1,
                bytes: 1,
                downloadedAt: .distantPast
            )
        }
        return DownloadRecord(
            item: item,
            chapters: chapters,
            totalChapterCount: totalChapterCount,
            totalBytes: Int64(downloadedChapterCount),
            directoryName: "download-test",
            coverFileName: nil,
            detail: nil,
            comments: [],
            updatedAt: .distantPast
        )
    }
}
