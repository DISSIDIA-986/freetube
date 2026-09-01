import Foundation
import Observation
import YouTubeKit

@MainActor
@Observable
final class TVCatalogModel {
    var query = ""
    private(set) var homeVideos: [TVVideo] = []
    private(set) var videos: [TVVideo] = []
    private(set) var isLoading = false
    private(set) var isShowingSearchResults = false
    var errorMessage: String?

    private let youtube = YouTubeModel()

    func loadHome() async {
        guard homeVideos.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let response = try await HomeScreenResponse.sendThrowingRequest(
                youtubeModel: youtube,
                data: [:]
            )
            let results = response.results.map(makeVideo(from:))
            if !results.isEmpty {
                homeVideos = results
                return
            }
            try await loadDiscoveryFallback()
        } catch {
            do {
                try await loadDiscoveryFallback()
            } catch {
                errorMessage = TVCatalogError.requestFailed.localizedDescription
            }
        }
    }

    func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = TVCatalogError.emptyQuery.localizedDescription
            return
        }
        isShowingSearchResults = true
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
                return makeVideo(from: video)
            }
            if videos.isEmpty { errorMessage = "No videos found." }
        } catch {
            errorMessage = TVCatalogError.requestFailed.localizedDescription
        }
    }

    func resetToHome() {
        query = ""
        videos = []
        isShowingSearchResults = false
        errorMessage = nil
    }

    func streamURL(for video: TVVideo) async throws -> URL {
        do {
            let response = try await VideoInfosResponse.sendThrowingRequest(
                youtubeModel: youtube,
                data: [.query: video.id]
            )
            let hlsURL = response.streamingURL
            if let progressive = response.defaultFormats
                .compactMap({ $0 as? VideoDownloadFormat })
                .compactMap(\.url)
                .first { return progressive }

            // VideoInfosResponse often returns format metadata without signed URLs. The
            // download-format response runs YouTubeKit's URL deciphering path and usually
            // supplies a combined audio/video MP4 that AVPlayer can consume directly.
            if let detailed = try? await VideoInfosWithDownloadFormatsResponse.sendThrowingRequest(
                youtubeModel: youtube,
                data: [.query: video.id]
            ) {
                if let progressive = detailed.defaultFormats
                    .compactMap({ $0 as? VideoDownloadFormat })
                    .compactMap(\.url)
                    .first { return progressive }
                if let progressive = detailed.downloadFormats
                    .compactMap({ $0 as? VideoDownloadFormat })
                    .compactMap(\.url)
                    .first { return progressive }
            }
            if let hlsURL { return hlsURL }
            throw TVCatalogError.noPlayableStream
        } catch let error as TVCatalogError {
            throw error
        } catch {
            throw TVCatalogError.requestFailed
        }
    }

    private func loadDiscoveryFallback() async throws {
        let response = try await SearchResponse.sendThrowingRequest(
            youtubeModel: youtube,
            data: [.query: "Trending"]
        )
        homeVideos = response.results.compactMap { result in
            guard let video = result as? YTVideo else { return nil }
            return makeVideo(from: video)
        }
        if homeVideos.isEmpty { throw TVCatalogError.requestFailed }
    }

    private func makeVideo(from video: YTVideo) -> TVVideo {
        TVVideo(
            id: video.videoId,
            title: video.title ?? "Untitled video",
            channel: video.channel?.name ?? "YouTube",
            thumbnailURL: video.thumbnails.last?.url,
            duration: video.timeLength ?? ""
        )
    }
}
