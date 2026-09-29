import UIKit

/// Channel metadata for Now Playing (display name, stream title, game, and the
/// channel's profile picture as artwork), fetched from Twitch's public GQL
/// endpoint. It needs only the public web Client-ID — no user login or OAuth token.
enum TwitchMetadata {
    struct Info {
        var displayName: String
        var title: String?
        var game: String?
        var artwork: UIImage?
    }

    /// Profile pictures rarely change and their URLs are content-addressed, so
    /// cache the decoded images for the app's lifetime.
    private static let imageCache = NSCache<NSURL, UIImage>()

    /// The channel login for a live-channel URL like `twitch.tv/<login>`, or nil
    /// for other Twitch pages (VODs, clips, directory).
    static func channel(from urlString: String) -> String? {
        guard let u = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = u.host?.lowercased(), host.hasSuffix("twitch.tv") else { return nil }
        let parts = u.path.split(separator: "/").map(String.init)
        guard parts.count == 1, let login = parts.first?.lowercased(),
              !["videos", "directory", "downloads", "settings"].contains(login),
              login.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
        return login
    }

    static func fetch(login: String) async -> Info? {
        let query = """
            query($login: String!) { user(login: $login) {
              displayName profileImageURL(width: 300) stream { title game { name } } } }
            """
        guard let data = try? await TwitchAPI.gql(["query": query, "variables": ["login": login]]),
              let json = try? JSONSerialization.data(withJSONObject: data),
              let user = try? JSONDecoder().decode(Response.self, from: json).user else { return nil }

        var info = Info(displayName: user.displayName, title: user.stream?.title,
                        game: user.stream?.game?.name)
        if let imageURL = user.profileImageURL.flatMap(URL.init(string:)) {
            info.artwork = await image(at: imageURL)
        }
        return info
    }

    private static func image(at url: URL) async -> UIImage? {
        if let cached = imageCache.object(forKey: url as NSURL) { return cached }
        var req = URLRequest(url: url)
        req.setValue(await TwitchAPI.userAgent(), forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let image = UIImage(data: data) else { return nil }
        imageCache.setObject(image, forKey: url as NSURL)
        return image
    }

    /// GQL `data`.
    private struct Response: Decodable {
        let user: User?
        struct User: Decodable {
            let displayName: String
            let profileImageURL: String?
            let stream: Stream?
        }
        struct Stream: Decodable {
            let title: String?
            let game: Game?
        }
        struct Game: Decodable { let name: String }
    }
}
