import SwiftUI
import AVFoundation
import MediaPlayer

/// How the player is presented over the browse page.
enum PlayerPresentation {
    case full   // video (with quality dropdown) + chat webview
    case mini   // small in-app PiP floating at the bottom
}

struct ContentView: View {
    @StateObject private var controller = StreamController()
    @State private var presentation: PlayerPresentation = .full
    @GestureState private var dragY: CGFloat = 0
    @State private var showDiagnostics = false
    /// True while the keyboard is up (e.g. typing in chat) — we then collapse the
    /// video/quality chrome so the chat webview fills the space above the keyboard.
    @State private var keyboardVisible = false
    /// Height of the on-screen keyboard, used to inset the chat above it (SwiftUI's
    /// automatic avoidance doesn't fire for a WKWebView first responder).
    @State private var keyboardHeight: CGFloat = 0
    /// Running as an iOS app on an Apple silicon Mac ("Designed for iPad").
    private static let isOnMac = ProcessInfo.processInfo.isiOSAppOnMac

    // Mini-player dimensions (16:9).
    private let miniWidth: CGFloat = 168
    private var miniHeight: CGFloat { (miniWidth * 9 / 16).rounded() }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // Main page — interactive whenever the player isn't full.
                BrowseView(
                    controller: controller,
                    openStream: openStream,
                    showDiagnostics: { showDiagnostics = true }
                )
                .allowsHitTesting(!(controller.player.hasStream && presentation == .full))

