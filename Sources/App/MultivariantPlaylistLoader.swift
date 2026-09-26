import AVFoundation

/// Serves an adaptive stream's multivariant (master) playlist to AVPlayer after
/// rewriting it, so AVPlayer will switch to the audio-only variant in the
/// background. Twitch declares that variant as `VIDEO="audio_only"` with a
/// matching `#EXT-X-MEDIA:TYPE=VIDEO` group, which AVPlayer won't select as
/// audio-only; stripping the video group makes it a plain audio-only variant.
///
/// Only the master playlist goes through here (via a custom URL scheme); the
/// variant playlists and segments it references are loaded by AVPlayer directly.
final class MultivariantPlaylistLoader: NSObject, AVAssetResourceLoaderDelegate {
    let queue = DispatchQueue(label: "MultivariantPlaylistLoader")
    private let headers: [String: String]

    init(headers: [String: String]) {
        self.headers = headers
    }

    // MARK: URL scheme mapping

    /// "https://…" → "slmaster-https://…", so AVPlayer asks us for it.
    private static let schemePrefix = "slmaster-"

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
        var request = URLRequest(url: real)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        URLSession.shared.dataTask(with: request) { data, response, error in
            let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            guard ok, let data, let text = String(data: data, encoding: .utf8) else {
                loadingRequest.finishLoading(with: error ?? URLError(.badServerResponse))
                return
            }
            let body = Data(Self.rewrite(text, baseURL: response?.url ?? real).utf8)
            if let info = loadingRequest.contentInformationRequest {
                info.contentType = "public.m3u-playlist"
                info.contentLength = Int64(body.count)
                info.isByteRangeAccessSupported = false
            }
            loadingRequest.dataRequest?.respond(with: body)
            loadingRequest.finishLoading()
        }.resume()
        return true
    }

    // MARK: Rewriting

    private static let videoCodecs = ["avc1", "avc3", "hvc1", "hev1", "av01", "vp09", "dvh1", "dvhe"]

    /// Make audio-only variants plain audio-only (drop their `VIDEO=` group and
    /// that group's `#EXT-X-MEDIA` line), and resolve relative URIs against
    /// `baseURL`, since AVPlayer sees the playlist at our custom-scheme URL.
    static func rewrite(_ playlist: String, baseURL: URL) -> String {
        var lines = playlist.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .init(charactersIn: "\r")) }

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

        var out: [String] = []
        for line in lines {
            if line.hasPrefix("#EXT-X-MEDIA:"), attribute("TYPE", in: line) == "VIDEO",
               let group = attribute("GROUP-ID", in: line), droppedGroups.contains(group) {
                continue
            }
            if !line.isEmpty, !line.hasPrefix("#") {
                out.append(URL(string: line, relativeTo: baseURL)?.absoluteString ?? line)
            } else if line.hasPrefix("#"), let uri = attribute("URI", in: line),
                      let absolute = URL(string: uri, relativeTo: baseURL)?.absoluteString, absolute != uri {
                out.append(line.replacingOccurrences(of: "URI=\"\(uri)\"", with: "URI=\"\(absolute)\""))
            } else {
                out.append(line)
            }
        }
        return out.joined(separator: "\n")
    }

    /// The value of `NAME=value` / `NAME="value"` in an HLS tag's attribute list.
    private static func attribute(_ name: String, in line: String) -> String? {
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
