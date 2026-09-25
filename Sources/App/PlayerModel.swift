import AVKit
import Combine

/// Owns the single `AVPlayer` for the whole app. Loading a new stream always
/// replaces the current item, so only one stream is ever playing.
///
/// Live streams are torn down on pause (so Streamlink/AVPlayer stop buffering in
/// the background) and re-resolved fresh at the live edge on resume — pausing a
/// live stream otherwise keeps the connection open and drifts behind live.
final class PlayerModel: ObservableObject {
    let player = AVPlayer()

    /// True once a stream has been loaded, so the UI knows to show the player.
    @Published private(set) var hasStream = false

    /// True when the current stream has no video (audio-only quality), so the UI
    /// can show artwork instead of a black frame.
    @Published private(set) var isAudioOnly = false

    /// Invoked when the user resumes a torn-down live stream; the controller
    /// re-resolves the current stream and calls `load` again.
    var onResumeRequested: (() -> Void)?

    private var currentURL: String?
    private var suspended = false     // torn down because the user paused a live stream
    private var rebuilding = false    // guards our own item swaps from the rate observer
    private var rateObservation: NSKeyValueObservation?
    private lazy var nowPlaying = NowPlayingCenter(player: player)

    init() {
        // Keep AirPlay / external playback available; audio routing is handled
        // by the AVAudioSession configured at launch.
        player.allowsExternalPlayback = true
        rateObservation = player.observe(\.rate, options: [.new]) { [weak self] _, _ in
            self?.handleRateChange()
        }
    }

    deinit { rateObservation?.invalidate() }

    /// Load (or switch to) a stream. A no-op if it's already the current URL,
    /// otherwise the existing item is replaced so the old stream stops cleanly.
    /// `title`/`subtitle` populate Control Center / lock-screen Now Playing info.
    func load(_ stream: SelectedStream, title: String, subtitle: String, audioOnly: Bool = false) {
        guard currentURL != stream.url, let url = URL(string: stream.url) else { return }
        rebuilding = true
        defer { rebuilding = false }
        currentURL = stream.url
        suspended = false
        isAudioOnly = audioOnly

        var options: [String: Any] = [:]
        if !stream.headers.isEmpty {
            options["AVURLAssetHTTPHeaderFieldsKey"] = stream.headers
        }
        let asset = AVURLAsset(url: url, options: options)
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        player.play()
        nowPlaying.update(title: title, subtitle: subtitle)
        if !hasStream { hasStream = true }
    }

    /// Stop playback and tear down the current item (dismisses the player UI).
    func stop() {
        rebuilding = true
        defer { rebuilding = false }
        player.pause()
        player.replaceCurrentItem(with: nil)
        nowPlaying.clear()
        currentURL = nil
        suspended = false
        hasStream = false
    }

    // MARK: - Pause teardown / resume

    private var isLive: Bool {
        guard let duration = player.currentItem?.duration else { return false }
        let seconds = duration.seconds
        return !(seconds.isFinite && seconds > 0)   // indefinite duration ⇒ live
    }

    private func handleRateChange() {
        guard !rebuilding else { return }
        if player.rate > 0 {
            // The user pressed play after we tore the stream down: re-resolve it.
            if suspended {
                suspended = false
                onResumeRequested?()
            }
        } else {
            // The user paused: tear the live stream down so it stops buffering.
            if !suspended, player.currentItem != nil, isLive {
                scheduleTeardown()
            }
        }
    }

    private func scheduleTeardown() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, player.rate == 0, !suspended, player.currentItem != nil else { return }
            rebuilding = true
            player.replaceCurrentItem(with: nil)
            currentURL = nil
            suspended = true
            rebuilding = false
        }
    }
}