                if controller.player.hasStream {
                    playerOverlay(geo)
                }
            }
        }
        // Keep `geo` at full height when the keyboard shows (SwiftUI would
        // otherwise shrink the GeometryReader); we inset the chat manually via
        // keyboardHeight, so this avoids double-counting and the webview overflow.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .sheet(isPresented: $showDiagnostics) { DiagnosticsView() }
        .onChange(of: controller.player.hasStream) { hasStream in
            // Test hook: launch with `--mini` to show a new stream in the mini player.
            let mini = ProcessInfo.processInfo.arguments.contains("--mini")
            if hasStream { withAnimation(spring) { presentation = mini ? .mini : .full } }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notif in
            // On macOS there's no on-screen keyboard to make room for, but the
            // notifications still fire for the hardware keyboard — ignore them.
            guard !Self.isOnMac else { return }
            let h = (notif.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue.height ?? 0
            withAnimation(.easeOut(duration: 0.25)) {
                keyboardHeight = h
                keyboardVisible = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            guard !Self.isOnMac else { return }
            withAnimation(.easeOut(duration: 0.25)) { keyboardVisible = false }
        }
        .task { await maybeRunSmokeTest() }
        // Test hook: launch with `--show-info` to open the Settings sheet.
        .task { if ProcessInfo.processInfo.arguments.contains("--show-info") { showDiagnostics = true } }
        #if DEBUG
        .task { registerDebugHooks() }
        #endif
    }

    // MARK: - Player overlay

    @ViewBuilder
    private func playerOverlay(_ geo: GeometryProxy) -> some View {
        let frame = playerFrame(geo)
        let fullVideoH = (geo.size.width * 9 / 16).rounded()
        let progress = dragProgress
        let full = presentation == .full
        let chromeOpacity = full ? 1 - progress : 0
        let wide = isWide(geo)
        // While typing in chat, collapse the video + quality bar so the webview
        // gets the full height above the keyboard. Side-by-side, the chat column
        // is already full height, so the video stays.
        let videoHidden = full && keyboardVisible && !wide

        // Full-mode backdrop + chrome. Always in the tree (so the player keeps a
        // stable position/identity), just faded out and non-interactive in mini.
        Color(.systemBackground)
            .ignoresSafeArea()
            .opacity(chromeOpacity)
            .allowsHitTesting(full)

        // Inset the chat above the keyboard (keyboard height minus the bottom
        // safe area, which the keyboard already covers).
        let kbInset = (videoHidden || (wide && keyboardVisible))
            ? max(0, keyboardHeight - geo.safeAreaInsets.bottom) : 0

        Group {
            if wide {
                // Desktop / landscape: video on the left, chat on the right.
                HStack(spacing: 0) {
                    Color.clear   // video area
                        .frame(width: geo.size.width - chatColumnWidth(geo))
                    Divider()
                    ChatView(url: controller.chatURL)
                        .padding(.bottom, kbInset)
                }
            } else {
                VStack(spacing: 0) {
                    if !videoHidden {
                        Color.clear.frame(height: fullVideoH)   // reserve the video area — no header above
                    }
                    ChatView(url: controller.chatURL)
                }
                .padding(.bottom, kbInset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(chromeOpacity)
        .allowsHitTesting(full)

        // The single shared player instance — a constant id keeps it alive as its
        // frame animates between full and mini, so playback is never interrupted.
        PlayerView(model: controller.player)
            .frame(width: frame.width, height: videoHidden ? 0 : frame.height)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: presentation == .mini ? 12 : 0))
            .shadow(color: .black.opacity(presentation == .mini ? 0.3 : 0),
                    radius: 8, y: 4)
            .scaleEffect(full ? 1 - progress * 0.08 : 1, anchor: .top)
            .opacity(videoHidden ? 0 : 1)
            .offset(x: frame.minX, y: frame.minY + (full ? dragY : 0))
            .simultaneousGesture(pullDownGesture)
            .allowsHitTesting(!videoHidden)
            .id("sharedPlayer")

        // Quality dropdown over the video. It shows and hides with AVKit's own
        // controls, and stays up while a quality is loading.
        if full, !videoHidden, !controller.qualities.isEmpty {
            let menuShown = controller.player.controlsVisible || controller.busy
            qualityMenu
                .frame(width: frame.width, alignment: .center)
                .offset(x: frame.minX, y: frame.minY + 10 + (full ? dragY : 0))
                .opacity((menuShown ? 1 : 0) * chromeOpacity)
                .allowsHitTesting(menuShown)
                .animation(.easeInOut(duration: 0.2), value: menuShown)
        }

        if presentation == .mini {
            // Audio-only streams have no video, so show artwork in the mini player
            // instead of a black frame (full mode keeps the plain player + chat).
            if controller.player.isAudioOnly {
                AudioArtworkView()
                    .frame(width: frame.width, height: frame.height)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .offset(x: frame.minX, y: frame.minY)
                    .allowsHitTesting(false)
            }

            // AVPlayerViewController swallows taps (it shows its own transport
            // controls), so a transparent catcher on top handles tap-to-expand.
            Color.clear
                .contentShape(Rectangle())
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
                .onTapGesture { expand() }

            miniCloseButton(geo, videoFrame: frame)
        }

        // Reconnect / failure overlay over the video area (full mode only).
        if full, !videoHidden, controller.player.playbackFailed || controller.player.isReconnecting {
            ZStack {
                if controller.player.playbackFailed {
                    Color.black.opacity(0.7)
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.largeTitle).foregroundStyle(.yellow)
                        Text("Playback failed").font(.headline).foregroundStyle(.white)
                        Button { controller.player.retry() } label: {
                            Label("Retry", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    Color.black.opacity(0.5)
                    VStack(spacing: 8) {
                        ProgressView().tint(.white)
                        Text("Reconnecting…").font(.footnote).foregroundStyle(.white)
                    }
                }
            }
            .frame(width: frame.width, height: frame.height)
            .offset(x: frame.minX, y: frame.minY)
            .allowsHitTesting(controller.player.playbackFailed)
        }
    }

    private var qualityMenu: some View {
        Menu {
            Picker("Quality", selection: Binding(
                get: { controller.selectedQuality },
                set: { quality in Task { await controller.play(quality: quality) } }
            )) {
                ForEach(controller.qualities, id: \.self) { quality in   // best, audio_only, then best → worst
                    Text(controller.displayName(for: quality)).tag(quality)
                }
            }
        } label: {
            HStack(spacing: 5) {
                if controller.busy {
                    ProgressView().controlSize(.mini).tint(.white)
                }
                Text(controller.displayName(for: controller.selectedQuality))
                    .font(.footnote.weight(.semibold))
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.black.opacity(0.55), in: Capsule())
        }
        .disabled(controller.busy)
    }

    private func miniCloseButton(_ geo: GeometryProxy, videoFrame: CGRect) -> some View {
        Button {
            withAnimation(spring) { controller.stop() }
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.title3)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .black.opacity(0.6))
        }
        .offset(x: videoFrame.maxX - 14, y: videoFrame.minY - 10)
    }

    // MARK: - Geometry

    private func playerFrame(_ geo: GeometryProxy) -> CGRect {
        let w = geo.size.width
        switch presentation {
        case .full where isWide(geo):
            // Fill the left column; AVKit letterboxes.
            return CGRect(x: 0, y: 0, width: w - chatColumnWidth(geo), height: geo.size.height)
        case .full:
            return CGRect(x: 0, y: 0, width: w, height: (w * 9 / 16).rounded())
        case .mini:
            return CGRect(x: w - miniWidth - 12,
                          y: geo.size.height - miniHeight - 12,
                          width: miniWidth, height: miniHeight)
        }
    }

    /// Landscape / desktop-sized windows put chat beside the video instead of below.
    private func isWide(_ geo: GeometryProxy) -> Bool {
        geo.size.width > geo.size.height && geo.size.width >= 700
    }

    private func chatColumnWidth(_ geo: GeometryProxy) -> CGFloat {
        min(456, max(360, (geo.size.width * 0.36).rounded()))
    }

    /// 0 → not dragging, 1 → dragged far enough to collapse.
    private var dragProgress: CGFloat {
        guard presentation == .full, dragY > 0 else { return 0 }
        return min(dragY / 260, 1)
    }

    private var spring: Animation { .spring(response: 0.35, dampingFraction: 0.85) }

    // MARK: - Gestures / transitions

    private var pullDownGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .updating($dragY) { value, state, _ in
                if presentation == .full, value.translation.height > 0 {
                    state = value.translation.height
                }
            }
            .onEnded { value in
                if presentation == .full, value.translation.height > 120 {
                    withAnimation(spring) { presentation = .mini }
                }
            }
    }

    private func expand() {
        withAnimation(spring) { presentation = .full }
    }

    private func openStream(_ url: String, _ quality: String) {
        Task {
            await controller.open(url: url, quality: quality)
            if controller.player.hasStream {
                withAnimation(spring) { presentation = .full }
            }
        }
    }

    // MARK: - Debug server

    #if DEBUG
    private static let debugActions = [
        "open {url, quality?}", "play {quality}", "stop", "retry", "mini", "full",
        "settings {show?}", "setting {key, value}", "save {url, name?}", "unsave {url}",
    ]

    /// Expose navigation + state to `DebugServer`, and start it if enabled
    /// (`--debug-server` or Settings → Developer, which can also start it later).
    private func registerDebugHooks() {
        DebugServer.shared.app = .init(state: debugState, perform: debugAction)
        if DebugServer.enabled { DebugServer.shared.start() }
    }

    private func debugState() -> [String: Any] {
        let p = controller.player
        let item = p.player.currentItem
        var player: [String: Any] = [
            "has_stream": p.hasStream, "audio_only": p.isAudioOnly, "reconnecting": p.isReconnecting,
            "failed": p.playbackFailed, "controls_visible": p.controlsVisible,
            "video_height": p.videoHeight as Any, "rate": p.player.rate,
            "time_control": ["paused", "waiting", "playing"][p.player.timeControlStatus.rawValue],
            "item_status": item.map { ["unknown", "ready", "failed"][$0.status.rawValue] } as Any,
            "item_error": item?.error?.localizedDescription as Any,
            "latency": p.latency as Any,
            "configured_live_offset": item.map { $0.configuredTimeOffsetFromLive.seconds }
                .flatMap { $0.isFinite ? $0 : nil } as Any,
            "recommended_live_offset": item.map { $0.recommendedTimeOffsetFromLive.seconds }
                .flatMap { $0.isFinite ? $0 : nil } as Any,
        ]
        if let ev = item?.accessLog()?.events.last {
            player["observed_kbps"] = Int(ev.observedBitrate / 1000)
            player["indicated_kbps"] = Int(ev.indicatedBitrate / 1000)
            player["stalls"] = ev.numberOfStalls
        }
        let settingKeys = ["quick_quality", "twitch_low_latency", "auto_quality", "cap_720_on_cellular",
                           "audio_only_in_background", "audio_only_on_resume", "chat_betterttv"]
        return [
            "presentation": presentation == .full ? "full" : "mini",
            "settings_shown": showDiagnostics,
            "keyboard_visible": keyboardVisible,
            "url": controller.urlText, "status": controller.status, "busy": controller.busy,
            "plugin": controller.pluginName as Any, "qualities": controller.qualities,
            "selected_quality": controller.selectedQuality,
            "quality_label": controller.displayName(for: controller.selectedQuality),
            "chat_url": controller.chatURL?.absoluteString as Any,
            "chat_webview_url": DebugServer.shared.webViewURL as Any,
            "saved": controller.saved.map { ["name": $0.name, "url": $0.url] },
            "player": player,
            "settings": Dictionary(uniqueKeysWithValues: settingKeys.map {
                ($0, UserDefaults.standard.object(forKey: $0) ?? NSNull())
            }),
            "actions": Self.debugActions,
        ]
    }

    private func debugAction(_ name: String, _ args: [String: Any]) async throws {
        func arg(_ key: String) throws -> String {
            guard let v = args[key] as? String, !v.isEmpty else { throw DebugServer.ActionError("missing \"\(key)\"") }
            return v
        }
        switch name {
        case "open":
            showDiagnostics = false
            await controller.open(url: try arg("url"), quality: args["quality"] as? String ?? "best")
            if controller.player.hasStream { withAnimation(spring) { presentation = .full } }
        case "play":
            await controller.play(quality: try arg("quality"))
        case "stop":
            withAnimation(spring) { controller.stop() }
        case "retry":
            controller.player.retry()
        case "mini", "full":
            guard controller.player.hasStream else { throw DebugServer.ActionError("no stream playing") }
            withAnimation(spring) { presentation = name == "mini" ? .mini : .full }
        case "settings":
            showDiagnostics = args["show"] as? Bool ?? true
        case "setting":
            let key = try arg("key")
            if let value = args["value"], !(value is NSNull) {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        case "save":
            controller.add(url: try arg("url"), name: args["name"] as? String)
        case "unsave":
            let url = try arg("url")
            guard let stream = controller.saved.first(where: { $0.url == url }) else {
                throw DebugServer.ActionError("not saved: \(url)")
            }
            controller.remove(stream)
        default:
            throw DebugServer.ActionError("unknown action \"\(name)\"; one of: \(Self.debugActions.joined(separator: ", "))")
        }
    }
    #endif

    // MARK: - Smoke test

    /// Headless smoke test: launch with `--smoke-url <URL>` to auto-resolve and
    /// write the JSON result to the app container for `xcrun simctl` to read.
    private func maybeRunSmokeTest() async {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--smoke-url"), i + 1 < args.count else { return }
        let url = args[i + 1]
        let quality = args.firstIndex(of: "--smoke-quality").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? "best"
        var out: [String: Any] = ["url": url, "quality": quality]
        do {
            let r = try await ResolvedStreams.resolve(url, twitchAuth: await TwitchAuth.token())
            let sel = r.select(quality)
            out["ok"] = sel != nil
            out["plugin"] = r.plugin
            out["aliases"] = r.aliases
            out["streams"] = r.streams.map(\.name)
            out["request_headers"] = r.headers
            out["selected_url"] = sel?.url as Any
            out["selected_name"] = sel?.name as Any
            if let sel {
                controller.urlText = url
                // Populate qualities so the on-screen UI matches a real session.
                controller.qualities = r.qualityNames(allowAuto: UserDefaults.standard.bool(forKey: "auto_quality"))
                controller.aliasTargets = r.aliases
                controller.pluginName = r.plugin
                controller.selectedQuality = sel.name
                let lowLatency = args.contains("--smoke-low-latency")
                out["low_latency"] = lowLatency
                controller.player.load(sel, title: controller.nowPlayingTitle,
                                       subtitle: controller.pluginName ?? "Streamlink",
                                       adaptive: sel.name == "auto", lowLatency: lowLatency)
                controller.refreshNowPlayingInfo(url: url, fallbackTitle: controller.nowPlayingTitle)
                let pb = await probePlayback(sel)
                out.merge(pb) { _, new in new }
                out["qualities"] = controller.qualities
                out["video_height"] = controller.player.videoHeight as Any
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                out["video_height_10s"] = controller.player.videoHeight as Any
                // Live streams only; nil for VOD.
                out["latency_10s"] = controller.player.latency as Any
                out["recommended_live_offset_10s"] = controller.player.player.currentItem
                    .map { $0.recommendedTimeOffsetFromLive.seconds }.flatMap { $0.isFinite ? $0 : nil } as Any
                if let ev = controller.player.player.currentItem?.accessLog()?.events.last {
                    out["observed_kbps"] = Int(ev.observedBitrate / 1000)
                    out["indicated_kbps"] = Int(ev.indicatedBitrate / 1000)
                    out["switch_bitrate_kbps"] = Int(ev.switchBitrate / 1000)
                    out["stalls"] = ev.numberOfStalls
                }
                out["label"] = controller.displayName(for: controller.selectedQuality)
                let np = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                out["now_playing_title"] = np[MPMediaItemPropertyTitle] as Any
                out["now_playing_artist"] = np[MPMediaItemPropertyArtist] as Any
                out["now_playing_artwork"] = (np[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork)
                    .map { "\(Int($0.bounds.width))x\(Int($0.bounds.height))" } as Any
            }
        } catch {
            out["ok"] = false
            out["error"] = error.localizedDescription
        }
        writeResult("smoke_result.json", out)
    }

    /// Build an AVPlayer exactly as PlayerView does and wait until it is actually
    /// playing (or fails), proving the native playback path end-to-end.
    private func probePlayback(_ stream: SelectedStream) async -> [String: Any] {
        guard let url = URL(string: stream.url) else {
            return ["playback_ok": false, "playback_reason": "invalid url"]
        }
        var options: [String: Any] = [:]
        if !stream.headers.isEmpty { options["AVURLAssetHTTPHeaderFieldsKey"] = stream.headers }
        let asset = AVURLAsset(url: url, options: options)
        let item = AVPlayerItem(asset: asset)
        let probe = AVPlayer(playerItem: item)
        probe.play()
        for _ in 0..<40 {
            if item.status == .failed {
                return ["playback_ok": false,
                        "playback_reason": item.error?.localizedDescription ?? "item failed"]
            }
            if item.status == .readyToPlay, probe.timeControlStatus == .playing {
                return ["playback_ok": true, "time_control": "playing"]
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return ["playback_ok": false,
                "playback_reason": "timeout (itemStatus=\(item.status.rawValue) tcs=\(probe.timeControlStatus.rawValue))",
                "player_error": item.error?.localizedDescription as Any]
    }

    private func writeResult(_ name: String, _ dict: [String: Any]) {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let file = dir.appendingPathComponent(name)
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]) {
            try? data.write(to: file)
            NSLog("[Streamlink] RESULT_WRITTEN \(file.path)")
        }
    }
}

/// The Settings sheet.
struct DiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var loggedIn = false
    @State private var showLogin = false
    @AppStorage("twitch_low_latency") private var lowLatency = false
    @AppStorage("audio_only_in_background") private var audioOnlyInBackground = false
    @AppStorage("audio_only_on_resume") private var audioOnlyOnResume = false
    @AppStorage("cap_720_on_cellular") private var cap720OnCellular = true
    @AppStorage("auto_quality") private var autoQuality = false
    @AppStorage("chat_betterttv") private var betterTTV = true
    #if DEBUG
    @AppStorage(DebugServer.settingKey) private var debugServer = false
    #endif

    var body: some View {
        NavigationStack {
            List {
                accountSection
                playbackSection
                chatSection
                #if DEBUG
                developerSection
                #endif
                Section("About") {
                    LabeledContent("Version", value: appVersion)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task { loggedIn = await TwitchAuth.isLoggedIn() }
            .sheet(isPresented: $showLogin, onDismiss: {
                Task { loggedIn = await TwitchAuth.isLoggedIn() }
            }) {
                TwitchLoginView()
            }
        }
    }

    private var accountSection: some View {
        Section {
            // A Label (like the buttons below) so the icons and text line up.
            Label {
                Text(loggedIn ? "Logged in to Twitch" : "Not logged in")
            } icon: {
                Image(systemName: loggedIn ? "checkmark.seal.fill" : "person.crop.circle")
                    .foregroundStyle(loggedIn ? .green : .secondary)
            }
            Button {
                showLogin = true
            } label: {
                Label(loggedIn ? "Manage Twitch login" : "Log in to Twitch",
                      systemImage: "person.crop.circle.badge.plus")
            }
            if loggedIn {
                Button(role: .destructive) {
                    Task {
                        await TwitchAuth.logout()
                        loggedIn = await TwitchAuth.isLoggedIn()
                    }
                } label: {
                    Label("Log out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        } header: {
            Text("Account")
        } footer: {
            Text("Enables subscriber quality and fewer ads. Your login stays on-device.")
        }
    }

    private var playbackSection: some View {
        Section("Playback") {
            SettingToggle("Twitch low latency", "Reduces stream delay.", isOn: $lowLatency)
            SettingToggle("Auto quality", "Best adapts to your connection.", isOn: $autoQuality)
            SettingToggle("Limit to 720p on cellular", "Best/Auto open at 720p on mobile data.",
                          isOn: $cap720OnCellular)
            SettingToggle("Audio-only in background", "Drops video when you leave the app. Auto always does.",
                          isOn: $audioOnlyInBackground)
            SettingToggle("Stay audio-only on resume", "Pick a quality to turn video back on.",
                          isOn: $audioOnlyOnResume)
                .disabled(!audioOnlyInBackground)
        }
    }

    private var chatSection: some View {
        Section("Chat") {
            SettingToggle("BetterTTV in chat", "BTTV/FFZ/7TV emotes, from cdn.betterttv.net.",
                          isOn: $betterTTV)
        }
    }

    #if DEBUG
    private var developerSection: some View {
        Section {
            SettingToggle("Debug server", "HTTP API into app internals, port \(DebugServer.port.rawValue).",
                          isOn: $debugServer)
                .onChange(of: debugServer) { on in
                    if on {
                        DebugServer.shared.start()
                    } else if !DebugServer.launchEnabled {
                        DebugServer.shared.stop()
                    }
                }
            if debugServer || DebugServer.launchEnabled, !DebugServer.loopbackOnly {
                let base = "http://\(DebugServer.addresses.first ?? "<device-ip>"):\(DebugServer.port.rawValue)"
                LabeledContent("Address", value: base)
                    .font(.caption.monospaced())
                LabeledContent("Token", value: DebugServer.token)
                    .font(.caption.monospaced())
                Button {
                    UIPasteboard.general.string = "curl -H 'X-Debug-Token: \(DebugServer.token)' \(base)/state"
                } label: {
                    Label("Copy curl command", systemImage: "doc.on.doc")
                }
            }
        } header: {
            Text("Developer")
        } footer: {
            Text(DebugServer.loopbackOnly ? "Listens on localhost only."
                 : "Reachable from your local network with the token.")
        }
    }
    #endif

    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }
}

/// A settings toggle with a one-line description under its title.
private struct SettingToggle: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    init(_ title: String, _ detail: String, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        self._isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
