import AVKit
import SwiftUI

struct TVVideoDetailView: View {
    @Environment(TVCatalogModel.self) private var model
    let video: TVVideo
    @State private var player: AVPlayer?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(video.title).font(.title.bold()).lineLimit(3)
            Text(video.channel).foregroundStyle(.secondary)
            if let player {
                VideoPlayer(player: player)
                    .frame(maxWidth: .infinity, minHeight: 520)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            } else if let message {
                ContentUnavailableView("Playback unavailable", systemImage: "play.slash", description: Text(message))
            } else {
                ProgressView("Preparing playback…")
            }
            Spacer()
        }
        .padding(60)
        .task {
            do {
                player = AVPlayer(url: try await model.streamURL(for: video))
                player?.play()
            } catch {
                message = error.localizedDescription
            }
        }
        .onDisappear { player?.pause() }
    }
}
