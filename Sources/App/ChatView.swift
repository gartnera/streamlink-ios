import SwiftUI

/// A webview for a stream's chat, shown under the player in full mode. When no
/// chat URL is available for the current service it shows a placeholder so the
/// layout is ready for chat regardless.
struct ChatView: View {
    let url: URL?

    var body: some View {
        Group {
            if let url {
                WebView(url: url)
            } else {
                placeholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.secondarySystemBackground))
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Chat unavailable for this stream")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
