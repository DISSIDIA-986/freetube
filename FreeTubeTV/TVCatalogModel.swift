import Foundation
import Observation
import YouTubeKit

@MainActor
@Observable
final class TVCatalogModel {
    private static let regionDefaultsKey = "tv.freetube.region.v2"
    var query = ""
    private(set) var homeVideos: [TVVideo] = []
    private(set) var isLoadingMoreHome = false
    private(set) var hasMoreHome = true
    private(set) var subscriptionVideos: [TVVideo] = []
    private(set) var likedVideos: [TVVideo] = []
    private(set) var cloudPlaylists: [TVCollection] = []
    private(set) var videos: [TVVideo] = []
    private(set) var collections: [TVCollection] = []
    private(set) var isLoading = false
    private(set) var isShowingSearchResults = false
    var errorMessage: String?
    private(set) var regionProfile: TVRegionProfile
    private(set) var account: TVAccount?

    private let youtube = YouTubeModel()
    private(set) var gatewayHost: String
    private let gatewayPort = 8787

    struct Pairing: Sendable {
        let code: String
        let expiresAt: Date
    }

    init() {
        let defaults = UserDefaults.standard
        gatewayHost = defaults.string(forKey: "tv.freetube.gatewayHost") ?? "192.168.1.79"
        regionProfile = TVRegionProfile(rawValue: defaults.string(forKey: Self.regionDefaultsKey) ?? "") ?? .northAmerica
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
        UserDefaults.standard.set(profile.rawValue, forKey: Self.regionDefaultsKey)
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

    func startGatewayPairing() async throws -> Pairing {
        guard let base = gatewayBaseURL else { throw TVCatalogError.requestFailed }
        var request = URLRequest(url: base.appendingPathComponent("pair/start"))
        request.httpMethod = "POST"
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw TVCatalogError.requestFailed
        }
        let result = try JSONDecoder().decode(PairingResponse.self, from: data)
        return Pairing(code: result.code, expiresAt: Date(timeIntervalSince1970: result.expiresAt / 1000))
    }

