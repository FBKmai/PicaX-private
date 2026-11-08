import Foundation
import XCTest
@testable import PicaX

final class SuperResolutionBatchTests: XCTestCase {
    func testScopeSelectsCurrentChapterOrWholeBook() {
        XCTAssertEqual(
            ReaderBatchRenderScope.wholeBook.chapterIndices(totalChapters: 3, currentChapterIndex: 2),
            [0, 1, 2])
        XCTAssertEqual(
            ReaderBatchRenderScope.currentChapter.chapterIndices(totalChapters: 3, currentChapterIndex: 2),
            [2])
        XCTAssertEqual(
            ReaderBatchRenderScope.currentChapter.chapterIndices(totalChapters: 3, currentChapterIndex: -5),
            [0])
        XCTAssertEqual(
            ReaderBatchRenderScope.currentChapter.chapterIndices(totalChapters: 3, currentChapterIndex: 99),
            [2])
        XCTAssertEqual(
            ReaderBatchRenderScope.wholeBook.chapterIndices(totalChapters: 0, currentChapterIndex: 0),
            [])
    }

    func testPageAndArchiveFileNamesAreStableAndPathFree() {
        XCTAssertEqual(
            ReaderBatchRenderStore.pageFileName(chapterIndex: 0, pageIndex: 0),
            "E001-P0001.png")
        XCTAssertEqual(
            ReaderBatchRenderStore.pageFileName(chapterIndex: 11, pageIndex: 1_233),
            "E012-P1234.png")
        XCTAssertEqual(
            ReaderBatchRenderStore.archiveFileName(bookTitle: "A/B: C"),
            "PicaX-A-B- C-2x.zip")
        XCTAssertEqual(ReaderBatchRenderStore.safeFileName("  "), "untitled")
        let longChineseTitle = String(repeating: "漫", count: 100)
        let truncated = ReaderBatchRenderStore.safeFileName(longChineseTitle)
        XCTAssertLessThanOrEqual(truncated.utf8.count, 80)
        XCTAssertFalse(truncated.isEmpty)
    }

    func testUnsupportedSizesAreSkippedButModelFailuresAreNot() {
        for error in [
            SuperResolutionError.fullPagePageUnsupported,
            SuperResolutionError.longPage,
            SuperResolutionError.unsuitableMangaPage,
            SuperResolutionError.budgetExceeded,
            SuperResolutionError.insufficientStorage
        ] {
            XCTAssertTrue(ReaderBatchRenderModel.isSkipped(error), "\(error) should be skipped")
        }
        XCTAssertFalse(ReaderBatchRenderModel.isSkipped(SuperResolutionError.modelUnavailable))
        XCTAssertFalse(ReaderBatchRenderModel.isSkipped(SuperResolutionError.inferenceFailed))
        XCTAssertTrue(ReaderBatchRenderModel.isSkipped(ReaderImageSourceError.budgetExceeded))
        XCTAssertFalse(ReaderBatchRenderModel.isSkipped(ReaderImageSourceError.invalidImage))
        XCTAssertTrue(ReaderBatchRenderModel.isFatal(SuperResolutionError.modelUnavailable))
        XCTAssertTrue(ReaderBatchRenderModel.isFatal(SuperResolutionError.insufficientStorage))
        XCTAssertFalse(ReaderBatchRenderModel.isFatal(SuperResolutionError.budgetExceeded))
        XCTAssertFalse(ReaderBatchRenderModel.isFatal(ReaderImageSourceError.invalidImage))
    }

    func testStoreWritesManifestAndBuildsArchiveWithoutDeletingOutputs() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PicaX-BatchTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try ReaderBatchRenderStore.createOutputDirectory(
            bookTitle: "Book/One",
            now: Date(timeIntervalSince1970: 0),
            root: root)
        XCTAssertEqual(directory.lastPathComponent, "Book-One-19700101-000000")

        var manifest = ReaderBatchRenderManifest(
            bookID: "book-1",
            bookTitle: "Book/One",
            scope: .wholeBook,
            preset: SuperResolutionPreset.color.rawValue,
            requestedMode: SuperResolutionInferenceMode.automatic.rawValue,
            computeUnit: SuperResolutionComputeUnit.cpuOnly.rawValue,
            createdAt: Date(timeIntervalSince1970: 0))
        manifest.status = .completed
        manifest.finishedAt = Date(timeIntervalSince1970: 10)
        manifest.chapters = [
            ReaderBatchRenderChapterRecord(
                chapterIndex: 0, title: "Chapter 1", pageCount: 1, status: .succeeded)
        ]
        manifest.pages = [
            ReaderBatchRenderPageRecord(
                chapterIndex: 0,
                chapterTitle: "Chapter 1",
                pageIndex: 0,
                sourceURLString: "https://example.com/1.jpg",
                status: .succeeded,
                fileName: "E001-P0001.png")
        ]
        try ReaderBatchRenderStore.writeManifest(manifest, to: directory)
        try ReaderBatchRenderStore.writeReadme(
            ReaderBatchRenderStore.readmeText(
                bookTitle: "Book/One",
                scope: .wholeBook,
                preset: .color,
                requestedMode: .automatic,
                chapterCount: 1,
                createdAt: Date(timeIntervalSince1970: 0)),
            to: directory)
        let pageURL = directory.appendingPathComponent("E001-P0001.png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 1]).write(to: pageURL)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            ReaderBatchRenderManifest.self,
            from: Data(contentsOf: directory.appendingPathComponent(
                ReaderBatchRenderStore.manifestName)))
        XCTAssertEqual(decoded.status, .completed)
        XCTAssertEqual(decoded.pages.first?.fileName, "E001-P0001.png")
        XCTAssertEqual(decoded.computeUnit, "cpuOnly")

        let archive = try ReaderBatchRenderStore.makeArchive(
            directory: directory,
            fileNames: ["E001-P0001.png"],
            archiveName: "Book-One-2x.zip")
        defer { ReaderBatchRenderStore.removeTemporaryArchive(archive) }
        XCTAssertEqual(archive.lastPathComponent, "Book-One-2x.zip")
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
        let archiveData = try Data(contentsOf: archive)
        XCTAssertGreaterThan(archiveData.count, 4)
        XCTAssertEqual(Array(archiveData.prefix(2)), [0x50, 0x4B])
        XCTAssertTrue(FileManager.default.fileExists(atPath: pageURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(
            ReaderBatchRenderStore.manifestName).path))
    }

    func testStoreRejectsMissingPageWhenBuildingArchive() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PicaX-BatchTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try ReaderBatchRenderStore.createOutputDirectory(
            bookTitle: "Book", root: root)
        XCTAssertThrowsError(try ReaderBatchRenderStore.makeArchive(
            directory: directory,
            fileNames: ["E001-P0001.png"],
            archiveName: "Book.zip")) { error in
            XCTAssertEqual(error as? ReaderBatchRenderError, .outputFileMissing("E001-P0001.png"))
        }
    }
}
