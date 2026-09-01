import AVKit
import SwiftUI

struct TVVideoDetailView: View {
    private static let resolutionDefaultsKey = "tv.freetube.playbackResolution"
    private static let defaultResolution = 480

    @Environment(\.dismiss) private var dismiss
    @Environment(TVCatalogModel.self) private var model
    @Environment(TVLibraryStore.self) private var library
    @Environment(TVPlaybackDiagnostics.self) private var diagnostics
    let video: TVVideo
    @State private var player: AVPlayer?
    @State private var playerItem: AVPlayerItem?
    @State private var hlsLoader: TVHLSResourceLoader?
    @State private var message: String?
    @State private var playbackMonitor: Task<Void, Never>?
    @State private var progressTask: Task<Void, Never>?
    @State private var localPlaybackURL: URL?
    @State private var selectedResolution: Int
    @State private var channelCollection: TVCollection?
    @State private var channelVideo: TVVideo?
    @State private var isLookingUpChannel = false
    @State private var channelLookupFailed = false
    @State private var playbackAttempt = 0
    @State private var hasRecordedRuntimeFailure = false
    @State private var didHandlePlaybackEnd = false
    let onFinished: (() -> Void)?

    init(video: TVVideo, onFinished: (() -> Void)? = nil) {
        self.video = video
        self.onFinished = onFinished
        let storedResolution = UserDefaults.standard.integer(forKey: Self.resolutionDefaultsKey)
        _selectedResolution = State(initialValue: storedResolution == 0 ? Self.defaultResolution : storedResolution)
    }

