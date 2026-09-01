import AVKit
import SwiftUI

struct TVVideoDetailView: View {
    @Environment(TVCatalogModel.self) private var model
    let video: TVVideo
    @State private var player: AVPlayer?
    @State private var playerItem: AVPlayerItem?
    @State private var hlsLoader: TVHLSResourceLoader?
    @State private var message: String?

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
            player?.pause()
            player = nil
            playerItem = nil
            hlsLoader = nil
        }
        .onChange(of: playerItem?.status) { _, status in
            guard status == .failed else { return }
            message = playerItem?.error?.localizedDescription ?? "The video stream could not be decoded."
        }
    }
}
