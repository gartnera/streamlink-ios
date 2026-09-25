import SwiftUI
import AVFoundation

/// How the player is presented over the browse page.
enum PlayerPresentation {
    case full   // video + one-line quality + chat webview
    case mini   // small in-app PiP floating at the bottom
}

struct ContentView: View {
    @StateObject private var controller = StreamController()
    @State private var presentation: PlayerPresentation = .full
    @GestureState private var dragY: CGFloat = 0
    @State private var diag: DiagResponse?
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
        .sheet(isPresented: $showDiagnostics) { DiagnosticsView(diag: diag) }
        .onChange(of: controller.player.hasStream) { hasStream in
            if hasStream { withAnimation(spring) { presentation = .full } }
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
        .task { await runDiagnostics() }
        .task { await maybeRunSmokeTest() }
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
                // Desktop / landscape: video + quality bar on the left, chat on the right.
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: max(0, geo.size.height - qualityBarHeight))   // video area
                        qualityBar.frame(height: qualityBarHeight)
                    }
                    .frame(width: geo.size.width - chatColumnWidth(geo))
                    Divider()
                    ChatView(url: controller.chatURL)
                        .padding(.bottom, kbInset)
                }
            } else {
                VStack(spacing: 0) {
                    if !videoHidden {
                        Color.clear.frame(height: fullVideoH)   // reserve the video area — no header above
                        qualityBar
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

    private var qualityBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(controller.qualities, id: \.self) { quality in
                    QualityChip(
                        title: quality,
                        selected: quality == controller.selectedQuality,
                        action: { Task { await controller.play(quality: quality) } }
                    )
                    .disabled(controller.busy)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity)
        .background(Color(.systemBackground))
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
            // Fill the left column above the quality bar; AVKit letterboxes.
            return CGRect(x: 0, y: 0, width: w - chatColumnWidth(geo),
                          height: max(0, geo.size.height - qualityBarHeight))
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

    private let qualityBarHeight: CGFloat = 52

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

    // MARK: - Diagnostics

    private func runDiagnostics() async {
        do {
            let d: DiagResponse = try await PythonBridge.shared.request(["op": "diag"], as: DiagResponse.self)
            diag = d
            NSLog("[Streamlink] diag: python=\(d.python ?? "?") checks=\(d.checks ?? [:])")
            writeResult("diag.json", [
                "ok": d.ok, "python": d.python as Any, "platform": d.platform as Any,
                "checks": d.checks as Any,
            ])
        } catch {
            diag = DiagResponse(ok: false, python: nil, platform: nil, checks: nil, error: error.localizedDescription)
            NSLog("[Streamlink] diag failed: \(error.localizedDescription)")
            writeResult("diag.json", ["ok": false, "error": error.localizedDescription])
        }
    }

    // MARK: - Smoke test

    /// Headless smoke test: launch with `--smoke-url <URL>` to auto-resolve and
    /// write the JSON result to the app container for `xcrun simctl` to read.
    private func maybeRunSmokeTest() async {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--smoke-url"), i + 1 < args.count else { return }
        let url = args[i + 1]
        var out: [String: Any] = ["url": url]
        do {
            let r: ResolveResponse = try await PythonBridge.shared.request(
                ["op": "resolve", "url": url, "quality": "best"], as: ResolveResponse.self)
            out["ok"] = r.ok
            out["error"] = r.error as Any
            out["selected_url"] = r.selected?.url as Any
            out["selected_name"] = r.selected?.name as Any
            if r.ok, let sel = r.selected {
                controller.urlText = url
                // Populate qualities so the on-screen UI matches a real session.
                if let s: ResolveResponse = try? await PythonBridge.shared.request(
                    ["op": "streams", "url": url], as: ResolveResponse.self), let list = s.streams {
                    controller.qualities = list
                    controller.pluginName = s.plugin
                }
                controller.player.load(sel, title: controller.nowPlayingTitle,
                                       subtitle: controller.pluginName ?? "Streamlink")
                let pb = await probePlayback(sel)
                out.merge(pb) { _, new in new }
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

/// A pill-shaped, tappable quality option that plays on tap.
private struct QualityChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(selected ? Color.accentColor : Color(.secondarySystemBackground))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Runtime diagnostics, shown on demand rather than inline.
struct DiagnosticsView: View {
    let diag: DiagResponse?
    @Environment(\.dismiss) private var dismiss
    @State private var loggedIn = false
    @State private var showLogin = false
    @AppStorage("twitch_low_latency") private var lowLatency = false
    @AppStorage("audio_only_in_background") private var audioOnlyInBackground = false
    @AppStorage("audio_only_on_resume") private var audioOnlyOnResume = false
    @AppStorage("chat_betterttv") private var betterTTV = true

    var body: some View {
        NavigationStack {
            List {
                accountSection
                playbackSection
                chatSection
                if let diag {
                    Section("Runtime") {
                        LabeledContent("Python", value: diag.python ?? "?")
                        LabeledContent("Platform", value: diag.platform ?? "—")
                    }
                    if let checks = diag.checks, !checks.isEmpty {
                        Section("Checks") {
                            ForEach(checks.sorted(by: { $0.key < $1.key }), id: \.key) { k, v in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: v.hasPrefix("ok") ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .foregroundStyle(v.hasPrefix("ok") ? .green : .red)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(k).font(.subheadline.weight(.medium))
                                        Text(v).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    if let err = diag.error {
                        Section("Error") {
                            Text(err).font(.caption.monospaced()).foregroundStyle(.red)
                        }
                    }
                } else {
                    Text("Loading Python runtime…").foregroundStyle(.secondary)
                }
                Section("About") {
                    LabeledContent("Version", value: appVersion)
                }
            }
            .navigationTitle("Info")
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
            HStack {
                Image(systemName: loggedIn ? "checkmark.seal.fill" : "person.crop.circle")
                    .foregroundStyle(loggedIn ? .green : .secondary)
                Text(loggedIn ? "Logged in to Twitch" : "Not logged in")
                Spacer()
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
            Text("Logging in enables subscriber quality and fewer ads on Twitch. Your login stays on-device.")
        }
    }

    private var playbackSection: some View {
        Section {
            Toggle("Twitch low latency", isOn: $lowLatency)
            Toggle("Audio-only in background", isOn: $audioOnlyInBackground)
            Toggle("Stay audio-only on resume", isOn: $audioOnlyOnResume)
                .disabled(!audioOnlyInBackground)
        } header: {
            Text("Playback")
        } footer: {
            Text("Low latency reduces Twitch delay. Audio-only in background drops video to save data when you leave the app. Stay audio-only on resume keeps it that way when you come back — pick a quality to turn video back on.")
        }
    }

    private var chatSection: some View {
        Section {
            Toggle("BetterTTV in chat", isOn: $betterTTV)
        } header: {
            Text("Chat")
        } footer: {
            Text("Loads BetterTTV from cdn.betterttv.net into Twitch chat for BTTV/FFZ/7TV emotes and chat features. Applies to the next stream you open.")
        }
    }

    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }
}
