import AVFoundation

/// Serves HLS playlists to AVPlayer after rewriting them (via a custom URL
/// scheme), for two reasons:
///
/// - Multivariant (master) playlists: so AVPlayer will switch to the audio-only
///   variant in the background. Twitch declares that variant as
///   `VIDEO="audio_only"` with a matching `#EXT-X-MEDIA:TYPE=VIDEO` group, which
///   AVPlayer won't select as audio-only; stripping the video group makes it a
///   plain audio-only variant.
/// - Media playlists, with `lowLatency`: Twitch declares
///   `#EXT-X-TARGETDURATION:6` for 2 s segments, and AVPlayer won't play closer
///   to live than three target durations (18 s). Declaring the real longest
///   segment lets it get within a few seconds.
///
/// Segments are always loaded by AVPlayer directly.
final class HLSPlaylistLoader: NSObject, AVAssetResourceLoaderDelegate {
    let queue = DispatchQueue(label: "HLSPlaylistLoader")
    private let headers: [String: String]
    private let lowLatency: Bool
    /// Target duration served per media playlist, so it never drops between
    /// reloads (the spec forbids changing it). Accessed on `queue`.
    private var targetDurations: [URL: Int] = [:]

    init(headers: [String: String], lowLatency: Bool) {
        self.headers = headers
        self.lowLatency = lowLatency
    }

    // MARK: URL scheme mapping

    /// "https://…" → "slplaylist-https://…", so AVPlayer asks us for it.
    private static let schemePrefix = "slplaylist-"

    static func assetURL(for url: URL) -> URL? {
        guard let scheme = url.scheme,
              var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        c.scheme = schemePrefix + scheme
        return c.url
    }

    private static func realURL(for url: URL) -> URL? {
        guard let scheme = url.scheme, scheme.hasPrefix(schemePrefix),
              var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        c.scheme = String(scheme.dropFirst(schemePrefix.count))
        return c.url
    }

