import SwiftUI
import Foundation
import Combine
import UIKit

/// A user-saved stream URL, persisted across launches.
struct SavedStream: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var url: String
}

/// Owns stream resolution + playback state and the saved-streams list, shared
/// between the main player screen and the stream-selection page.
@MainActor
final class StreamController: ObservableObject {
    let player = PlayerModel()

    @Published var urlText: String = ""
    /// Available qualities: `best`, `audio_only`, then concrete qualities best → worst.
    @Published var qualities: [String] = []
    /// Alias → concrete quality for the current stream, e.g. "best" → "1080p60".
    @Published var aliasTargets: [String: String] = [:]
    @Published var selectedQuality: String = "best"
    @Published var pluginName: String?
    @Published var status: String = ""
    @Published var busy = false
    @Published private(set) var saved: [SavedStream] = []

    private let savedKey = "saved_streams_v1"
    private var cancellables = Set<AnyCancellable>()

    init() {
        loadSaved()
        _ = NetworkMonitor.shared   // start monitoring before the first open()
        // Re-publish the nested player's changes so views observing the
        // controller update when playback state (e.g. hasStream) changes.
        player.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // When playback drops/fails, the player asks us to re-resolve the stream
        // fresh (new live-edge URL) so it can reconnect.
        player.onReloadRequested = { [weak self] in
            Task { @MainActor in await self?.reloadCurrent() }
        }
        observeAppLifecycle()
    }

    // MARK: - Auto audio-only in background

    /// The video quality we switched away from when backgrounding, to restore.
    private var preBackgroundQuality: String?

