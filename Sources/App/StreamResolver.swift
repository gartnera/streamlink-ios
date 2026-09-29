import Foundation

/// A stream URL for AVPlayer, with the HTTP headers to load it with.
struct SelectedStream: Hashable {
    let name: String
    let url: String
    let headers: [String: String]
}

/// Turns a page URL into playable qualities: Twitch live channels, VODs and
/// clips (via `TwitchAPI`), and direct HLS (`hls://…` or a `.m3u8` URL).
/// Quality names, ordering and `best` follow Streamlink's.
struct ResolvedStreams {
    /// "twitch" or "hls".
    let plugin: String
    /// Concrete qualities in playlist order, e.g. 1080p60 → audio_only.
    let streams: [(name: String, url: URL)]
    /// The multivariant playlist, which AVPlayer can play as "auto".
    let multivariant: URL?
    let headers: [String: String]

    struct ResolveError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
        static let noStreams = ResolveError(message: "no playable streams found for this URL")
    }

    static func resolve(_ urlString: String, twitchAuth: String?) async throws -> ResolvedStreams {
        var url = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !url.contains("://") { url = "https://" + url }

        if let target = TwitchAPI.target(for: url) {
            if case .clip(let slug) = target {
                let clips = try await TwitchAPI.clipQualities(slug: slug)
                guard !clips.isEmpty else { throw ResolveError.noStreams }
                return ResolvedStreams(plugin: "twitch", streams: clips, multivariant: nil,
                                       headers: await TwitchAPI.browserHeaders())
            }
            guard let playlist = try await TwitchAPI.playlistURL(for: target, authToken: twitchAuth) else {
                throw ResolveError.noStreams
            }
            return try await fromPlaylist(playlist, plugin: "twitch", headers: await TwitchAPI.browserHeaders())
        }

        let prefix = ["hls://", "hlsvariant://"].first { url.lowercased().hasPrefix($0) }
        if let prefix {
            url = String(url.dropFirst(prefix.count))
            if !url.contains("://") { url = "https://" + url }
        }
        guard let direct = URL(string: url), ["http", "https"].contains(direct.scheme?.lowercased()),
              prefix != nil || direct.pathExtension.lowercased() == "m3u8" else {
            throw ResolveError(message: "unsupported URL: only Twitch and HLS (.m3u8) streams can be played")
        }
        return try await fromPlaylist(direct, plugin: "hls", headers: ["User-Agent": await TwitchAPI.userAgent()])
    }

    // MARK: Playlists

    private static func fromPlaylist(_ url: URL, plugin: String, headers: [String: String]) async throws -> ResolvedStreams {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // Offline Twitch channels answer 404 with a JSON error.
        guard (200..<300).contains(status), let text = String(data: data, encoding: .utf8) else {
            throw ResolveError.noStreams
        }
        guard text.hasPrefix("#EXTM3U") else { throw ResolveError(message: "not an HLS playlist") }
        guard text.contains("#EXT-X-STREAM-INF:") else {
            // A media playlist: one stream, named like Streamlink's.
            return ResolvedStreams(plugin: plugin, streams: [("live", url)], multivariant: nil, headers: headers)
        }
        let streams = variants(in: text, baseURL: response.url ?? url, twitch: plugin == "twitch")
        guard !streams.isEmpty else { throw ResolveError.noStreams }
        return ResolvedStreams(plugin: plugin, streams: streams, multivariant: url, headers: headers)
    }

    /// Named variants of a multivariant playlist, deduplicated with `_alt`/`_alt2`.
    static func variants(in playlist: String, baseURL: URL, twitch: Bool) -> [(name: String, url: URL)] {
        let lines = playlist.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let attr = HLSPlaylistLoader.attribute
        // Video rendition names by group, as Streamlink names non-Twitch variants.
        var videoNames: [String: String] = [:]
        for line in lines where line.hasPrefix("#EXT-X-MEDIA:") && attr("TYPE", line) == "VIDEO" {
            if let group = attr("GROUP-ID", line), let name = attr("NAME", line), !name.isEmpty {
                videoNames[group] = name
            }
        }

        var result: [(name: String, url: URL)] = []
        var pending: String?
        for line in lines {
            if line.hasPrefix("#EXT-X-STREAM-INF:") { pending = line; continue }
            guard let inf = pending, !line.isEmpty, !line.hasPrefix("#") else { continue }
            pending = nil
            guard let url = URL(string: line, relativeTo: baseURL)?.absoluteURL,
                  var name = twitch ? twitchName(inf) : genericName(inf, videoNames: videoNames) else { continue }
            if result.contains(where: { $0.name == name }) {
                name += "_alt"
                let alts = result.filter { $0.name.hasPrefix(name) }.count
                if alts >= 2 { continue }
                if alts > 0 { name += "\(alts + 1)" }
            }
            result.append((name, url))
        }
        return result
    }

    private static func genericName(_ inf: String, videoNames: [String: String]) -> String? {
        if let group = HLSPlaylistLoader.attribute("VIDEO", in: inf), let name = videoNames[group] { return name }
        return pixelsName(inf, withFramerate: false) ?? bandwidthName(inf)
    }

    /// Twitch names variants by `STABLE-VARIANT-ID` ("1080p60", "audio_only").
    private static func twitchName(_ inf: String) -> String? {
        let attr = HLSPlaylistLoader.attribute
        let variant = attr("STABLE-VARIANT-ID", inf)?.lowercased() ?? ""
        if attr("IVS-GROUPS", inf)?.lowercased() == "portrait", let pixels = pixelsName(inf, withFramerate: true) {
            return pixels + "_portrait"
        }
        if variant.hasPrefix("audio") { return "audio_only" }
        return variant.isEmpty ? pixelsName(inf, withFramerate: true) : variant
    }

    /// "720p60" (frame rate shown above 30 fps, or always with `withFramerate`).
    private static func pixelsName(_ inf: String, withFramerate: Bool) -> String? {
        guard let resolution = HLSPlaylistLoader.attribute("RESOLUTION", in: inf),
              let height = resolution.split(separator: "x").last.flatMap({ Int($0) }), height > 0 else { return nil }
        if let fps = HLSPlaylistLoader.attribute("FRAME-RATE", in: inf).flatMap(Double.init), withFramerate || fps > 30 {
            return "\(height)p\(Int(fps.rounded(.up)))"
        }
        return "\(height)p"
    }

    private static func bandwidthName(_ inf: String) -> String? {
        guard let bw = HLSPlaylistLoader.attribute("BANDWIDTH", in: inf).flatMap(Int.init), bw > 0 else { return nil }
        return bw >= 1000 ? "\(bw / 1000)k" : "\(Double(bw) / 1000)k"
    }

    // MARK: Qualities

    /// The concrete quality `best` stands for: the highest-weighted, not
    /// counting audio-only or (Twitch) portrait variants.
    var best: String? {
        if streams.count == 1 { return streams[0].name }
        let candidates = streams.map(\.name).filter { !$0.hasPrefix("audio") && !$0.hasSuffix("_portrait") }
        // Ties go to the later one, as in Streamlink.
        return candidates.reduce(nil as (String, Double)?) { top, name in
            let w = Self.weight(name)
            guard w > 0 else { return top }
            return w >= (top?.1 ?? 0) ? (name, w) : top
        }?.0
    }

    /// Streamlink's `stream_weight`: resolution (+fps) or bit rate, minus alts.
    static func weight(_ name: String) -> Double {
        let regex = try! NSRegularExpression(pattern: #"^(\d+)(k|p)?(\d+)?(\+)?(?:[a_](\d+)k)?(?:_(alt)(\d)?)?$"#)
        guard let m = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) else { return 0 }
        func group(_ i: Int) -> String? { Range(m.range(at: i), in: name).map { String(name[$0]) } }
        var weight = 0.0
        if group(6) != nil { weight -= 0.01 * Double(group(7).flatMap(Int.init) ?? 1) }
        switch group(2) {
        case "k": return weight + Double(group(1)!)! / 2800
        case "p":
            weight += Double(group(1)!)!
            weight += group(3).flatMap(Double.init) ?? 0
            if group(4) == "+" { weight += 1 }
            weight += (group(5).flatMap(Double.init) ?? 0) / 2800
            return weight
        default: return 0
        }
    }

    /// Qualities for the picker: `auto` (with `allowAuto`, for adaptive HLS) or
    /// `best`, then `audio_only`, then the rest highest → lowest.
    func qualityNames(allowAuto: Bool) -> [String] {
        var front: [String] = allowAuto && multivariant != nil ? ["auto"] : best != nil ? ["best"] : []
        let names = streams.map(\.name)
        if names.contains("audio_only") { front.append("audio_only") }
        let rest = names.filter { !front.contains($0) }
        let numbered = rest.filter { $0.contains(where: \.isNumber) }
            .sorted { Self.sortKey($1).lexicographicallyPrecedes(Self.sortKey($0)) }
        let unnumbered = rest.filter { !$0.contains(where: \.isNumber) }.reversed()
        return front + numbered + unnumbered
    }

    /// Numbers in the name, then alternates just after their main variant.
    private static func sortKey(_ name: String) -> [Int] {
        var base = name, alt = 0
        if let r = name.range(of: #"_alt(\d*)$"#, options: .regularExpression) {
            base = String(name[..<r.lowerBound])
            alt = Int(name[r].dropFirst(4)) ?? 1
        }
        let numbers = base.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        return numbers + [-alt]
    }

    /// Alias → concrete quality, e.g. "best" → "1080p60".
    var aliases: [String: String] { best.map { ["best": $0] } ?? [:] }

    /// The stream to play for `quality` ("auto", "best", or a concrete name),
    /// falling back to `best`.
    func select(_ quality: String) -> SelectedStream? {
        if quality == "auto", let multivariant {
            return SelectedStream(name: "auto", url: multivariant.absoluteString, headers: headers)
        }
        let target = quality == "best" ? best : quality
        if let target, let stream = streams.first(where: { $0.name == target }) {
            return SelectedStream(name: quality, url: stream.url.absoluteString, headers: headers)
        }
        guard let fallback = best ?? streams.first?.name,
              let stream = streams.first(where: { $0.name == fallback }) else { return nil }
        return SelectedStream(name: best != nil ? "best" : fallback, url: stream.url.absoluteString, headers: headers)
    }
}
