import WebKit

/// Reads the Twitch `auth-token` cookie from the webview cookie store shared by
/// the in-app chat view. When the user logs into Twitch there (to chat), the
/// cookie becomes available and is sent with Twitch API calls for authenticated
/// stream resolution — no Safari cookie sharing needed (iOS forbids that anyway).
///
/// `@MainActor`-isolated: `WKWebsiteDataStore`/WebKit must be first touched on
/// the main thread, or WebKit's one-time init traps (EXC_BREAKPOINT).
@MainActor
enum TwitchAuth {
    /// The persistent cookie store used by the chat webview and read here.
    static var cookieStore: WKHTTPCookieStore {
        WKWebsiteDataStore.default().httpCookieStore
    }

    /// The current Twitch OAuth token, if the user is logged in via the chat view.
    static func token() async -> String? {
        await cookie(named: "auth-token")
    }

    /// The value of a twitch.tv cookie in the webview store.
    static func cookie(named name: String) async -> String? {
        let cookies = await allCookies()
        return cookies.first {
            $0.name == name && $0.domain.contains("twitch.tv")
        }?.value
    }

    /// Whether a Twitch auth token is currently present.
    static func isLoggedIn() async -> Bool {
        await token() != nil
    }

    /// Remove all Twitch cookies, logging the user out.
    static func logout() async {
        let cookies = await allCookies()
        for cookie in cookies where cookie.domain.contains("twitch.tv") {
            await withCheckedContinuation { cont in
                cookieStore.delete(cookie) { cont.resume() }
            }
        }
    }

    private static func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { cont in
            cookieStore.getAllCookies { cont.resume(returning: $0) }
        }
    }
}