    private func observeAppLifecycle() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                       object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleEnterBackground() }
        }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification,
                       object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleEnterForeground() }
        }
    }

    private func handleEnterBackground() {
        // Auto streams go audio-only in the background on their own (see
        // PlayerModel.setBackgroundAudioOnly), without a reload.
        guard UserDefaults.standard.bool(forKey: "audio_only_in_background"),
              player.hasStream,
              selectedQuality != "audio_only", selectedQuality != "auto",
              qualities.contains("audio_only") else { return }
        preBackgroundQuality = selectedQuality
        Task { await play(quality: "audio_only") }
    }

    private func handleEnterForeground() {
        guard let quality = preBackgroundQuality else { return }
        preBackgroundQuality = nil
        // Optionally stay audio-only; the user picks a video quality to resume video.
        guard !UserDefaults.standard.bool(forKey: "audio_only_on_resume") else { return }
        Task { await play(quality: quality) }
    }

    /// Re-resolve and reload the current stream at its selected quality.
    func reloadCurrent() async {
        await play(quality: selectedQuality)
    }

    // MARK: - Resolve / play

    /// Whether the current URL is a Twitch stream (so we should attach auth).
    private var isTwitch: Bool { urlText.lowercased().contains("twitch.tv") }

    /// Resolve `url`'s streams, with the Twitch auth token if there is one.
    private func resolveStreams(_ url: String) async throws -> ResolvedStreams {
        let token = url.lowercased().contains("twitch.tv") ? await TwitchAuth.token() : nil
        return try await ResolvedStreams.resolve(url, twitchAuth: token)
    }

    /// Low latency is a player setting (see HLSPlaylistLoader).
    private var lowLatency: Bool {
        isTwitch && UserDefaults.standard.bool(forKey: "twitch_low_latency")
    }

    /// Resolve the available qualities for `urlText` without starting playback.
    @discardableResult
    func resolve() async -> Bool {
        busy = true; defer { busy = false }
        status = "Resolving \(urlText)…"
        qualities = []; aliasTargets = [:]; pluginName = nil
        channelInfo = nil   // re-fetch: the stream title/game may have changed
        do {
            let r = try await resolveStreams(urlText)
            let streams = r.qualityNames(allowAuto: UserDefaults.standard.bool(forKey: "auto_quality"))
            qualities = streams
            aliasTargets = r.aliases
            pluginName = r.plugin
            selectedQuality = streams.contains("best") ? "best" : streams[0]
            status = "Found \(streams.count) qualities."
            return true
        } catch let error as ResolvedStreams.ResolveError {
            status = "No streams: \(error.message)"
        } catch {
            status = "Error: \(error.localizedDescription)"
        }
        return false
    }

    /// Resolve the concrete URL for `quality` and start playback.
    func play(quality: String) async {
        busy = true; defer { busy = false }
        selectedQuality = quality
        status = "Opening \(quality)…"
        // Captured up front: the URL field is editable while we await below.
        let url = urlText, title = nowPlayingTitle, lowLatency = lowLatency
        do {
            // Resolved afresh each time, for a new token and live edge.
            if let sel = try await resolveStreams(url).select(quality) {
                let audioOnly = quality.lowercased().contains("audio")
                // Auto streams adapt inside AVPlayer, so let it apply the cellular cap.
                let cap = sel.name == "auto" && capOnCellular ? CGSize(width: 1280, height: 720) : .zero
                player.load(sel, title: title,
                            subtitle: pluginName ?? "Streamlink", audioOnly: audioOnly,
                            adaptive: sel.name == "auto", maxResolutionOnCellular: cap,
                            lowLatency: lowLatency)
                refreshNowPlayingInfo(url: url, fallbackTitle: title)
                status = "Playing \(sel.name)"
            } else {
                status = "Cannot play: no playable streams found for this URL"
            }
        } catch let error as ResolvedStreams.ResolveError {
            status = "Cannot play: \(error.message)"
        } catch {
            status = "Error: \(error.localizedDescription)"
        }
    }

    /// Quick path from the streams page: switch URL, resolve, and play the
    /// requested quality. `auto` and `best` are interchangeable — whichever the
    /// stream offers (auto when it's adaptive HLS) — else the top quality.
    /// On cellular, `best` is capped to 720p unless the user turned that off
    /// (auto gets the same cap inside AVPlayer; see `play`).
    func open(url: String, quality: String) async {
        urlText = url
        guard await resolve() else { return }
        var q = quality
        if !qualities.contains(q) {
            if ["auto", "best"].contains(q), let top = ["auto", "best"].first(where: qualities.contains) {
                q = top
            } else {
                q = qualities.first ?? "best"
            }
        }
        if q == "best", NetworkMonitor.shared.isCellular, capOnCellular,
           let capped = cappedQuality(maxHeight: 720) {
            q = capped
        }
        await play(quality: q)
    }

    private var capOnCellular: Bool {
        UserDefaults.standard.object(forKey: "cap_720_on_cellular") as? Bool ?? true
    }

    /// The highest quality at or below `maxHeight` (e.g. 720p60 for 720), or nil
    /// if `best` is already within the cap or the names don't encode a height.
    func cappedQuality(maxHeight: Int) -> String? {
        let best = aliasTargets["best"] ?? qualities.first { Self.height(of: $0) != nil }
        guard let best, let bestHeight = Self.height(of: best), bestHeight > maxHeight else { return nil }
        // `qualities` is ordered best → worst, so the first match is the highest.
        return qualities.first { (Self.height(of: $0) ?? .max) <= maxHeight }
    }

    /// Vertical resolution encoded in a quality name ("720p60" → 720), if any.
    static func height(of quality: String) -> Int? {
        let digits = quality.prefix { $0.isNumber }
        guard !digits.isEmpty, quality.dropFirst(digits.count).first == "p" else { return nil }
        return Int(digits)
    }

    /// User-facing name for a quality ("best" → "Best (1080p60)", "auto" →
    /// "Auto (720p60)" with what's playing now, "audio_only" → "Audio only").
    func displayName(for quality: String) -> String {
        switch quality {
        case "auto":
            // Match the playing height back to a quality name for its frame rate,
            // unless several differ in it (e.g. 720p60 and 720p30). Variants like
            // 720p60_alt / 720p60_portrait count as 720p60.
            guard selectedQuality == "auto", let h = player.videoHeight else { return "Auto" }
            let names = Set(qualities.filter { Self.height(of: $0) == h }
                .map { String($0.prefix { $0 != "_" }) })
            return "Auto (\(names.count == 1 ? names.first! : "\(h)p"))"
        case "best":
            return aliasTargets["best"].map { "Best (\($0))" } ?? "Best"
        case "audio_only": return "Audio only"
        default: return quality
        }
    }

    func stop() { player.stop() }

    /// A human-friendly title for Now Playing, derived from the current URL
    /// (e.g. a saved stream's name, else the channel/last path component).
    var nowPlayingTitle: String {
        let t = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = saved.first(where: { $0.url == t }) { return match.name }
        return Self.defaultName(for: t)
    }

    /// Twitch channel info for Now Playing, keyed by the stream URL it's for.
    private var channelInfo: (url: String, info: TwitchMetadata.Info)?
    private var channelInfoTask: Task<Void, Never>?
    /// The stream URL whose info Now Playing should show (the one last loaded).
    private var nowPlayingURL: String?

    /// Show the channel's stream title, name/game and profile picture in Now
    /// Playing for the just-loaded `url`. Cached info is applied right away (so
    /// quality switches and reconnects keep it); a new channel is fetched and
    /// applied on arrival. `fallbackTitle` is used when the channel is offline.
    func refreshNowPlayingInfo(url: String, fallbackTitle: String) {
        nowPlayingURL = url
        if let cached = channelInfo, cached.url == url {
            applyNowPlaying(cached.info, fallbackTitle: fallbackTitle)
            return
        }
        channelInfoTask?.cancel()
        guard let login = TwitchMetadata.channel(from: url) else { return }
        channelInfoTask = Task { [weak self] in
            guard let info = await TwitchMetadata.fetch(login: login), !Task.isCancelled,
                  let self else { return }
            channelInfo = (url, info)
            // Another stream may have been loaded while this was in flight.
            guard nowPlayingURL == url else { return }
            applyNowPlaying(info, fallbackTitle: fallbackTitle)
        }
    }

    private func applyNowPlaying(_ info: TwitchMetadata.Info, fallbackTitle: String) {
        let subtitle = [info.displayName, info.game].compactMap { $0 }.joined(separator: " · ")
        player.updateNowPlaying(title: info.title ?? fallbackTitle,
                                subtitle: subtitle, artwork: info.artwork)
    }

    // MARK: - Chat

    /// Best-effort chat page for the current stream, shown in a webview under
    /// the player. Twitch is wired up; other services fall back to a placeholder.
    var chatURL: URL? { Self.chatURL(for: urlText) }

    static func chatURL(for urlString: String) -> URL? {
        guard let u = URL(string: urlString), let host = u.host?.lowercased() else { return nil }
        if host.contains("twitch.tv") {
            let channel = u.path.split(separator: "/").first.map(String.init)
            if let channel, !channel.isEmpty {
                return URL(string: "https://www.twitch.tv/popout/\(channel)/chat?popout=")
            }
        }
        return nil
    }

    // MARK: - Saved streams

    var isCurrentSaved: Bool {
        let t = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        return saved.contains { $0.url == t }
    }

    func add(url: String, name: String? = nil) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let idx = saved.firstIndex(where: { $0.url == trimmed }) {
            if let name, !name.isEmpty { saved[idx].name = name }
        } else {
            let display = (name?.isEmpty == false) ? name! : Self.defaultName(for: trimmed)
            saved.insert(SavedStream(name: display, url: trimmed), at: 0)
        }
        persistSaved()
    }

    func toggleSavedForCurrent() {
        let t = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = saved.first(where: { $0.url == t }) {
            remove(existing)
        } else {
            add(url: t)
        }
    }

    func remove(_ stream: SavedStream) {
        saved.removeAll { $0.id == stream.id }
        persistSaved()
    }

    func remove(atOffsets offsets: IndexSet) {
        saved.remove(atOffsets: offsets)
        persistSaved()
    }

    /// Expand typed shorthand into a full URL: a bare channel name ("xqc") is a
    /// Twitch channel, and a scheme-less address ("twitch.tv/xqc") gets https.
    static func normalizedURL(_ input: String) -> String {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains("://") else { return t }
        if !t.contains("."), !t.contains("/") { return "https://twitch.tv/\(t)" }
        return "https://\(t)"
    }

    static func defaultName(for url: String) -> String {
        guard let u = URL(string: url), let host = u.host else { return url }
        let clean = host.replacingOccurrences(of: "www.", with: "")
        let last = u.path.split(separator: "/").last.map(String.init)
        if let last, !last.isEmpty { return "\(clean)/\(last)" }
        return clean
    }

    private func loadSaved() {
        guard let data = UserDefaults.standard.data(forKey: savedKey),
              let list = try? JSONDecoder().decode([SavedStream].self, from: data) else { return }
        saved = list
    }

    private func persistSaved() {
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: savedKey)
        }
    }
}
