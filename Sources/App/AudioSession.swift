import AVFoundation

/// Configures the shared AVAudioSession for media playback so audio continues
/// in the background (with `UIBackgroundModes: audio`) and routes through the
/// native audio system, Control Center, and AirPlay.
enum AudioSession {
    static func activate() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, options: [.allowAirPlay])
            try session.setActive(true)
        } catch {
            NSLog("[AudioSession] activation failed: \(error.localizedDescription)")
        }
    }
}
