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
        // NowPlayingCenter owns the lock screen / Control Center info (with
        // channel artwork); don't let AVKit overwrite it with its own.
        controller.updatesNowPlayingInfoCenter = false
        controller.delegate = context.coordinator

        context.coordinator.controller = controller
        context.coordinator.model = model
        context.coordinator.observeAppLifecycle()
        context.coordinator.trackControlsVisibility()

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
            nc.addObserver(self, selector: #selector(willLock),
                           name: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil)
        }

        /// The device is locking (only posted with a passcode set), which arrives
        /// just before backgrounding. PiP never starts on lock, so detach now —
        /// before AVKit pauses the still-attached player.
        @objc private func willLock() {
            guard !pipActive, controller?.player != nil else { return }
            controller?.player = nil
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
            controlsTimer?.invalidate()
        }

        // MARK: Controls visibility

        private var controlsTimer: Timer?
        private weak var controlsView: UIView?
        /// Failed lookups since the last hit; we stop walking the tree after ~5s.
        private var controlsLookupMisses = 0
        private let maxControlsLookupMisses = 50

        /// AVKit has no public API for whether its inline controls are showing,
        /// so poll its controls container (e.g. `AVMobileGlassControlsView` on
        /// iOS 26), which is hidden whenever the controls fade out. If it can't
        /// be found, report the controls as visible so our overlay stays usable.
        /// Paused while the app is in the background.
        func trackControlsVisibility() {
            controlsTimer?.invalidate()
            controlsLookupMisses = 0
            controlsTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self, let root = self.controller?.view else { return }
                if self.controlsView?.isDescendant(of: root) != true,
                   self.controlsLookupMisses < self.maxControlsLookupMisses {
                    self.controlsView = Self.findControlsView(in: root)
                    self.controlsLookupMisses = self.controlsView == nil ? self.controlsLookupMisses + 1 : 0
                }
                let visible = self.controlsView.map { !$0.isHidden && $0.alpha > 0.01 } ?? true
                if self.model?.controlsVisible != visible { self.model?.controlsVisible = visible }
            }
        }

        /// Breadth-first, so the top-level container wins over nested *ControlsViews.
        private static func findControlsView(in root: UIView) -> UIView? {
            var queue = root.subviews
            while !queue.isEmpty {
                let view = queue.removeFirst()
                let name = String(describing: type(of: view))
                if name.hasPrefix("AV"), name.hasSuffix("ControlsView") { return view }
                queue.append(contentsOf: view.subviews)
            }
            return nil
        }

        @objc private func didEnterBackground() {
            controlsTimer?.invalidate()
            controlsTimer = nil
            // If the player is still attached when locking (no passcode, so no
            // willLock), AVKit pauses it right away; remember whether it was
            // playing to resume after detaching.
            let wasPlaying = (model?.player.rate ?? 0) > 0
            // Give PiP a moment to claim the session; if it doesn't, detach the
            // player so AVKit keeps audio playing instead of pausing on hide.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                // Skip if PiP took over, or the user already came back.
                guard let self, !self.pipActive,
                      UIApplication.shared.applicationState == .background else { return }
                self.controller?.player = nil
                if wasPlaying { self.model?.resumeAfterSystemPause() }
                // No video visible: adaptive streams drop to audio-only.
                self.model?.setBackgroundAudioOnly(true)
            }
        }

        @objc private func willEnterForeground() {
            trackControlsVisibility()
            model?.setBackgroundAudioOnly(false)
            guard !pipActive, controller?.player == nil else { return }
            controller?.player = model?.player
        }

        // MARK: AVPlayerViewControllerDelegate (PiP lifecycle)

        func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
            pipActive = true
        }

        func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
            pipEnded()
        }

        /// E.g. when the stream switched to audio-only while PiP was starting.
        func playerViewController(_ playerViewController: AVPlayerViewController,
                                  failedToStartPictureInPictureWithError error: Error) {
            pipEnded()
        }

        private func pipEnded() {
            pipActive = false
            // Switching to audio-only in the background (e.g. "Audio-only in
            // background") ends PiP, which leaves the player attached, and AVKit
            // then pauses it. Detach and keep the audio going, as when PiP never
            // started. (Closing PiP on a video stream still pauses, as usual.)
            guard UIApplication.shared.applicationState == .background,
                  model?.isAudioOnly == true, controller?.player != nil else { return }
            controller?.player = nil
            model?.resumeAfterSystemPause()
            model?.setBackgroundAudioOnly(true)
        }

        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
        ) {
            completionHandler(true)
        }
    }
}