    func gatewayPairingStatus(code: String) async -> PairingStatus {
        guard let base = gatewayBaseURL,
              var components = URLComponents(url: base.appendingPathComponent("pair/status"), resolvingAgainstBaseURL: false) else {
            return .failed
        }
        components.queryItems = [URLQueryItem(name: "code", value: code)]
        do {
            let (data, response) = try await URLSession.shared.data(from: components.url!)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return .failed }
            let result = try JSONDecoder().decode(PairingStatusResponse.self, from: data)
            return result.status == "paired" ? .paired : .pending
        } catch {
            return .failed
        }
    }

    func loadGatewayAccount() async -> Bool {
        guard let base = gatewayBaseURL else { return false }
        do {
            let (data, response) = try await URLSession.shared.data(from: base.appendingPathComponent("account"))
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return false }
            let result = try JSONDecoder().decode(AccountResponse.self, from: data)
            guard result.signedIn, let title = result.title, let channelID = result.channelID else { account = nil; return false }
            account = TVAccount(title: title, channelID: channelID, thumbnailURL: result.thumbnailURL)
            return true
        } catch { return false }
    }

    func loadGatewaySubscriptions() async {
        guard let base = gatewayBaseURL else { return }
        do {
            let (data, response) = try await URLSession.shared.data(from: base.appendingPathComponent("subscriptions"))
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            let result = try JSONDecoder().decode(SubscriptionsResponse.self, from: data)
            subscriptionVideos = result.videos.map { TVVideo(id: $0.id, title: $0.title, channel: $0.channel, thumbnailURL: $0.thumbnailURL, duration: "") }
        } catch { subscriptionVideos = [] }
    }

    func loadCloudLibrary() async {
        guard let base = gatewayBaseURL else { return }
        do {
            async let likesRequest = URLSession.shared.data(from: base.appendingPathComponent("likes"))
            async let playlistsRequest = URLSession.shared.data(from: base.appendingPathComponent("playlists"))
            let (likesData, likesResponse) = try await likesRequest
            let (playlistData, playlistResponse) = try await playlistsRequest
            if (likesResponse as? HTTPURLResponse)?.statusCode == 200 {
                let result = try JSONDecoder().decode(VideoListResponse.self, from: likesData)
                likedVideos = result.videos.map { TVVideo(id: $0.id, title: $0.title, channel: $0.channel, thumbnailURL: $0.thumbnailURL, duration: "") }
            }
            if (playlistResponse as? HTTPURLResponse)?.statusCode == 200 {
                let result = try JSONDecoder().decode(PlaylistListResponse.self, from: playlistData)
                cloudPlaylists = result.playlists.map { TVCollection(id: $0.id, title: $0.title, subtitle: "\($0.count) videos", thumbnailURL: $0.thumbnailURL, kind: .playlist) }
            }
        } catch { }
    }

    func syncHistoryToGateway() async {
        guard let base = gatewayBaseURL, let history = libraryStore?.history else { return }
        do {
            let (remoteData, remoteResponse) = try await URLSession.shared.data(from: base.appendingPathComponent("sync/history"))
            if (remoteResponse as? HTTPURLResponse)?.statusCode == 200 {
                let remote = try JSONDecoder().decode(SyncedHistoryResponse.self, from: remoteData)
                libraryStore?.mergeHistory(remote.videos)
            }
            let mergedHistory = libraryStore?.history ?? history
            var request = URLRequest(url: base.appendingPathComponent("sync/history"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(["videos": mergedHistory])
            _ = try await URLSession.shared.data(for: request)
        } catch { }
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
            appendHomeVideos(response.results.map(makeVideo(from:)))
            homeContinuationToken = response.continuationToken
            homeVisitorData = response.visitorData
            while homeVideos.count < Self.minimumHomeVideos, homeContinuationToken != nil {
                await fetchMoreHome()
            }
            if homeVideos.isEmpty { try await loadDiscoveryFallback() }
        } catch {
            do {
                try await loadDiscoveryFallback()
            } catch {
                errorMessage = TVCatalogError.requestFailed.localizedDescription
            }
        }
    }

    func reloadHome() async {
        homeVideos = []
        homeContinuationToken = nil
        homeVisitorData = nil
        hasMoreHome = true
        errorMessage = nil
        await loadHome()
    }

    /// Loads the next Home continuation. This is safe to call repeatedly from a
    /// tvOS scroll sentinel because concurrent/re-entrant requests are ignored.
    func loadMoreHome() async {
        guard !isLoadingMoreHome, hasMoreHome, homeContinuationToken != nil else {
            if homeContinuationToken == nil { hasMoreHome = false }
            return
        }
        isLoadingMoreHome = true
        defer { isLoadingMoreHome = false }
        await fetchMoreHome()
    }

    private func fetchMoreHome() async {
        guard hasMoreHome, let token = homeContinuationToken else {
            hasMoreHome = false
            return
        }
        do {
            let continuation: HomeScreenResponse.Continuation
            if let homeVisitorData {
                continuation = try await HomeScreenResponse.Continuation.sendThrowingRequest(
                    youtubeModel: youtube,
                    data: [.continuation: token, .visitorData: homeVisitorData]
                )
            } else {
                continuation = try await HomeScreenResponse.Continuation.sendThrowingRequest(
                    youtubeModel: youtube,
                    data: [.continuation: token]
                )
            }
            appendHomeVideos(continuation.results.map(makeVideo(from:)))
            homeContinuationToken = continuation.continuationToken
            hasMoreHome = continuation.continuationToken != nil
        } catch {
            // Keep the already loaded feed usable. The next scroll sentinel can
            // retry instead of replacing a good feed with an error screen.
        }
    }

    func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = TVCatalogError.emptyQuery.localizedDescription
            return
        }
        isShowingSearchResults = true
        libraryStore?.recordSearch(trimmed)
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
            collections = response.results.compactMap { result in
                if let channel = result as? YTChannel {
                    return TVCollection(id: channel.channelId, title: channel.name ?? "Channel", subtitle: "Channel", thumbnailURL: channel.thumbnails.last?.url, kind: .channel)
                }
                if let playlist = result as? YTPlaylist {
                    return TVCollection(id: playlist.playlistId, title: playlist.title ?? "Playlist", subtitle: "Playlist", thumbnailURL: playlist.thumbnails.last?.url, kind: .playlist)
                }
                return nil
            }
            if videos.isEmpty { errorMessage = "No videos found." }
        } catch {
            errorMessage = TVCatalogError.requestFailed.localizedDescription
        }
    }

    func loadCollection(_ collection: TVCollection) async throws -> [TVVideo] {
        switch collection.kind {
        case .playlist:
            var response = try await PlaylistInfosResponse.sendThrowingRequest(
                youtubeModel: youtube,
                data: [.browseId: collection.id]
            )
            while response.results.count < 200, response.continuationToken != nil {
                let continuation = try await response.fetchContinuationThrowing(youtubeModel: youtube)
                response.mergeWithContinuation(continuation)
            }
            return response.results.map(makeVideo(from:))
        case .channel:
            let response = try await ChannelInfosResponse.sendThrowingRequest(
                youtubeModel: youtube,
                data: [.browseId: collection.id]
            )
            guard let videos = response.currentContent as? ChannelInfosResponse.Videos else { return [] }
            return videos.items.compactMap { result in
                guard let video = result as? YTVideo else { return nil }
                return makeVideo(from: video)
            }
        }
    }

    weak var libraryStore: TVLibraryStore?

    func resetToHome() {
        query = ""
        videos = []
        collections = []
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
        for query in regionProfile.discoveryQueries {
            do {
                let response = try await SearchResponse.sendThrowingRequest(
                    youtubeModel: youtube,
                    data: [.query: query]
                )
                let results: [TVVideo] = response.results.compactMap { result in
                    guard let video = result as? YTVideo else { return nil }
                    return makeVideo(from: video)
                }
                appendHomeVideos(results)
                var continuation = response
                while homeVideos.count < Self.minimumHomeVideos, continuation.continuationToken != nil {
                    let next = try await continuation.fetchContinuationThrowing(youtubeModel: youtube)
                    appendHomeVideos(next.results.compactMap { result in
                        guard let video = result as? YTVideo else { return nil }
                        return makeVideo(from: video)
                    })
                    continuation.continuationToken = next.continuationToken
                }
                if !homeVideos.isEmpty {
                    homeContinuationToken = continuation.continuationToken
                    homeVisitorData = continuation.visitorData
                    hasMoreHome = homeContinuationToken != nil
                    return
                }
            } catch {
                // Anonymous YouTube responses can reject one discovery query while
                // still accepting another. Continue through the fallback list.
            }
        }
        throw TVCatalogError.requestFailed
    }

    private static let minimumHomeVideos = 18
    private var homeContinuationToken: String?
    private var homeVisitorData: String?

    private func appendHomeVideos(_ videos: [TVVideo]) {
        var existingIDs = Set(homeVideos.map(\.id))
        for video in videos where existingIDs.insert(video.id).inserted {
            homeVideos.append(video)
        }
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

enum PairingStatus: Sendable { case pending, paired, failed }

private struct PairingResponse: Decodable {
    let code: String
    let expiresAt: Double
}

private struct PairingStatusResponse: Decodable {
    let status: String
}

private struct AccountResponse: Decodable {
    let signedIn: Bool
    let title: String?
    let channelID: String?
    let thumbnailURL: URL?
}

private struct SubscriptionsResponse: Decodable {
    let videos: [SubscriptionVideo]
}

private struct SubscriptionVideo: Decodable {
    let id: String
    let title: String
    let channel: String
    let thumbnailURL: URL?
}

private typealias VideoListResponse = SubscriptionsResponse

private struct PlaylistListResponse: Decodable {
    let playlists: [CloudPlaylist]
}

private struct CloudPlaylist: Decodable {
    let id: String
    let title: String
    let count: Int
    let thumbnailURL: URL?
}

private struct SyncedHistoryResponse: Decodable {
    let videos: [TVVideo]
}
