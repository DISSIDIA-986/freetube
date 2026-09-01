import AVKit
import SwiftUI

struct TVPlayerSurface: UIViewControllerRepresentable {
    let player: AVPlayer
    let selectedResolution: Int
    let onResolutionSelected: (Int) -> Void
    let onChannelSelected: () -> Void

    private let resolutionOptions = [360, 480, 720, 1080, 1440, 2160]

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        controller.allowsPictureInPicturePlayback = true
        updateTransportBar(controller)
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player {
            controller.player = player
        }
        updateTransportBar(controller)
    }

    private func updateTransportBar(_ controller: AVPlayerViewController) {
        let resolutionMenu = UIMenu(
            title: "Resolution",
            image: UIImage(systemName: "4k.tv"),
            children: resolutionOptions.map { resolution in
                UIAction(
                    title: "\(resolution)p",
                    state: resolution == selectedResolution ? .on : .off
                ) { _ in
                    onResolutionSelected(resolution)
                }
            }
        )
        let channelAction = UIAction(
            title: "View Channel",
            image: UIImage(systemName: "person.2")
        ) { _ in
            onChannelSelected()
        }
        controller.transportBarCustomMenuItems = [resolutionMenu, channelAction]
    }
}
