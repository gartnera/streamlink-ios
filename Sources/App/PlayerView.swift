import SwiftUI
import AVKit
import UIKit

/// Hosts the shared `AVPlayer` in an `AVPlayerViewController`.
///
/// Background behavior:
///   • Video → Picture in Picture. PiP is allowed and starts automatically when
///     the app is backgrounded while a video is playing, so video keeps going.
///   • Audio → if PiP isn't taking over (e.g. audio-only stream, or PiP declined),
///     the player is detached from the controller on backgrounding so AVKit does
///     not pause it — audio then continues via the `.playback` AVAudioSession.
struct PlayerView: UIViewControllerRepresentable {
    @ObservedObject var model: PlayerModel

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = model.player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.delegate = context.coordinator

        context.coordinator.controller = controller
        context.coordinator.model = model
        context.coordinator.observeAppLifecycle()

        model.player.play()
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        // The player is shared via `model`; nothing to reconfigure per update.
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        weak var controller: AVPlayerViewController?
        var model: PlayerModel?
        private var pipActive = false

        func observeAppLifecycle() {
            let nc = NotificationCenter.default
            nc.addObserver(self, selector: #selector(didEnterBackground),
                           name: UIApplication.didEnterBackgroundNotification, object: nil)
            nc.addObserver(self, selector: #selector(willEnterForeground),
                           name: UIApplication.willEnterForegroundNotification, object: nil)
        }

        deinit { NotificationCenter.default.removeObserver(self) }

        @objc private func didEnterBackground() {
            // Give PiP a moment to claim the session; if it doesn't, detach the
            // player so AVKit keeps audio playing instead of pausing on hide.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, !self.pipActive else { return }
                self.controller?.player = nil
            }
        }

        @objc private func willEnterForeground() {
            guard !pipActive, controller?.player == nil else { return }
            controller?.player = model?.player
        }

        // MARK: AVPlayerViewControllerDelegate (PiP lifecycle)

        func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
            pipActive = true
        }

        func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
            pipActive = false
        }

        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
        ) {
            completionHandler(true)
        }
    }
}
