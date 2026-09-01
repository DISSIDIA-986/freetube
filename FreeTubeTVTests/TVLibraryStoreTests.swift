import XCTest
@testable import FreeTubeTV

@MainActor
final class TVLibraryStoreTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "TVLibraryStoreTests-\(UUID().uuidString)")!
    }

    func testEmptyStoreAndInvalidDataAreSafe() {
        defaults.set(Data("not-json".utf8), forKey: "tv.freetube.favorites")
        let store = TVLibraryStore(defaults: defaults)
        XCTAssertTrue(store.favorites.isEmpty)
        XCTAssertTrue(store.history.isEmpty)
    }

    func testFavoriteToggleIsIdempotent() {
        let store = TVLibraryStore(defaults: defaults)
        let video = makeVideo(id: "one")
        store.toggleFavorite(video)
        XCTAssertTrue(store.isFavorite(video))
        store.toggleFavorite(video)
        XCTAssertFalse(store.isFavorite(video))
        store.toggleFavorite(video)
        XCTAssertEqual(store.favorites.map(\.id), ["one"])
    }

    func testHistoryMovesDuplicateToFrontAndCapsAtFifty() {
        let store = TVLibraryStore(defaults: defaults)
        for index in 0..<50 {
            store.recordHistory(makeVideo(id: "video-\(index)"))
        }
        store.recordHistory(makeVideo(id: "video-10"))
        XCTAssertEqual(store.history.count, 50)
        XCTAssertEqual(store.history.first?.id, "video-10")
        XCTAssertEqual(Set(store.history.map(\.id)).count, 50)

        store.recordHistory(makeVideo(id: "new-video"))
        XCTAssertEqual(store.history.count, 50)
        XCTAssertEqual(store.history.first?.id, "new-video")
        XCTAssertFalse(store.history.contains { $0.id == "video-0" })
    }

    func testClearHistoryRemovesPersistedEntries() {
        let store = TVLibraryStore(defaults: defaults)
        store.recordHistory(makeVideo(id: "one"))
        store.clearHistory()
        XCTAssertTrue(store.history.isEmpty)
        XCTAssertTrue(TVLibraryStore(defaults: defaults).history.isEmpty)
    }

    func testCompletedVideoProgressCanBeClearedForFreshPlayback() {
        let store = TVLibraryStore(defaults: defaults)
        let video = makeVideo(id: "completed")
        store.saveProgress(599, for: video)
        XCTAssertEqual(store.progress(for: video), 599)
        store.clearProgress(for: video)
        XCTAssertNil(store.progress(for: video))
        XCTAssertNil(TVLibraryStore(defaults: defaults).progress(for: video))
    }

    func testMergeHistoryDeduplicatesAndKeepsRemoteOrder() {
        let store = TVLibraryStore(defaults: defaults)
        store.recordHistory(makeVideo(id: "local"))
        store.mergeHistory([makeVideo(id: "remote"), makeVideo(id: "local")])
        XCTAssertEqual(store.history.map(\.id), ["remote", "local"])
    }

    func testChannelSorterPlacesNewestEnglishVideosFirst() {
        let videos = [
            makeVideo(id: "old", publishedRelative: "2 days ago"),
            makeVideo(id: "new", publishedRelative: "3 hours ago"),
            makeVideo(id: "middle", publishedRelative: "1 day ago")
        ]

        XCTAssertEqual(TVChannelVideoSorter.newestFirst(videos).map(\.id), ["new", "middle", "old"])
    }

    func testChannelSorterSupportsChineseAndKeepsUnknownItemsLast() {
        let videos = [
            makeVideo(id: "unknown", publishedRelative: nil),
            makeVideo(id: "old", publishedRelative: "昨天"),
            makeVideo(id: "new", publishedRelative: "刚刚"),
            makeVideo(id: "also-unknown", publishedRelative: "premiere")
        ]

        XCTAssertEqual(TVChannelVideoSorter.newestFirst(videos).map(\.id), ["new", "old", "unknown", "also-unknown"])
    }

    func testRelativeAgeRejectsEmptyAndUnrecognizedLabels() {
        XCTAssertNil(TVChannelVideoSorter.relativeAge(nil))
        XCTAssertNil(TVChannelVideoSorter.relativeAge(""))
        XCTAssertNil(TVChannelVideoSorter.relativeAge("premieres tomorrow"))
        XCTAssertEqual(TVChannelVideoSorter.relativeAge("1 month ago"), 2_629_800)
    }

    func testVideoDecodingRemainsCompatibleWithOlderSavedData() throws {
        let data = Data(#"{"id":"legacy","title":"Legacy","channel":"Channel","channelID":null,"thumbnailURL":null,"duration":"1:00"}"#.utf8)
        let video = try JSONDecoder().decode(TVVideo.self, from: data)
        XCTAssertEqual(video.id, "legacy")
        XCTAssertNil(video.publishedRelative)
    }

    func testPlaybackDiagnosticsAreBoundedAndPersistedWithoutSensitiveURLs() {
        let suite = UserDefaults(suiteName: "TVPlaybackDiagnosticsTests-\(UUID().uuidString)")!
        let diagnostics = TVPlaybackDiagnostics(defaults: suite)
        for index in 0..<55 {
            diagnostics.record(videoID: "video-\(index)", resolution: 480, succeeded: false, error: "https://secret.example/\(index) \(String(repeating: "x", count: 400))")
        }

        XCTAssertEqual(diagnostics.incidents.count, 50)
        XCTAssertEqual(TVPlaybackDiagnostics(defaults: suite).incidents.count, 50)
        XCTAssertLessThanOrEqual(diagnostics.incidents.first?.error?.count ?? 0, 300)
    }

    func testAppStatePersistsAndClampsSelectedTab() {
        let suite = UserDefaults(suiteName: "TVAppStateTests-\(UUID().uuidString)")!
        let state = TVAppState(defaults: suite)
        state.selectedTab = 2
        XCTAssertEqual(TVAppState(defaults: suite).selectedTab, 2)
        state.selectedTab = 99
        XCTAssertEqual(state.selectedTab, 2)
        state.selectedTab = -1
        XCTAssertEqual(state.selectedTab, 0)
    }

    func testPlaybackQueueReturnsRemainingItemsInOrder() {
        let videos = (0..<4).map { makeVideo(id: "video-\($0)") }
        XCTAssertEqual(TVPlaybackQueue.remaining(after: videos[1], in: videos).map(\.id), ["video-2", "video-3"])
    }

    func testPlaybackQueueHandlesMissingAndLastItems() {
        let videos = [makeVideo(id: "first"), makeVideo(id: "last")]
        XCTAssertTrue(TVPlaybackQueue.remaining(after: videos[1], in: videos).isEmpty)
        XCTAssertTrue(TVPlaybackQueue.remaining(after: makeVideo(id: "missing"), in: videos).isEmpty)
    }

    func testPlaybackQueuePopIsSafeForEmptyAndConsumesOnce() {
        var queue = [makeVideo(id: "one")]
        XCTAssertEqual(TVPlaybackQueue.popNext(from: &queue)?.id, "one")
        XCTAssertNil(TVPlaybackQueue.popNext(from: &queue))
        XCTAssertTrue(queue.isEmpty)
    }

    func testYouTubeHandoffBuildsExactVideoURL() {
        XCTAssertEqual(
            TVYouTubeHandoff.url(for: "abc123")?.absoluteString,
            "https://www.youtube.com/watch?v=abc123"
        )
        XCTAssertEqual(TVYouTubeHandoff.appURL(for: "abc123")?.absoluteString, "youtube://watch/abc123")
    }

    func testYouTubeHandoffRejectsEmptyOrWhitespaceOnlyIDs() {
        XCTAssertNil(TVYouTubeHandoff.url(for: ""))
        XCTAssertNil(TVYouTubeHandoff.url(for: "   \n"))
    }

    private func makeVideo(id: String, publishedRelative: String? = nil) -> TVVideo {
        TVVideo(id: id, title: "Title \(id)", channel: "Channel", thumbnailURL: nil, duration: "1:00", publishedRelative: publishedRelative)
    }
}
