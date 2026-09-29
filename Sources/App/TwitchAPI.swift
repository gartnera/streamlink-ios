import Foundation
import WebKit

/// Twitch's web GQL API and its usher playlist service, called the way
/// Streamlink's Twitch plugin does: a playback access token from GQL, then the
/// multivariant playlist from usher signed with it.
enum TwitchAPI {
    /// The public Client-ID of Twitch's web player.
    static let clientID = "kimne78kx3ncx6brgo4mv6wki5h1ko"

    /// What a Twitch URL points at.
    enum Target: Equatable {
        case live(channel: String)
        case vod(id: String)
        case clip(slug: String)
    }

    struct APIError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: URLs

    private static let patterns: [(NSRegularExpression, (String) -> Target)] = [
        (#"^https?://(?:clips\.twitch\.tv|(?:[\w-]+\.)?twitch\.tv/(?:[\w-]+/)?clip)/([^/?#]+)"#, { .clip(slug: $0) }),
        (#"^https?://(?:[\w-]+\.)?twitch\.tv/(?:[\w-]+/)?v(?:ideos?)?/(\d+)"#, { .vod(id: $0) }),
        (#"^https?://(?:(?!clips\.)[\w-]+\.)?twitch\.tv/((?!v(?:ideos?)?/|clip/)[^/?#]+)/?(?:[?#]|$)"#,
         { .live(channel: $0.lowercased()) }),
    ].map { (try! NSRegularExpression(pattern: $0, options: .caseInsensitive), $1) }

    /// The stream a Twitch URL points at: `twitch.tv/<channel>`, `…/videos/<id>`,
    /// `…/clip/<slug>`, `clips.twitch.tv/<slug>`, or `player.twitch.tv/?channel=…`.
    static func target(for urlString: String) -> Target? {
        if let c = URLComponents(string: urlString), c.host?.lowercased() == "player.twitch.tv" {
            let item = { (name: String) in c.queryItems?.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 } }
            if let video = item("video") { return .vod(id: video.hasPrefix("v") ? String(video.dropFirst()) : video) }
            return item("channel").map { .live(channel: $0.lowercased()) }
        }
        let range = NSRange(urlString.startIndex..., in: urlString)
        for (regex, target) in patterns {
            if let m = regex.firstMatch(in: urlString, range: range), let r = Range(m.range(at: 1), in: urlString) {
                return target(String(urlString[r]))
            }
        }
        return nil
    }

    // MARK: Browser identity

    /// We identify as Mobile Safari, so requests look like the embedded web
    /// player's (`playerType: embed`) in Safari. This replaces WebKit's
    /// `Mobile/15E148` user-agent suffix to turn a webview's user agent into
    /// Safari's; the chat webview uses it too, so the login cookie comes from
    /// the same "browser".
    static let safariApplicationName: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "Version/\(v.majorVersion).\(v.minorVersion) Mobile/15E148 Safari/604.1"
    }()

    @MainActor private static var userAgentTask: Task<String, Never>?

    /// Safari's user agent on this device. Read from WebKit, since it freezes
    /// the OS version in it (iOS 26 reports e.g. `iPhone OS 18_7`).
    @MainActor static func userAgent() async -> String {
        if userAgentTask == nil {
            userAgentTask = Task { @MainActor in
                let config = WKWebViewConfiguration()
                config.applicationNameForUserAgent = safariApplicationName
                let webView = WKWebView(frame: .zero, configuration: config)
                if let ua = try? await webView.evaluateJavaScript("navigator.userAgent") as? String { return ua }
                let v = ProcessInfo.processInfo.operatingSystemVersion
                return "Mozilla/5.0 (iPhone; CPU iPhone OS \(v.majorVersion)_\(v.minorVersion) like Mac OS X) " +
                    "AppleWebKit/605.1.15 (KHTML, like Gecko) \(safariApplicationName)"
            }
        }
        return await userAgentTask!.value
    }

    /// Safari's: the preferred language, plus its bare form ("en-US,en;q=0.9").
    private static let acceptLanguage: String = {
        let lang = Locale.preferredLanguages.first ?? "en-US"
        let base = lang.split(separator: "-").first.map(String.init) ?? lang
        return base == lang ? lang : "\(lang),\(base);q=0.9"
    }()

    /// Headers Safari sends for the web player's requests (playlists and
    /// segments too, so they're passed on to AVPlayer).
    static func browserHeaders() async -> [String: String] {
        [
            "User-Agent": await userAgent(),
            "Accept": "*/*",
            "Accept-Language": acceptLanguage,
            "Origin": "https://player.twitch.tv",
            "Referer": "https://player.twitch.tv/",
        ]
    }

