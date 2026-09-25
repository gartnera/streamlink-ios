import SwiftUI
import WebKit

/// A WKWebView backed by the shared persistent cookie store, so a Twitch login
/// performed in any instance (chat or the dedicated login page) persists and its
/// `auth-token` cookie is available to `TwitchAuth`.
struct WebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.websiteDataStore = .default()   // persistent, shared cookie store
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.scrollView.backgroundColor = .clear
        webView.uiDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if webView.url != url {
            webView.load(URLRequest(url: url))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKUIDelegate {
        /// Load target=_blank links (e.g. a login popup) in the same webview
        /// instead of silently dropping them.
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }
    }
}

/// Full-page Twitch login, opened from the info panel. On dismissal the caller
/// re-reads the auth token from the shared cookie store.
struct TwitchLoginView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            WebView(url: URL(string: "https://www.twitch.tv/login")!)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Twitch Login")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}
