import SwiftUI
import AVFoundation

struct ContentView: View {
    @State private var urlText: String = "https://streamlink.github.io/"
    @State private var qualities: [String] = []
    @State private var selectedQuality: String = "best"
    @State private var pluginName: String?
    @State private var playing: SelectedStream?
    @State private var status: String = ""
    @State private var busy = false
    @State private var diag: DiagResponse?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let stream = playing {
                        PlayerView(stream: stream)
                            .aspectRatio(16.0 / 9.0, contentMode: .fit)
                            .background(Color.black)
                            .cornerRadius(8)
                    }

                    inputSection
                    if !qualities.isEmpty { qualitySection }
                    if !status.isEmpty {
                        Text(status)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    diagnosticsSection
                }
                .padding()
            }
            .navigationTitle("Streamlink")
        }
        .task { await runDiagnostics() }
        .task { await maybeRunSmokeTest() }
    }

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Stream URL").font(.headline)
            TextField("https://twitch.tv/...", text: $urlText)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
            Button {
                Task { await resolve() }
            } label: {
                HStack {
                    if busy { ProgressView().padding(.trailing, 4) }
                    Text(busy ? "Resolving…" : "Load")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy || urlText.isEmpty)
        }
    }

    private var qualitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let plugin = pluginName {
                Text("Plugin: \(plugin)").font(.subheadline).foregroundStyle(.secondary)
            }
            Picker("Quality", selection: $selectedQuality) {
                ForEach(qualities, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu)
            Button("Play \(selectedQuality)") {
                Task { await play(quality: selectedQuality) }
            }
            .buttonStyle(.bordered)
            .disabled(busy)
        }
    }

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider().padding(.vertical, 8)
            Text("Runtime").font(.headline)
            if let diag {
                Text("Python \(diag.python ?? "?")  ·  \(diag.platform ?? "")")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach((diag.checks ?? [:]).sorted(by: { $0.key < $1.key }), id: \.key) { k, v in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: v.hasPrefix("ok") ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(v.hasPrefix("ok") ? .green : .red)
                        Text("\(k): \(v)").font(.caption.monospaced())
                    }
                }
            } else {
                Text("Loading Python runtime…").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Actions

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

    private func resolve() async {
        busy = true; defer { busy = false }
        status = "Resolving \(urlText)…"
        qualities = []; playing = nil; pluginName = nil
        do {
            let r: ResolveResponse = try await PythonBridge.shared.request(
                ["op": "streams", "url": urlText], as: ResolveResponse.self)
            if r.ok, let streams = r.streams, !streams.isEmpty {
                qualities = streams
                pluginName = r.plugin
                selectedQuality = streams.contains("best") ? "best" : streams[0]
                status = "Found \(streams.count) qualities."
            } else {
                status = "No streams: \(r.error ?? "unknown error")"
            }
        } catch {
            status = "Error: \(error.localizedDescription)"
        }
    }

    private func play(quality: String) async {
        busy = true; defer { busy = false }
        status = "Opening \(quality)…"
        do {
            let r: ResolveResponse = try await PythonBridge.shared.request(
                ["op": "resolve", "url": urlText, "quality": quality], as: ResolveResponse.self)
            if r.ok, let sel = r.selected {
                playing = sel
                status = "Playing \(sel.name)"
            } else {
                status = "Cannot play: \(r.error ?? "unknown error")"
            }
        } catch {
            status = "Error: \(error.localizedDescription)"
        }
    }

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
                playing = sel
                urlText = url
                // Confirm the native player actually starts (audio+video path).
                let pb = await probePlayback(sel)
                out.merge(pb) { _, new in new }
            }
        } catch {
            out["ok"] = false
            out["error"] = error.localizedDescription
        }
        writeResult("smoke_result.json", out)
    }

    /// Build an AVPlayer exactly as PlayerView does and wait until it is
    /// actually playing (or fails), so the smoke test proves the native
    /// playback/audio path, not just URL resolution.
    private func probePlayback(_ stream: SelectedStream) async -> [String: Any] {
        guard let url = URL(string: stream.url) else {
            return ["playback_ok": false, "playback_reason": "invalid url"]
        }
        var options: [String: Any] = [:]
        if !stream.headers.isEmpty { options["AVURLAssetHTTPHeaderFieldsKey"] = stream.headers }
        let asset = AVURLAsset(url: url, options: options)
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.play()
        for _ in 0..<40 {
            if item.status == .failed {
                return ["playback_ok": false,
                        "playback_reason": item.error?.localizedDescription ?? "item failed"]
            }
            if item.status == .readyToPlay, player.timeControlStatus == .playing {
                return ["playback_ok": true, "time_control": "playing"]
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return ["playback_ok": false,
                "playback_reason": "timeout (itemStatus=\(item.status.rawValue) tcs=\(player.timeControlStatus.rawValue))",
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
