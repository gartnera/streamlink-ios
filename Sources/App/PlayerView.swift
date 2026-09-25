import SwiftUI
import AVKit

/// Wraps AVPlayer in a SwiftUI view. Builds an AVURLAsset with any HTTP headers
/// Streamlink says the stream requires, then plays natively (HLS / progressive),
/// with audio going through the AVAudioSession configured at launch.
struct PlayerView: UIViewControllerRepresentable {
    let stream: SelectedStream

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = makePlayer()
        controller.player?.play()
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        // Rebuild only if the stream identity changed.
        if context.coordinator.currentURL != stream.url {
            context.coordinator.currentURL = stream.url
            controller.player = makePlayer()
            controller.player?.play()
        }
    }

    func makeCoordinator() -> Coordinator {
        let c = Coordinator()
        c.currentURL = stream.url
        return c
    }

    final class Coordinator {
        var currentURL: String?
    }

    private func makePlayer() -> AVPlayer? {
        guard let url = URL(string: stream.url) else { return nil }
        var options: [String: Any] = [:]
        if !stream.headers.isEmpty {
            options["AVURLAssetHTTPHeaderFieldsKey"] = stream.headers
        }
        let asset = AVURLAsset(url: url, options: options)
        let item = AVPlayerItem(asset: asset)
        return AVPlayer(playerItem: item)
    }
}
