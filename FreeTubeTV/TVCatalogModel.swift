import Foundation
import Observation
import YouTubeKit

@MainActor
@Observable
final class TVCatalogModel {
    var query = ""
    private(set) var videos: [TVVideo] = []
    private(set) var isLoading = false
    var errorMessage: String?

    private let youtube = YouTubeModel()

    func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = TVCatalogError.emptyQuery.localizedDescription
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let response = try await SearchResponse.sendThrowingRequest(
                youtubeModel: youtube,
                data: [.query: trimmed]
            )
            videos = response.results.compactMap { result in
                guard let video = result as? YTVideo else { return nil }
                return TVVideo(
                    id: video.videoId,
                    title: video.title ?? "Untitled video",
                    channel: video.channel?.name ?? "YouTube",
                    thumbnailURL: video.thumbnails.last?.url,
                    duration: video.timeLength ?? ""
                )
            }
            if videos.isEmpty { errorMessage = "No videos found." }
        } catch {
            errorMessage = TVCatalogError.requestFailed.localizedDescription
        }
    }

    func streamURL(for video: TVVideo) async throws -> URL {
        do {
            let response = try await VideoInfosResponse.sendThrowingRequest(
                youtubeModel: youtube,
                data: [.query: video.id]
            )
            if let streamingURL = response.streamingURL { return streamingURL }
            if let progressive = response.defaultFormats.first(where: { $0.url != nil })?.url {
                return progressive
            }
            throw TVCatalogError.noPlayableStream
        } catch let error as TVCatalogError {
            throw error
        } catch {
            throw TVCatalogError.requestFailed
        }
    }
}
