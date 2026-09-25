import SwiftUI

@main
struct StreamlinkApp: App {
    init() {
        AudioSession.activate()
        // Warm up the interpreter off the main thread so the first request is fast.
        DispatchQueue.global(qos: .userInitiated).async {
            PythonBridge.shared.bootstrap()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
