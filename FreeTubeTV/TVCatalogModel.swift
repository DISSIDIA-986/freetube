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
    private(set) var regionProfile: TVRegionProfile

    private let youtube = YouTubeModel()
    private(set) var gatewayHost: String
    private let gatewayPort = 8787

    init() {
        let defaults = UserDefaults.standard
        gatewayHost = defaults.string(forKey: "tv.freetube.gatewayHost") ?? "192.168.1.79"
        regionProfile = TVRegionProfile(rawValue: defaults.string(forKey: "tv.freetube.region") ?? "") ?? .chinaChinese
        youtube.selectedLocale = regionProfile.rawValue
    }

    var gatewayBaseURL: URL? {
        URL(string: "http://\(gatewayHost):\(gatewayPort)")
    }

    func updateGatewayHost(_ host: String) {
        let cleaned = host.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "https://", with: "")
            .split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
        gatewayHost = cleaned
        UserDefaults.standard.set(cleaned, forKey: "tv.freetube.gatewayHost")
    }

    func updateRegionProfile(_ profile: TVRegionProfile) {
        guard profile != regionProfile else { return }
        regionProfile = profile
        youtube.selectedLocale = profile.rawValue
        UserDefaults.standard.set(profile.rawValue, forKey: "tv.freetube.region")
        homeVideos = []
        videos = []
        isShowingSearchResults = false
        errorMessage = nil
    }

    func checkGateway() async -> Bool {
        guard let base = gatewayBaseURL else { return false }
        do {
            let (_, response) = try await URLSession.shared.data(from: base.appendingPathComponent("healthz"))
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

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

    func playbackSource(for video: TVVideo) async throws -> TVPlaybackSource {
        if let gatewaySource = try? await resolveViaGateway(videoID: video.id) {
            print("FreeTubeTV playback: using Mac gateway")
            return gatewaySource
        }
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
                return TVPlaybackSource(videoURL: progressive, audioURL: nil)
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
                    return TVPlaybackSource(videoURL: progressive, audioURL: nil)
                }
                if let source = progressiveSource(from: detailed.downloadFormats) {
                    print("FreeTubeTV playback: selected detailed download tracks video=\(source.videoURL.absoluteString) audio=\(source.audioURL?.absoluteString ?? "none")")
                    return source
                }
            }
            if let hlsURL {
                print("FreeTubeTV playback: falling back to HLS")
                return TVPlaybackSource(videoURL: hlsURL, audioURL: nil)
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

    private func resolveViaGateway(videoID: String) async throws -> TVPlaybackSource {
        guard let gatewayBaseURL else { throw TVCatalogError.requestFailed }
        var components = URLComponents(url: gatewayBaseURL.appendingPathComponent("resolve"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "id", value: videoID)]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw TVCatalogError.requestFailed
        }
        struct GatewayResponse: Decodable { let url: URL }
        let result = try JSONDecoder().decode(GatewayResponse.self, from: data)
        return TVPlaybackSource(videoURL: result.url, audioURL: nil)
    }

    private func loadDiscoveryFallback() async throws {
        let response = try await SearchResponse.sendThrowingRequest(
            youtubeModel: youtube,
            data: [.query: regionProfile.discoveryQuery]
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
        // Only legacy muxed itags contain both an audio and video track. Adaptive itags such
        // as 137/299 are video-only even though YouTubeKit represents them as VideoDownloadFormat.
        let muxedItags: Set<Int> = [18, 22, 34, 35, 37, 43, 44, 45, 46, 59, 78]
        return candidates
            .filter { $0.2 }
            .filter { url, _, _ in
                guard let itag = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "itag" })?.value,
                      let value = Int(itag) else { return false }
                return muxedItags.contains(value)
            }
            .sorted { $0.1 > $1.1 }
            .first?.0
    }

    private func progressiveSource(from formats: [any AdaptiveDownloadFormat]) -> TVPlaybackSource? {
        if let muxed = progressiveURL(from: formats) {
            return TVPlaybackSource(videoURL: muxed, audioURL: nil)
        }

        let videos = formats.compactMap { format -> (URL, Int)? in
            guard let video = format as? VideoDownloadFormat,
                  let url = video.url,
                  let codec = video.codec?.lowercased(),
                  (codec.contains("avc1") || codec.contains("avc")),
                  video.mimeType?.contains("video/mp4") == true else { return nil }
            return (url, video.height ?? 0)
        }.sorted { $0.1 > $1.1 }

        let audios = formats.compactMap { format -> (URL, Int)? in
            guard let audio = format as? AudioOnlyFormat,
                  let url = audio.url,
                  audio.mimeType?.contains("audio/mp4") == true else { return nil }
            return (url, audio.bitrate ?? 0)
        }.sorted { $0.1 > $1.1 }

        guard let video = videos.first, let audio = audios.first else { return nil }
        return TVPlaybackSource(videoURL: video.0, audioURL: audio.0)
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
