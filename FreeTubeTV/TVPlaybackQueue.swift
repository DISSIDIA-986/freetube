import Foundation

/// Deterministic queue operations shared by shelves and collection screens.
enum TVPlaybackQueue {
    static func remaining(after video: TVVideo, in videos: [TVVideo]) -> [TVVideo] {
        guard let index = videos.firstIndex(of: video) else { return [] }
        return Array(videos.dropFirst(index + 1))
    }

    static func popNext(from queue: inout [TVVideo]) -> TVVideo? {
        guard !queue.isEmpty else { return nil }
        return queue.removeFirst()
    }
}
