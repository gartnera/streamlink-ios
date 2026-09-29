import SwiftUI

@main
struct StreamlinkApp: App {
    init() {
        AudioSession.activate()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
