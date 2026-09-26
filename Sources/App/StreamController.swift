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

    @Published var urlText: String = "https://streamlink.github.io/"
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
        guard UserDefaults.standard.bool(forKey: "audio_only_in_background"),
              player.hasStream,
              selectedQuality != "audio_only",
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

    /// Build a request body, attaching the Twitch auth token and any Streamlink
    /// options (e.g. low latency) that apply.
    private func requestBody(_ base: [String: Any]) async -> [String: Any] {
        var body = base
        if isTwitch, let token = await TwitchAuth.token() {
            body["twitch_auth"] = token
        }
        var options: [String: Any] = [:]
        if isTwitch, UserDefaults.standard.bool(forKey: "twitch_low_latency") {
            options["twitch-low-latency"] = true
        }
        if !options.isEmpty { body["options"] = options }
        return body
    }

    /// Resolve the available qualities for `urlText` without starting playback.
    @discardableResult
    func resolve() async -> Bool {
        busy = true; defer { busy = false }
        status = "Resolving \(urlText)…"
        qualities = []; aliasTargets = [:]; pluginName = nil
        do {
            let body = await requestBody(["op": "streams", "url": urlText])
            let r: ResolveResponse = try await PythonBridge.shared.request(
                body, as: ResolveResponse.self)
            if r.ok, let streams = r.streams, !streams.isEmpty {
                qualities = streams
                aliasTargets = r.aliases ?? [:]
                pluginName = r.plugin
                selectedQuality = streams.contains("best") ? "best" : streams[0]
                status = "Found \(streams.count) qualities."
                return true
            } else {
                status = "No streams: \(r.error ?? "unknown error")"
            }
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
        do {
            let body = await requestBody(["op": "resolve", "url": urlText, "quality": quality])
            let r: ResolveResponse = try await PythonBridge.shared.request(
                body, as: ResolveResponse.self)
            if r.ok, let sel = r.selected {
                let audioOnly = quality.lowercased().contains("audio")
                player.load(sel, title: nowPlayingTitle,
                            subtitle: pluginName ?? "Streamlink", audioOnly: audioOnly)
                status = "Playing \(sel.name)"
            } else {
                status = "Cannot play: \(r.error ?? "unknown error")"
            }
        } catch {
            status = "Error: \(error.localizedDescription)"
        }
    }

    /// Quick path from the streams page: switch URL, resolve, and play the
    /// requested quality — falling back to `best` if that quality isn't offered.
    /// On cellular, `best` is capped to 720p unless the user turned that off.
    func open(url: String, quality: String) async {
        urlText = url
        guard await resolve() else { return }
        var q = qualities.contains(quality)
            ? quality
            : (qualities.contains("best") ? "best" : (qualities.first ?? "best"))
        if q == "best", NetworkMonitor.shared.isCellular,
           UserDefaults.standard.object(forKey: "cap_720_on_cellular") as? Bool ?? true,
           let capped = cappedQuality(maxHeight: 720) {
            q = capped
        }
        await play(quality: q)
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

    /// User-facing name for a quality ("best" → "Best (1080p60)", "audio_only" → "Audio only").
    func displayName(for quality: String) -> String {
        switch quality {
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
