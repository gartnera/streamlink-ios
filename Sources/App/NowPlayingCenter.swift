import AVFoundation
import MediaPlayer

/// Publishes Now Playing metadata (title/subtitle, artwork, live state, elapsed time) to
/// Control Center and the lock screen, and wires the remote play/pause/stop
/// commands back to the shared `AVPlayer` — so background playback shows info
/// and is controllable from outside the app.
final class NowPlayingCenter {
    private let player: AVPlayer
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var title = ""
    private var subtitle = ""
    private var artwork: MPMediaItemArtwork?

    init(player: AVPlayer) {
        self.player = player
        setupCommands()

        statusObservation = player.observe(\.timeControlStatus) { [weak self] _, _ in
            self?.refresh()
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 1), queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        statusObservation?.invalidate()
    }

    func update(title: String, subtitle: String, artwork image: UIImage? = nil) {
        self.title = title
        self.subtitle = subtitle
        artwork = image.map { image in
            MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        refresh()
    }

    func clear() {
        title = ""
        subtitle = ""
        artwork = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func setupCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            self?.player.play(); return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.player.pause(); return .success
        }
        center.stopCommand.addTarget { [weak self] _ in
            self?.player.pause(); return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            if player.timeControlStatus == .playing { player.pause() } else { player.play() }
            return .success
        }
        // Live streams can't seek; leave the scrubbing commands disabled.
        center.changePlaybackPositionCommand.isEnabled = false
    }

    private func refresh() {
        guard !title.isEmpty else { return }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyTitle] = title
        info[MPMediaItemPropertyArtist] = subtitle
        info[MPMediaItemPropertyArtwork] = artwork

        let duration = player.currentItem?.duration.seconds ?? .nan
        let isLive = !(duration.isFinite && duration > 0)
        info[MPNowPlayingInfoPropertyIsLiveStream] = isLive
        if !isLive { info[MPMediaItemPropertyPlaybackDuration] = duration }

        let elapsed = player.currentTime().seconds
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed.isFinite ? elapsed : 0
        info[MPNowPlayingInfoPropertyPlaybackRate] = player.rate

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
