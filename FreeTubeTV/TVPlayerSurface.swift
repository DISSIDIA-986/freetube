import AVKit
import SwiftUI

/// UIKit container for the native tvOS player. Keeping AVPlayerViewController in
/// a real parent controller gives tvOS a stable focus environment and dismissal
/// lifecycle, matching the proven Bilibili/StreamBox architecture.
struct TVPlayerSurface: UIViewControllerRepresentable {
    let player: AVPlayer
    let selectedResolution: Int
    let onResolutionSelected: (Int) -> Void
    let onChannelSelected: () -> Void
    let onYouTubeSelected: () -> Void

    func makeUIViewController(context: Context) -> TVNativePlayerViewController {
        let controller = TVNativePlayerViewController()
        controller.update(player: player, selectedResolution: selectedResolution, onResolutionSelected: onResolutionSelected, onChannelSelected: onChannelSelected, onYouTubeSelected: onYouTubeSelected)
        return controller
    }

    func updateUIViewController(_ controller: TVNativePlayerViewController, context: Context) {
        controller.update(player: player, selectedResolution: selectedResolution, onResolutionSelected: onResolutionSelected, onChannelSelected: onChannelSelected, onYouTubeSelected: onYouTubeSelected)
    }
}

@MainActor
final class TVNativePlayerViewController: UIViewController, AVPlayerViewControllerDelegate {
    private let playerViewController = AVPlayerViewController()
    private let resolutionOptions = [360, 480, 720, 1080, 1440, 2160]
    private var pendingPlayer: AVPlayer?
    private var selectedResolution = 480
    private var onResolutionSelected: ((Int) -> Void)?
    private var onChannelSelected: (() -> Void)?
    private var onYouTubeSelected: (() -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(playerViewController)
        view.addSubview(playerViewController.view)
        playerViewController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            playerViewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            playerViewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            playerViewController.view.topAnchor.constraint(equalTo: view.topAnchor),
            playerViewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        playerViewController.didMove(toParent: self)
        playerViewController.showsPlaybackControls = true
        playerViewController.allowsPictureInPicturePlayback = true
        playerViewController.delegate = self
        playerViewController.player = pendingPlayer
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        [playerViewController.view]
    }

    func update(player: AVPlayer, selectedResolution: Int, onResolutionSelected: @escaping (Int) -> Void, onChannelSelected: @escaping () -> Void, onYouTubeSelected: @escaping () -> Void) {
        pendingPlayer = player
        if isViewLoaded, playerViewController.player !== player {
            playerViewController.player = player
        }
        self.selectedResolution = selectedResolution
        self.onResolutionSelected = onResolutionSelected
        self.onChannelSelected = onChannelSelected
        self.onYouTubeSelected = onYouTubeSelected
        updateTransportBar()
    }

    func playerViewControllerShouldDismiss(_ playerViewController: AVPlayerViewController) -> Bool {
        // SwiftUI owns the presentation. Do not dismiss only the child controller.
        false
    }

    private func updateTransportBar() {
        guard isViewLoaded else { return }
        let resolutionMenu = UIMenu(
            title: "Resolution",
            image: UIImage(systemName: "4k.tv"),
            children: resolutionOptions.map { resolution in
                UIAction(title: "\(resolution)p", state: resolution == selectedResolution ? .on : .off) { [weak self] _ in
                    self?.onResolutionSelected?(resolution)
                }
            }
        )
        let channelAction = UIAction(title: "View Channel", image: UIImage(systemName: "person.2")) { [weak self] _ in
            self?.onChannelSelected?()
        }
        let youtubeAction = UIAction(title: "Open in YouTube", image: UIImage(systemName: "arrow.up.right.square")) { [weak self] _ in
            self?.onYouTubeSelected?()
        }
        playerViewController.transportBarCustomMenuItems = [resolutionMenu, channelAction, youtubeAction]
    }
}
