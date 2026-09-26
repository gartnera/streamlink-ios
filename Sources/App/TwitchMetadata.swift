import UIKit

/// Channel metadata for Now Playing (display name, stream title, game, and the
/// channel's profile picture as artwork), fetched from Twitch's public GQL
/// endpoint. It needs only the public web Client-ID Streamlink itself uses —
/// no user login or OAuth token.
enum TwitchMetadata {
    struct Info {
        var displayName: String
        var title: String?
        var game: String?
        var artwork: UIImage?
    }

    private static let clientID = "kimne78kx3ncx6brgo4mv6wki5h1ko"
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
        guard let url = URL(string: "https://gql.twitch.tv/gql") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue(clientID, forHTTPHeaderField: "Client-Id")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let query = """
            query($login: String!) { user(login: $login) {
              displayName profileImageURL(width: 300) stream { title game { name } } } }
            """
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "query": query, "variables": ["login": login],
        ])

        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let resp = try? JSONDecoder().decode(Response.self, from: data),
              let user = resp.data?.user else { return nil }

        var info = Info(displayName: user.displayName, title: user.stream?.title,
                        game: user.stream?.game?.name)
        if let imageURL = user.profileImageURL.flatMap(URL.init(string:)) {
            info.artwork = await image(at: imageURL)
        }
        return info
    }

    private static func image(at url: URL) async -> UIImage? {
        if let cached = imageCache.object(forKey: url as NSURL) { return cached }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let image = UIImage(data: data) else { return nil }
        imageCache.setObject(image, forKey: url as NSURL)
        return image
    }

    private struct Response: Decodable {
        struct Payload: Decodable { let user: User? }
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
        let data: Payload?
    }
}