    // MARK: AVAssetResourceLoaderDelegate

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = loadingRequest.request.url, let real = Self.realURL(for: url) else { return false }
        // Live playlists change on every reload.
        var request = URLRequest(url: real, cachePolicy: .reloadIgnoringLocalCacheData)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        URLSession.shared.dataTask(with: request) { data, response, error in
            let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            guard ok, let data, let text = String(data: data, encoding: .utf8) else {
                loadingRequest.finishLoading(with: error ?? URLError(.badServerResponse))
                return
            }
            self.queue.async { self.respond(loadingRequest, text: text, url: real, baseURL: response?.url ?? real) }
        }.resume()
        return true
    }

    private func respond(_ loadingRequest: AVAssetResourceLoadingRequest, text: String, url: URL, baseURL: URL) {
        let pin: ((Int) -> Int)? = lowLatency ? { [self] longest in
            let duration = max(targetDurations[url] ?? 0, longest)
            targetDurations[url] = duration
            return duration
        } : nil
        let body = Data(Self.rewrite(text, baseURL: baseURL, proxyPlaylists: lowLatency, targetDuration: pin).utf8)
        if let info = loadingRequest.contentInformationRequest {
            info.contentType = "public.m3u-playlist"
            info.contentLength = Int64(body.count)
            info.isByteRangeAccessSupported = false
        }
        loadingRequest.dataRequest?.respond(with: body)
        loadingRequest.finishLoading()
    }

    // MARK: Rewriting

    private static let videoCodecs = ["avc1", "avc3", "hvc1", "hev1", "av01", "vp09", "dvh1", "dvhe"]

    /// Rewrite a master or media playlist (see the type's doc), resolving
    /// relative URIs against `baseURL`, since AVPlayer sees the playlist at our
    /// custom-scheme URL. With `proxyPlaylists`, a master's playlist URIs are
    /// routed back through us so their media playlists get rewritten too.
    /// `targetDuration` maps a media playlist's longest segment (rounded) to the
    /// target duration to declare; nil leaves it alone.
    static func rewrite(_ playlist: String, baseURL: URL, proxyPlaylists: Bool,
                        targetDuration: ((Int) -> Int)?) -> String {
        let lines = playlist.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .init(charactersIn: "\r")) }
        if lines.contains(where: { $0.hasPrefix("#EXT-X-STREAM-INF:") }) {
            return rewriteMultivariant(lines, baseURL: baseURL, proxyPlaylists: proxyPlaylists)
        }
        return rewriteMedia(lines, baseURL: baseURL, targetDuration: targetDuration)
    }

    /// Make audio-only variants plain audio-only (drop their `VIDEO=` group and
    /// that group's `#EXT-X-MEDIA` line).
    private static func rewriteMultivariant(_ lines: [String], baseURL: URL, proxyPlaylists: Bool) -> String {
        var lines = lines
        var droppedGroups = Set<String>()
        var keptGroups = Set<String>()
        for (i, line) in lines.enumerated() where line.hasPrefix("#EXT-X-STREAM-INF:") {
            guard let group = attribute("VIDEO", in: line) else { continue }
            let codecs = attribute("CODECS", in: line)?.lowercased() ?? ""
            if !codecs.isEmpty, !videoCodecs.contains(where: codecs.contains) {
                lines[i] = removingAttribute("VIDEO", from: line)
                droppedGroups.insert(group)
            } else {
                keptGroups.insert(group)
            }
        }
        droppedGroups.subtract(keptGroups)

        let resolve = { (uri: String, line: String) -> String in
            guard let url = URL(string: uri, relativeTo: baseURL)?.absoluteURL else { return uri }
            // Variant and rendition playlists, not e.g. `#EXT-X-SESSION-KEY` URIs.
            let isPlaylist = !line.hasPrefix("#") || line.hasPrefix("#EXT-X-MEDIA:")
                || line.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:")
            return (proxyPlaylists && isPlaylist ? assetURL(for: url) : url)?.absoluteString ?? uri
        }
        return resolvingURIs(lines.filter { line in
            !(line.hasPrefix("#EXT-X-MEDIA:") && attribute("TYPE", in: line) == "VIDEO" &&
              attribute("GROUP-ID", in: line).map(droppedGroups.contains) == true)
        }, with: resolve)
    }

    /// Lower `#EXT-X-TARGETDURATION` to what `targetDuration` returns for the
    /// longest segment (rounded to nearest, as the spec requires), if smaller.
    private static func rewriteMedia(_ lines: [String], baseURL: URL, targetDuration: ((Int) -> Int)?) -> String {
        var lines = lines
        if let targetDuration,
           let longest = lines.compactMap({ line -> Double? in
               guard line.hasPrefix("#EXTINF:") else { return nil }
               return Double(line.dropFirst("#EXTINF:".count).prefix { $0 != "," })
           }).max(),
           let i = lines.firstIndex(where: { $0.hasPrefix("#EXT-X-TARGETDURATION:") }),
           let declared = Int(lines[i].dropFirst("#EXT-X-TARGETDURATION:".count)) {
            let duration = targetDuration(max(1, Int(longest.rounded())))
            if duration < declared { lines[i] = "#EXT-X-TARGETDURATION:\(duration)" }
        }
        return resolvingURIs(lines) { uri, _ in URL(string: uri, relativeTo: baseURL)?.absoluteString ?? uri }
    }

    /// Map every URI line and `URI="…"` attribute through `resolve(uri, line)`.
    private static func resolvingURIs(_ lines: [String], with resolve: (String, String) -> String) -> String {
        lines.map { line in
            if !line.isEmpty, !line.hasPrefix("#") { return resolve(line, line) }
            if line.hasPrefix("#"), let uri = attribute("URI", in: line) {
                let mapped = resolve(uri, line)
                if mapped != uri { return line.replacingOccurrences(of: "URI=\"\(uri)\"", with: "URI=\"\(mapped)\"") }
            }
            return line
        }.joined(separator: "\n")
    }

    /// The value of `NAME=value` / `NAME="value"` in an HLS tag's attribute list.
    static func attribute(_ name: String, in line: String) -> String? {
        guard let match = attributeRegex(name).firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[range]).trimmingCharacters(in: .init(charactersIn: "\""))
    }

    private static func removingAttribute(_ name: String, from line: String) -> String {
        let regex = try! NSRegularExpression(pattern: ",\(name)=(\"[^\"]*\"|[^,]*)|(?<=:)\(name)=(\"[^\"]*\"|[^,]*),?")
        return regex.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "")
    }

    private static func attributeRegex(_ name: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: "[:,]\(name)=(\"[^\"]*\"|[^,]*)")
    }
}