    var body: some View {
        ZStack {
            if let player {
                TVPlayerSurface(
                    player: player,
                    selectedResolution: selectedResolution,
                    onResolutionSelected: {
                        selectedResolution = $0
                        UserDefaults.standard.set($0, forKey: Self.resolutionDefaultsKey)
                    },
                    onChannelSelected: openChannel
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
            } else if let message {
                VStack(spacing: 24) {
                    ContentUnavailableView("Playback unavailable", systemImage: "play.slash", description: Text(message))
                    Button("Retry") { playbackAttempt += 1 }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                VStack(spacing: 20) {
                    ProgressView()
                    Text("Preparing (video.title)…")
                        .font(.title3)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                .padding(80)
            }

            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                    Spacer()
                }
                .padding(.top, 36)
                .padding(.leading, 48)
                Spacer()

            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .sheet(item: $channelCollection) { collection in
            TVCollectionView(collection: collection) { selected in
                channelCollection = nil
                channelVideo = selected
            }
        }
        .fullScreenCover(item: $channelVideo) { selected in
            TVVideoDetailView(video: selected)
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
            guard let finishedItem = notification.object as? AVPlayerItem,
                  finishedItem === playerItem,
                  !didHandlePlaybackEnd else { return }
            didHandlePlaybackEnd = true
            player?.pause()
            if let onFinished {
                onFinished()
            } else {
                dismiss()
            }
        }
        .task(id: "\(selectedResolution)-\(playbackAttempt)") {
            player?.pause()
            player = nil
            playerItem = nil
            message = nil
            hasRecordedRuntimeFailure = false
            didHandlePlaybackEnd = false
            do {
                let source = try await model.playbackSource(for: video, preferredHeight: selectedResolution)
                library.recordHistory(video)
                let url = source.videoURL
                if source.audioURL == nil && isGatewayURL(source.videoURL) {
                    let item = AVPlayerItem(url: source.videoURL)
                    playerItem = item
                    player = AVPlayer(playerItem: item)
                } else {
                // Route both HLS and progressive MP4 through the same loader. AVPlayer's
                // direct MP4 requests use its own User-Agent and are rejected by YouTube's
                // CDN with HTTP 403 even though the signed URL works with our URLSession.
                let loader = TVHLSResourceLoader()
                hlsLoader = loader
                guard let rewrittenURL = TVHLSResourceLoader.rewrite(url) else {
                    throw TVCatalogError.noPlayableStream
                }
                let videoAsset = AVURLAsset(url: rewrittenURL)
                videoAsset.resourceLoader.setDelegate(loader, queue: .main)
                let playbackAsset: AVAsset
                if let audioURL = source.audioURL,
                   let rewrittenAudioURL = TVHLSResourceLoader.rewrite(audioURL) {
                    let audioAsset = AVURLAsset(url: rewrittenAudioURL)
                    audioAsset.resourceLoader.setDelegate(loader, queue: .main)
                    let composition = AVMutableComposition()
                    let duration = try await videoAsset.load(.duration)
                    let audioDuration = try await audioAsset.load(.duration)
                    let range = CMTimeRange(start: .zero, duration: min(duration, audioDuration))
                    guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
                          let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first,
                          let compositionVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
                          let compositionAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                        throw TVCatalogError.noPlayableStream
                    }
                    try compositionVideo.insertTimeRange(range, of: videoTrack, at: .zero)
                    try compositionAudio.insertTimeRange(range, of: audioTrack, at: .zero)
                    // tvOS can inspect the remote tracks but AVPlayer may reject the remote
                    // composition itself with -11828. Materialize the muxed MP4 first, matching
                    // the original FreeTube download path and avoiding remote composition playback.
                    let outputURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent("freetube-\(video.id)-\(UUID().uuidString).mp4")
                    guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough),
                          exporter.supportedFileTypes.contains(.mp4) else {
                        throw TVCatalogError.noPlayableStream
                    }
                    exporter.outputURL = outputURL
                    exporter.outputFileType = .mp4
                    await exporter.export()
                    guard exporter.status == .completed else {
                        throw exporter.error ?? TVCatalogError.noPlayableStream
                    }
                    localPlaybackURL = outputURL
                    playbackAsset = AVURLAsset(url: outputURL)
                } else {
                    playbackAsset = videoAsset
                }
                let item = AVPlayerItem(asset: playbackAsset)
                playerItem = item
                player = AVPlayer(playerItem: item)
                }
                player?.automaticallyWaitsToMinimizeStalling = false
                if let seconds = library.progress(for: video), seconds > 5 {
                    await player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
                }
                player?.play()
                diagnostics.record(videoID: video.id, resolution: selectedResolution, succeeded: true)
            } catch is CancellationError {
                return
            } catch {
                message = diagnosticDescription(for: error)
                diagnostics.record(videoID: video.id, resolution: selectedResolution, succeeded: false, error: message)
            }
        }
        .onDisappear {
            playbackMonitor?.cancel()
            progressTask?.cancel()
            player?.pause()
            player = nil
            playerItem = nil
            hlsLoader = nil
            if let localPlaybackURL {
                try? FileManager.default.removeItem(at: localPlaybackURL)
            }
            localPlaybackURL = nil
        }
        .task(id: playerItem) {
            guard let item = playerItem, let player else { return }
            playbackMonitor?.cancel()
            playbackMonitor = Task { @MainActor in
                for _ in 0..<30 {
                    guard !Task.isCancelled else { return }
                    print("FreeTubeTV player: item=\(item.status.rawValue) player=\(player.status.rawValue) time=\(player.timeControlStatus.rawValue) error=\(String(describing: item.error))")
                    if item.status == .failed {
                        print("FreeTubeTV player error log: \(String(describing: item.errorLog()?.events.map { [$0.errorStatusCode, $0.errorDomain, $0.errorComment ?? ""] }))")
                        message = playbackError(for: item)
                        recordRuntimeFailure(message ?? "The stream could not be loaded.")
                        return
                    }
                    if player.status == .failed {
                        message = player.error?.localizedDescription ?? "The player failed to load this stream."
                        recordRuntimeFailure(message ?? "The player failed to load this stream.")
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(500))
                }

                // A ready item that never advances is indistinguishable from a black
                // surface to the user. Surface the underlying AVFoundation diagnostics.
                if item.status != .readyToPlay || player.timeControlStatus != .playing {
                    message = playbackError(for: item)
                    recordRuntimeFailure(message ?? "The stream did not become playable on Apple TV.")
                }
            }
            await playbackMonitor?.value
        }
        .task(id: playerItem) {
            guard let playerItem, let player else { return }
            progressTask?.cancel()
            progressTask = Task { @MainActor in
                while !Task.isCancelled {
                    let seconds = player.currentTime().seconds
                    if seconds.isFinite && seconds > 0 {
                        library.saveProgress(seconds, for: video)
                    }
                    try? await Task.sleep(for: .seconds(5))
                }
            }
            _ = playerItem
            await progressTask?.value
        }
    }

    private func playbackError(for item: AVPlayerItem) -> String {
        if let error = item.error?.localizedDescription {
            return error
        }
        if let event = item.errorLog()?.events.last {
            return "HTTP \(event.errorStatusCode): \(event.errorComment ?? "The stream could not be loaded.")"
        }
        return "The stream did not become playable on Apple TV."
    }

    private func openChannel() {
        guard !isLookingUpChannel, !channelLookupFailed else { return }
        isLookingUpChannel = true
        Task {
            channelCollection = await model.channelCollection(for: video)
            channelLookupFailed = channelCollection == nil
            isLookingUpChannel = false
        }
    }

    private func diagnosticDescription(for error: Error) -> String {
        let nsError = error as NSError
        return "\(error.localizedDescription) [\(nsError.domain):\(nsError.code)]"
    }

    private func recordRuntimeFailure(_ error: String) {
        guard !hasRecordedRuntimeFailure else { return }
        hasRecordedRuntimeFailure = true
        diagnostics.record(videoID: video.id, resolution: selectedResolution, succeeded: false, error: error)
    }

    private func isGatewayURL(_ url: URL) -> Bool {
        guard let gatewayHost = model.gatewayBaseURL?.host,
              let sourceHost = url.host else { return false }
        return sourceHost.caseInsensitiveCompare(gatewayHost) == .orderedSame
    }
}
