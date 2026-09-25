import SwiftUI

/// Original artwork shown in the player area for audio-only streams (no video),
/// so the mini and full player show something instead of a black frame. A purple
/// gradient (matching the app icon) with a simple animated equalizer.
struct AudioArtworkView: View {
    /// Animate the bars only when it's worth it (e.g. the mini player on screen).
    var animated: Bool = true
    @State private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(
                    colors: [Color(red: 142/255, green: 45/255, blue: 226/255),
                             Color(red: 74/255, green: 0/255, blue: 224/255)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )

                let barCount = 5
                let unit = geo.size.height
                let barWidth = max(3, unit * 0.06)
                HStack(alignment: .center, spacing: barWidth * 0.7) {
                    ForEach(0..<barCount, id: \.self) { i in
                        Capsule()
                            .fill(.white.opacity(0.9))
                            .frame(width: barWidth, height: barHeight(i, unit: unit))
                    }
                }
            }
            .clipped()
        }
        .onAppear {
            guard animated else { return }
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                phase = 1
            }
        }
    }

    /// Deterministic-ish varied bar heights that breathe with `phase`.
    private func barHeight(_ i: Int, unit: CGFloat) -> CGFloat {
        let base: [CGFloat] = [0.35, 0.6, 0.9, 0.5, 0.7]
        let swing: [CGFloat] = [0.25, 0.35, 0.15, 0.4, 0.3]
        let f = base[i % base.count] + swing[i % swing.count] * (i.isMultiple(of: 2) ? phase : (1 - phase))
        return unit * min(0.92, f) * 0.5 + unit * 0.12
    }
}