    /// The usher multivariant playlist URL for a live channel or VOD, or nil if
    /// it's offline / doesn't exist. `authToken` is the user's `auth-token`
    /// cookie, which can unlock subscriber-only qualities and fewer ads.
    static func playlistURL(for target: Target, authToken: String?) async throws -> URL? {
        let isLive: Bool, id: String
        switch target {
        case .live(let channel): (isLive, id) = (true, channel)
        case .vod(let vod): (isLive, id) = (false, vod)
        case .clip: return nil
        }
        let data = try await gql(persisted: "PlaybackAccessToken",
                                 hash: "ed230aa1e33e07eebb8928504583da78a5173989fadfb1ac94be06a04f3cdbe9",
                                 variables: ["isLive": isLive, "login": isLive ? id : "", "isVod": !isLive,
                                             "vodID": isLive ? "" : id, "playerType": "embed", "platform": "site"],
                                 authToken: authToken)
        let token = data[isLive ? "streamPlaybackAccessToken" : "videoPlaybackAccessToken"] as? [String: Any]
        guard let value = token?["value"] as? String, let signature = token?["signature"] as? String else { return nil }

        var c = URLComponents(string: isLive ? "https://usher.ttvnw.net/api/v2/channel/hls/\(id).m3u8"
                                             : "https://usher.ttvnw.net/vod/v2/\(id).m3u8")!
        c.queryItems = [
            "platform": "web", "p": String(Int.random(in: 0..<999_999)), "allow_source": "true",
            "allow_audio_only": "true", "playlist_include_framerate": "true", "multigroup_video": "true",
            "supported_codecs": "h264",
        ].map(URLQueryItem.init) + (isLive
            ? [.init(name: "sig", value: signature), .init(name: "token", value: value), .init(name: "fast_bread", value: "true")]
            : [.init(name: "nauthsig", value: signature), .init(name: "nauth", value: value)])
        // Tokens are JSON, and `+` must not be read as a space.
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c.url
    }

    /// A clip's MP4s as (quality, signed URL), highest first; empty if it doesn't exist.
    static func clipQualities(slug: String) async throws -> [(name: String, url: URL)] {
        let data = try await gql(persisted: "VideoAccessToken_Clip",
                                 hash: "993d9a5131f15a37bd16f32342c44ed1e0b1a9b968c6afdb662d2cddd595f6c5",
                                 variables: ["slug": slug, "platform": "web"], authToken: nil)
        guard let clip = data["clip"] as? [String: Any],
              let token = clip["playbackAccessToken"] as? [String: Any],
              let sig = token["signature"] as? String, let value = token["value"] as? String,
              let qualities = clip["videoQualities"] as? [[String: Any]] else { return [] }
        return qualities.compactMap { q in
            guard let quality = q["quality"] as? String, let source = q["sourceURL"] as? String,
                  var c = URLComponents(string: source), !source.isEmpty else { return nil }
            let fps = (q["frameRate"] as? NSNumber)?.intValue ?? 0
            c.queryItems = (c.queryItems ?? []) + [.init(name: "sig", value: sig), .init(name: "token", value: value)]
            c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            return c.url.map { (fps > 0 ? "\(quality)p\(fps)" : "\(quality)p", $0) }
        }
    }

    // MARK: GQL

    /// POST a GQL query (`query`) or persisted query and return its `data`.
    static func gql(_ body: [String: Any], authToken: String? = nil) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://gql.twitch.tv/gql")!, timeoutInterval: 15)
        req.httpMethod = "POST"
        await browserHeaders().forEach { req.setValue($1, forHTTPHeaderField: $0) }
        req.setValue(clientID, forHTTPHeaderField: "Client-ID")
        // No X-Device-Id, as in Streamlink: with one, Twitch serves a pre-roll
        // ad break (its "Preparing your stream" slate) on every stream start.

        // As Safari's `fetch` from player.twitch.tv sends it.
        req.setValue("text/plain;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        req.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")
        req.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
        req.setValue("same-site", forHTTPHeaderField: "Sec-Fetch-Site")
        if let authToken { req.setValue("OAuth \(authToken)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError(message: "Twitch API: unexpected response")
        }
        if let errors = json["errors"] as? [[String: Any]], let message = errors.first?["message"] as? String {
            throw APIError(message: "Twitch API: \(message)")
        }
        if let error = json["error"] as? String {
            throw APIError(message: "Twitch API: \(error): \(json["message"] as? String ?? "unknown error")")
        }
        return json["data"] as? [String: Any] ?? [:]
    }

    private static func gql(persisted operation: String, hash: String, variables: [String: Any],
                            authToken: String?) async throws -> [String: Any] {
        try await gql([
            "operationName": operation, "variables": variables,
            "extensions": ["persistedQuery": ["version": 1, "sha256Hash": hash]],
        ], authToken: authToken)
    }
}
