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

    private func makeVideo(id: String) -> TVVideo {
        TVVideo(id: id, title: "Title \(id)", channel: "Channel", thumbnailURL: nil, duration: "1:00")
    }
}
