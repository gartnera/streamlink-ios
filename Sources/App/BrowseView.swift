import SwiftUI

/// The main page: add a URL, pick a quick quality, and open saved streams.
/// Opening a stream is delegated to the parent, which expands the player.
struct BrowseView: View {
    @ObservedObject var controller: StreamController
    /// Open (url, quality) — parent resolves + plays and expands the player.
    var openStream: (String, String) -> Void
    var showDiagnostics: () -> Void

    /// Quick quality applied when tapping a saved stream or "Play".
    @AppStorage("quick_quality") private var quickQuality: String = "best"
    /// With Auto quality on, "best" opens the adaptive stream instead.
    @AppStorage("auto_quality") private var autoQuality = false
    @State private var newURL: String = ""

    private let quickOptions = ["best", "audio_only"]

    var body: some View {
        VStack(spacing: 0) {
            header
            List {
                addSection
                savedSection
                if !controller.status.isEmpty {
                    Section {
                        Text(controller.status)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.insetGrouped)
        }    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Streamlink")
                .font(.largeTitle.bold())
            Spacer()
            Button {
                showDiagnostics()
            } label: {
                Image(systemName: "gearshape")
                    .font(.title2)
            }
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var addSection: some View {
        Section("Add a stream") {
            HStack(spacing: 8) {
                TextField("Twitch channel or URL", text: $newURL)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .onSubmit(playNew)
                Button(action: playNew) {
                    if controller.busy { ProgressView() } else { Text("Play") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(controller.busy || newURL.isEmpty)
            }

            Picker("Quick quality", selection: $quickQuality) {
                Text(autoQuality ? "Auto" : "Best").tag("best")
                Text("Audio").tag("audio_only")
            }
            .pickerStyle(.segmented)

            if !newURL.isEmpty {
                Button {
                    controller.add(url: StreamController.normalizedURL(newURL))
                    newURL = ""
                } label: {
                    Label("Save to list", systemImage: "bookmark")
                }
            }
        }
    }

    @ViewBuilder
    private var savedSection: some View {
        if controller.saved.isEmpty {
            Section("Saved") {
                Text("No saved streams yet. Add one above.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else {
            Section("Saved") {
                ForEach(controller.saved) { stream in
                    Button {
                        openStream(stream.url, quickQuality)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(stream.name).foregroundStyle(.primary)
                            Text(stream.url)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            controller.remove(stream)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .contextMenu {
                        ForEach(quickOptions, id: \.self) { q in
                            Button("Play \(label(for: q))") { openStream(stream.url, q) }
                        }
                        Button(role: .destructive) { controller.remove(stream) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
                .onDelete { controller.remove(atOffsets: $0) }
            }
        }
    }

    private func playNew() {
        let url = StreamController.normalizedURL(newURL)
        guard !url.isEmpty else { return }
        openStream(url, quickQuality)
    }

    private func label(for quality: String) -> String {
        switch quality {
        case "best": return autoQuality ? "Auto" : "Best"
        case "audio_only": return "Audio"
        default: return quality
        }
    }
}
