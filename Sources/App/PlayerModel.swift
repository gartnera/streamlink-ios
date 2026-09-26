import AVKit
import Combine

/// Owns the single `AVPlayer` for the whole app. Loading a new stream always
/// replaces the current item, so only one stream is ever playing.
///
/// Resilience:
///   • Resuming a paused live stream seeks to the live edge (so you don't play
///     from behind live, or stall on a position that fell out of the window).
///   • Playback failures / stalls / drops trigger an automatic re-resolve with
///     exponential backoff; after a cap it surfaces a retryable failed state.
final class PlayerModel: ObservableObject {
    let player = AVPlayer()

    /// True once a stream has been loaded, so the UI knows to show the player.
    @Published private(set) var hasStream = false

    /// True when the current stream has no video (audio-only quality).
    @Published private(set) var isAudioOnly = false

    /// True while we're auto-reconnecting after a drop/failure.
    @Published private(set) var isReconnecting = false

    /// True once reconnection attempts are exhausted; the UI offers a Retry.
    @Published private(set) var playbackFailed = false

    /// Mirrors whether AVKit's on-video controls are showing, so our own overlay
    /// (the quality dropdown) can appear and hide with them. Set by `PlayerView`.
    @Published var controlsVisible = false

    /// Re-resolve the current stream fresh (new live-edge URL) and call `load`.
    var onReloadRequested: (() -> Void)?

    private var currentURL: String?
    private var rebuilding = false           // guards our own item swaps
    private var pausedByUser = false         // distinguishes user pause from stalls
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 6
    private var reconnectWork: DispatchWorkItem?
    private var stallWork: DispatchWorkItem?

    private var rateObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var itemTokens: [NSObjectProtocol] = []

    private lazy var nowPlaying = NowPlayingCenter(player: player)

    init() {
        player.allowsExternalPlayback = true
        rateObservation = player.observe(\.rate, options: [.new]) { [weak self] _, _ in
            self?.handleRateChange()
        }
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            self?.handleTimeControlChange()
        }
    }

    deinit {
        rateObservation?.invalidate()
        timeControlObservation?.invalidate()
        clearItemObservers()
    }

    /// Load (or switch to) a stream. A no-op if it's already the current URL,
    /// otherwise the existing item is replaced so the old stream stops cleanly.
    func load(_ stream: SelectedStream, title: String, subtitle: String, audioOnly: Bool = false) {
        guard currentURL != stream.url, let url = URL(string: stream.url) else { return }
        rebuilding = true
        defer { rebuilding = false }
        currentURL = stream.url
        isAudioOnly = audioOnly
        pausedByUser = false
        playbackFailed = false

        var options: [String: Any] = [:]
        if !stream.headers.isEmpty {
            options["AVURLAssetHTTPHeaderFieldsKey"] = stream.headers
        }
        let asset = AVURLAsset(url: url, options: options)
        let item = AVPlayerItem(asset: asset)
        observe(item)
        player.replaceCurrentItem(with: item)
        player.play()
        nowPlaying.update(title: title, subtitle: subtitle)
        if !hasStream { hasStream = true }
    }

    /// Stop playback and tear down the current item (dismisses the player UI).
    func stop() {
        rebuilding = true
        defer { rebuilding = false }
        cancelReconnect()
        clearItemObservers()
        player.pause()
        player.replaceCurrentItem(with: nil)
        nowPlaying.clear()
        currentURL = nil
        isAudioOnly = false
        isReconnecting = false
        playbackFailed = false
        hasStream = false
    }

    /// Manual retry after reconnection gave up.
    func retry() {
        reconnectAttempts = 0
        playbackFailed = false
        attemptReconnect()
    }

    // MARK: - Live edge / resume

    private var isLive: Bool {
        guard let duration = player.currentItem?.duration else { return false }
        let seconds = duration.seconds
        return !(seconds.isFinite && seconds > 0)   // indefinite duration ⇒ live
    }

    private func handleRateChange() {
        guard !rebuilding else { return }
        if player.rate > 0 {
            // Resuming after a user pause: jump back to the live edge.
            if pausedByUser {
                pausedByUser = false
                if isLive { seekToLive() }
            }
        } else if player.currentItem != nil {
            pausedByUser = true
        }
    }

    private func seekToLive() {
        guard let item = player.currentItem,
              let end = item.seekableTimeRanges.last?.timeRangeValue.end,
              end.isValid else { return }
        player.seek(to: end, toleranceBefore: .zero, toleranceAfter: .positiveInfinity) { [weak self] _ in
            self?.player.play()
        }
    }

    // MARK: - Failure detection

    private func observe(_ item: AVPlayerItem) {
        clearItemObservers()
        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            if item.status == .failed { self?.attemptReconnect() }
        }
        let nc = NotificationCenter.default
        itemTokens = [
            nc.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                self?.attemptReconnect()
            },
            nc.addObserver(forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main) { [weak self] _ in
                self?.handleStall()
            },
            nc.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                // A live stream shouldn't "end" — treat it as a drop and reconnect.
                guard let self else { return }
                if isLive { attemptReconnect() } else { stop() }
            },
        ]
    }

    private func clearItemObservers() {
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        itemTokens.forEach { NotificationCenter.default.removeObserver($0) }
        itemTokens.removeAll()
    }

    private func handleTimeControlChange() {
        if player.timeControlStatus == .playing {
            // Playback recovered — clear any reconnect state.
            stallWork?.cancel(); stallWork = nil
            if isReconnecting || reconnectAttempts > 0 {
                reconnectWork?.cancel(); reconnectWork = nil
                isReconnecting = false
                reconnectAttempts = 0
            }
        }
    }

    private func handleStall() {
        // AVPlayer often self-recovers from a stall; only re-resolve if it's still
        // stuck after a grace period.
        guard !rebuilding, stallWork == nil, !isReconnecting else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            stallWork = nil
            if player.timeControlStatus != .playing { attemptReconnect() }
        }
        stallWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }

    // MARK: - Reconnect

    private func attemptReconnect() {
        guard hasStream, !rebuilding else { return }
        reconnectWork?.cancel()
        guard reconnectAttempts < maxReconnectAttempts else {
            isReconnecting = false
            playbackFailed = true
            return
        }
        let delay = min(30, pow(2, Double(reconnectAttempts)))   // 1,2,4,8,16,30
        reconnectAttempts += 1
        isReconnecting = true
        playbackFailed = false

        let work = DispatchWorkItem { [weak self] in
            guard let self, isReconnecting else { return }
            currentURL = nil                 // force a fresh load even if URL is unchanged
            onReloadRequested?()
            // Watchdog: if it hasn't recovered, try again (covers re-resolve failures).
            let watchdog = DispatchWorkItem { [weak self] in
                guard let self, isReconnecting, player.timeControlStatus != .playing else { return }
                attemptReconnect()
            }
            reconnectWork = watchdog
            DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: watchdog)
        }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelReconnect() {
        reconnectWork?.cancel(); reconnectWork = nil
        stallWork?.cancel(); stallWork = nil
        reconnectAttempts = 0
    }
}
