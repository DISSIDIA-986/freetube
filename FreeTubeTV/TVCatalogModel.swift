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
        print("FreeTubeTV playback: resolving \(video.id)")
        do {
            let response = try await VideoInfosResponse.sendThrowingRequest(
                youtubeModel: youtube,
                data: [.query: video.id]
            )
            print("FreeTubeTV playback: base response hls=\(response.streamingURL != nil) default=\(response.defaultFormats.count)")
            let hlsURL = response.streamingURL
            if let progressive = progressiveURL(from: response.defaultFormats) {
                print("FreeTubeTV playback: selected base progressive MP4 \(progressive.absoluteString)")
                return progressive
            }

            // VideoInfosResponse often returns format metadata without signed URLs. The
            // download-format response runs YouTubeKit's URL deciphering path and usually
            // supplies a combined audio/video MP4 that AVPlayer can consume directly.
            if var detailed = try? await VideoInfosWithDownloadFormatsResponse.sendThrowingRequest(
                youtubeModel: youtube,
                data: [.query: video.id]
            ) {
                // The HTML response contains ciphered format URLs. YouTubeKit exposes the
                // player needed to decode them on the nested VideoInfosResponse; without
                // this call every MP4 URL remains nil and playback falls back to HLS.
                if let player = detailed.videoInfos.player {
                    try? detailed.deciphersURLs(player: player)
                }
                print("FreeTubeTV playback: detailed default=\(detailed.defaultFormats.count) download=\(detailed.downloadFormats.count)")
                if let progressive = progressiveURL(from: detailed.defaultFormats) {
                    print("FreeTubeTV playback: selected detailed default MP4 \(progressive.absoluteString)")
                    return progressive
                }
                if let progressive = progressiveURL(from: detailed.downloadFormats) {
                    print("FreeTubeTV playback: selected detailed download MP4 \(progressive.absoluteString)")
                    return progressive
                }
            }
            if let hlsURL {
                print("FreeTubeTV playback: falling back to HLS")
                return hlsURL
            }
            throw TVCatalogError.noPlayableStream
        } catch let error as TVCatalogError {
            print("FreeTubeTV playback: catalog error \(String(reflecting: error))")
            throw error
        } catch {
            print("FreeTubeTV playback: resolver error \(String(reflecting: error))")
            // Keep the YouTubeKit error intact. Converting it to a generic requestFailed
            // error hides cipher/player/network failures and makes tvOS playback impossible
            // to diagnose from the device.
            throw error
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

    private func progressiveURL(from formats: [any AdaptiveDownloadFormat]) -> URL? {
        let candidates = formats.compactMap { format -> (URL, Int, Bool)? in
            guard let video = format as? VideoDownloadFormat, let url = video.url else { return nil }
            let codec = video.codec?.lowercased() ?? ""
            let isH264 = codec.contains("avc1") || codec.contains("avc")
            let knownIncompatible = codec.contains("vp9") || codec.contains("vp09") || codec.contains("av01")
            return (url, video.height ?? 0, isH264 && !knownIncompatible)
        }

        // Prefer H.264/AAC MP4. YouTube often orders VP9/AV1 first, but those streams can
        // produce a black AVPlayer surface on tvOS even though the URL itself is valid.
        return candidates
            .filter { $0.2 }
            .sorted { $0.1 > $1.1 }
            .first?.0
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
