import XCTest
@testable import PicaX

@MainActor
final class AutoSuperResolutionQueueTests: XCTestCase {
    func testDownloadTaskPersistsAutoSuperResolutionRequest() throws {
        let task = ComicDownloadTask(
            item: makeItem(),
            downloadsComments: false,
            autoSuperResolutionAfterDownload: true)

        let decoded = try JSONDecoder().decode(
            ComicDownloadTask.self,
            from: JSONEncoder().encode(task))

        XCTAssertEqual(decoded.autoSuperResolutionAfterDownload, true)
        XCTAssertTrue(decoded.requestsAutoSuperResolution)
    }

    func testLegacyDownloadTaskWithoutAutoSuperResolutionDecodes() throws {
        let task = ComicDownloadTask(item: makeItem(), downloadsComments: false)
        let data = try JSONEncoder().encode(task)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "autoSuperResolutionAfterDownload")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(ComicDownloadTask.self, from: legacyData)

        XCTAssertNil(decoded.autoSuperResolutionAfterDownload)
        XCTAssertFalse(decoded.requestsAutoSuperResolution)
    }

    func testBackgroundAutoSuperResolutionDefaultsToEnabled() throws {
        let suiteName = "PicaXTests.AutoSuperResolution.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(DownloadSettingsKey.allowsAutoSuperResolutionInBackground(defaults: defaults))

        defaults.set(false, forKey: DownloadSettingsKey.autoSuperResolutionInBackground)
        XCTAssertFalse(DownloadSettingsKey.allowsAutoSuperResolutionInBackground(defaults: defaults))
    }

    func testJmAutoLoginDefaultsToEnabled() throws {
        let suiteName = "PicaXTests.JmAutoLogin.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(PlatformFeatureSettings.jmAutoLogin(defaults: defaults))

        defaults.set(false, forKey: PlatformFeatureSettingsKey.jmAutoLogin)
        XCTAssertFalse(PlatformFeatureSettings.jmAutoLogin(defaults: defaults))
    }

    func testJmFavoriteUpdatedSortMapsToServerValue() {
        let suiteName = "PicaXTests.JmFavoriteSort.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(JmFavoriteSort.updated.rawValue, forKey: PlatformFeatureSettingsKey.jmFavoriteSort)
        XCTAssertEqual(PlatformFeatureSettings.jmFavoriteSort(defaults: defaults), "mp")

        defaults.set("unknown", forKey: PlatformFeatureSettingsKey.jmFavoriteSort)
        XCTAssertEqual(PlatformFeatureSettings.jmFavoriteSort(defaults: defaults), "mr")
    }

    private func makeItem() -> ComicListItem {
        ComicListItem(
            id: "auto-super-resolution-test",
            platform: .picacg,
            title: "自动超分测试",
            subtitle: "",
            coverURLString: "",
            tags: [],
            pageCount: nil,
            likesCount: nil,
            favoriteDate: nil)
    }
}
