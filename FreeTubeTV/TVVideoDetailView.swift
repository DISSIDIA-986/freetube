import AVKit
import SwiftUI

struct TVVideoDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(TVCatalogModel.self) private var model
    @Environment(TVLibraryStore.self) private var library
    let video: TVVideo
    @State private var player: AVPlayer?
    @State private var playerItem: AVPlayerItem?
    @State private var hlsLoader: TVHLSResourceLoader?
    @State private var message: String?
    @State private var playbackMonitor: Task<Void, Never>?
    @State private var progressTask: Task<Void, Never>?
    @State private var localPlaybackURL: URL?
    @State private var selectedResolution = 480
    @State private var channelCollection: TVCollection?
    @State private var channelVideo: TVVideo?
    @State private var isLookingUpChannel = false
    @State private var channelLookupFailed = false
    @State private var isMuted = false
    @State private var captionsEnabled = false
    @State private var isPlaying = true
    @FocusState private var focusedControl: PlayerControl?

    private let resolutionOptions = [360, 480, 720, 1080, 1440, 2160]

    private enum PlayerControl: Hashable {
        case resolution, captions, mute, channel
    }

    var body: some View {
        ZStack {
            if let player {
                TVPlayerSurface(player: player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
            } else if let message {
                ContentUnavailableView("Playback unavailable", systemImage: "play.slash", description: Text(message))
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

                if player != nil {
                    HStack(spacing: 10) {
                        Menu {
                            ForEach(resolutionOptions, id: \.self) { resolution in
                                Button("\(resolution)p") { selectedResolution = resolution }
                            }
                        } label: {
                            Label("\(selectedResolution)p", systemImage: "4k.tv")
                        }
                        .focused($focusedControl, equals: .resolution)

                        Button {
                            captionsEnabled.toggle()
                            applyCaptionsSelection()
                        } label: {
                            Label(captionsEnabled ? "CC On" : "CC Off", systemImage: captionsEnabled ? "captions.bubble.fill" : "captions.bubble")
                        }
                        .focused($focusedControl, equals: .captions)

                        Button {
                            isMuted.toggle()
                            player?.isMuted = isMuted
                        } label: {
                            Label(isMuted ? "Muted" : "Sound", systemImage: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        }
                        .focused($focusedControl, equals: .mute)

                        Button {
                            isLookingUpChannel = true
                            channelLookupFailed = false
                            Task {
                                channelCollection = await model.channelCollection(for: video)
                                channelLookupFailed = channelCollection == nil
                                isLookingUpChannel = false
                            }
                        } label: {
                            Label(isLookingUpChannel ? "Finding…" : "Channel", systemImage: "person.2")
                        }
                        .focused($focusedControl, equals: .channel)
                        .disabled(isLookingUpChannel || channelLookupFailed)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .focusSection()
                    // AVKit owns Audio Adjustments and Subtitles in its transport bar.
                    // Keep our two additions compact and visually aligned with that bar.
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .padding(.bottom, 78)
                    .padding(.trailing, 48)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .zIndex(10)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .onPlayPauseCommand {
            isPlaying.toggle()
            if isPlaying { player?.play() } else { player?.pause() }
        }
        .sheet(item: $channelCollection) { collection in
            TVCollectionView(collection: collection) { selected in
                channelCollection = nil
                channelVideo = selected
            }
        }
        .fullScreenCover(item: $channelVideo) { selected in
            TVVideoDetailView(video: selected)
        }
        .task(id: selectedResolution) {
            player?.pause()
            player = nil
            playerItem = nil
            message = nil
            isPlaying = true
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
            } catch {
                message = diagnosticDescription(for: error)
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
                        return
                    }
                    if player.status == .failed {
                        message = player.error?.localizedDescription ?? "The player failed to load this stream."
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(500))
                }

                // A ready item that never advances is indistinguishable from a black
                // surface to the user. Surface the underlying AVFoundation diagnostics.
                if item.status != .readyToPlay || player.timeControlStatus != .playing {
                    message = playbackError(for: item)
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

    private func applyCaptionsSelection() {
        guard let item = playerItem,
              let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .legible) else { return }
        item.select(captionsEnabled ? (group.defaultOption ?? group.options.first) : nil, in: group)
    }

    private func diagnosticDescription(for error: Error) -> String {
        let nsError = error as NSError
        return "\(error.localizedDescription) [\(nsError.domain):\(nsError.code)]"
    }

    private func isGatewayURL(_ url: URL) -> Bool {
        guard let gatewayHost = model.gatewayBaseURL?.host,
              let sourceHost = url.host else { return false }
        return sourceHost.caseInsensitiveCompare(gatewayHost) == .orderedSame
    }
}
