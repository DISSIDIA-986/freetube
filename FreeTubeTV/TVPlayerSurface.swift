import AVKit
import SwiftUI

struct TVPlayerSurface: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        // Use the SwiftUI transport bar above. AVPlayerViewController's native
        // bar otherwise captures Siri Remote focus and makes overlay actions
        // visible but unreachable.
        controller.showsPlaybackControls = false
        controller.allowsPictureInPicturePlayback = true
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player {
            controller.player = player
        }
    }
}
