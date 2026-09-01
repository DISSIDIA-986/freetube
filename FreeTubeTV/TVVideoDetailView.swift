import AVKit
import SwiftUI

struct TVVideoDetailView: View {
    @Environment(TVCatalogModel.self) private var model
    let video: TVVideo
    @State private var player: AVPlayer?
    @State private var playerItem: AVPlayerItem?
    @State private var hlsLoader: TVHLSResourceLoader?
    @State private var message: String?
    @State private var playbackMonitor: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(video.title).font(.title.bold()).lineLimit(3)
            Text(video.channel).foregroundStyle(.secondary)
            if let message {
                ContentUnavailableView("Playback unavailable", systemImage: "play.slash", description: Text(message))
            } else if let player {
                TVPlayerSurface(player: player)
                    .frame(maxWidth: .infinity, minHeight: 520)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            } else {
                ProgressView("Preparing playback…")
            }
            Spacer()
        }
        .padding(60)
        .task {
            do {
                let url = try await model.streamURL(for: video)
                if url.pathExtension.lowercased() == "m3u8" || url.absoluteString.contains(".m3u8") {
                    let loader = TVHLSResourceLoader()
                    hlsLoader = loader
                    guard let rewrittenURL = TVHLSResourceLoader.rewrite(url) else {
                        throw TVCatalogError.noPlayableStream
                    }
                    let asset = AVURLAsset(url: rewrittenURL)
                    asset.resourceLoader.setDelegate(loader, queue: .main)
                    let item = AVPlayerItem(asset: asset)
                    playerItem = item
                    player = AVPlayer(playerItem: item)
                } else {
                    let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": [
                        "User-Agent": "Mozilla/5.0 (AppleTV; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15"
                    ]])
                    let item = AVPlayerItem(asset: asset)
                    playerItem = item
                    player = AVPlayer(playerItem: item)
                }
                player?.automaticallyWaitsToMinimizeStalling = false
                player?.play()
            } catch {
                message = error.localizedDescription
            }
        }
        .onDisappear {
            playbackMonitor?.cancel()
            player?.pause()
            player = nil
            playerItem = nil
            hlsLoader = nil
        }
        .task(id: playerItem) {
            guard let item = playerItem, let player else { return }
            playbackMonitor?.cancel()
            playbackMonitor = Task { @MainActor in
                for _ in 0..<30 {
                    guard !Task.isCancelled else { return }
                    if item.status == .failed {
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
}
