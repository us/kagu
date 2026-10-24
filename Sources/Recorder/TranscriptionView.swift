import AppKit
import AVFoundation
import SwiftUI

/// "Kagu Settings": a sidebar of five sections, labels on the left and controls on the right.
struct SettingsView: View {
    @Bindable var transcriber: Transcriber
    let folder: URL

    enum Section: String, CaseIterable, Identifiable {
        case transcription = "Transcription", audio = "Audio", general = "General", files = "Files", privacy = "Privacy"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .transcription: "waveform"
            case .audio: "speaker.wave.2"
            case .general: "gearshape"
            case .files: "folder"
            case .privacy: "lock"
            }
        }
    }

    @State private var section = Section.transcription

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Section.allCases) { item in
                    Button { section = item } label: {
                        Label(item.rawValue, systemImage: item.icon)
                            .font(.callout)
                            .foregroundStyle(section == item ? Theme.accent : Color.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 7).fill(section == item ? Theme.selection : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(section == item ? .isSelected : [])
                }
                Spacer()
            }
            .padding(10)
            .frame(width: 170)
            .background(Theme.sidebar)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch section {
                    case .transcription: TranscriptionSettings(transcriber: transcriber)
                    case .audio: AudioSettings()
                    case .general: GeneralSettings()
                    case .files: FilesSettings(folder: folder)
                    case .privacy: PrivacySettings()
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.canvas)
        }
        .frame(width: 640, height: 420)
        .navigationTitle("Kagu Settings")
    }
}

/// A label on the left, its control on the right.
private struct SettingRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label).font(.callout).frame(width: 120, alignment: .leading)
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The label on the left, the switch at the right edge.
private struct SwitchRight: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer()
            Toggle("", isOn: configuration.$isOn).toggleStyle(.switch).labelsHidden().tint(Theme.accent)
        }
    }
}

/// A short note in a rounded box with an info icon.
private struct Note: View {
    let text: String
    var icon = "info.circle"

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(.secondary)
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card.opacity(0.7)))
    }
}

private struct TranscriptionSettings: View {
    @Bindable var transcriber: Transcriber

    var body: some View {
        Toggle(isOn: $transcriber.enabled) { Text("Transcribe new recordings automatically").font(.callout) }
            .toggleStyle(SwitchRight())
        SettingRow(label: "Speech model") {
            VStack(spacing: 0) {
                ForEach(Array(WhisperModel.allCases.enumerated()), id: \.element) { index, model in
                    if index > 0 { Divider() }
                    ModelRow(store: transcriber.models, model: model, selected: transcriber.model == model) { transcriber.model = model }
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card.opacity(0.8)))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
        }
        if transcriber.models.state(transcriber.model) == .missing {
            HStack(spacing: 10) {
                Text(transcriber.enabled ? "The chosen model is not downloaded yet, so new recordings are not transcribed until it is." : "The chosen model is downloaded the first time you transcribe.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Download") { transcriber.models.download(transcriber.model) }.controlSize(.small)
            }
            .padding(.leading, 136)
        }
        if let text = transcriber.models.message {
            Label(text, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.secondary).symbolRenderingMode(.multicolor)
        }
        SettingRow(label: "Language") {
            Picker("Language", selection: $transcriber.language) {
                ForEach(Transcriber.languages, id: \.self) { Text(languageName($0)).tag($0) }
            }
            .labelsHidden()
            .frame(maxWidth: 240, alignment: .leading)
        }
        Note(text: "Transcripts are made on this Mac.\nNo audio or text is sent anywhere.")
    }

    private func languageName(_ code: String) -> String {
        code == "auto" ? "Detect automatically" : Locale.current.localizedString(forLanguageCode: code) ?? code
    }
}

/// One model in the card: its name and size, what it is good for, its download state and a "..." menu.
private struct ModelRow: View {
    let store: ModelStore
    let model: WhisperModel
    let selected: Bool
    let select: () -> Void

    private var name: String { model == .largeV3 ? "Large v3 (\(model.sizeText))" : "Turbo (\(model.sizeText))" }
    private var blurb: String { model == .largeV3 ? "Higher accuracy. Better for longer recordings." : "Faster, smaller. Good for everyday use." }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.callout.weight(.medium))
                Text(blurb).font(.caption).foregroundStyle(.secondary)
                status.font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                switch store.state(model) {
                case .missing: Button("Download") { store.download(model) }
                case .downloading: Button("Cancel Download") { store.cancelDownload(model) }
                case .verifying: Button("Checking...") {}.disabled(true)
                case .installed: Button("Remove", role: .destructive) { store.remove(model) }
                }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("\(name) options")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(selected ? Theme.raised : Color.clear)  // the chosen model is the white row, as in the mockup
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .help(selected ? "The model used for new transcripts" : "Use this model")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction(named: "Use this model", select)
    }

    @ViewBuilder private var status: some View {
        switch store.state(model) {
        case .missing: Text("Not downloaded")
        case .downloading(let value): HStack(spacing: 6) { ProgressView(value: value).frame(width: 120).tint(Theme.accent); Text("\(Int(value * 100))%") }
        case .verifying: Text("Checking the download")
        case .installed: Text("Downloaded")
        }
    }
}

private struct AudioSettings: View {
    @State private var mic = currentMicName() ?? "No microphone"

    var body: some View {
        SettingRow(label: "Microphone") {
            VStack(alignment: .leading, spacing: 6) {
                Text(mic)
                Button("Change in Sound Settings...") { open("x-apple.systempreferences:com.apple.Sound-Settings.extension?input") }
                    .controlSize(.small)
            }
        }
        SettingRow(label: "System audio") { Text("Everything the Mac plays, from every app").foregroundStyle(.secondary) }
        SettingRow(label: "Echo removal") { Text("Automatic: on with speakers, off with headphones").foregroundStyle(.secondary) }
        Note(text: "The mic is the system input. AirPods that are not in a call are left alone: the built-in mic is used, so they keep full sound quality.")
            .onAppear { mic = currentMicName() ?? "No microphone" }
    }
}

private struct GeneralSettings: View {
    @AppStorage("showMenuBar") private var showMenuBar = true

    var body: some View {
        SettingRow(label: "Menu bar") {
            Toggle("Show Kagu in the menu bar", isOn: $showMenuBar).toggleStyle(.switch).tint(Theme.accent)
        }
        SettingRow(label: "Shortcuts") {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                shortcut("New or stop recording", "⌘N")
                shortcut("Stop recording", "⌘.")
                shortcut("Pause or resume", "⇧⌘P")
                shortcut("Play or pause", "Space")
                shortcut("Search", "⌘F")
                shortcut("Transcribe an audio file", "⇧⌘T")
            }
            .font(.callout)
        }
    }

    private func shortcut(_ action: String, _ keys: String) -> some View {
        GridRow {
            Text(action)
            Text(keys).foregroundStyle(.secondary)
        }
    }
}

private struct FilesSettings: View {
    let folder: URL
    @State private var used = "Measuring..."

    var body: some View {
        SettingRow(label: "Recordings") {
            VStack(alignment: .leading, spacing: 6) {
                Text(folder.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")).textSelection(.enabled)
                Button("Show in Finder") { NSWorkspace.shared.open(folder) }.controlSize(.small)
            }
        }
        SettingRow(label: "Space used") { Text(used).foregroundStyle(.secondary) }
        SettingRow(label: "In the folder") {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
                layout("<name>.m4a", "the recording")
                layout("<name>.md", "its transcript, next to it")
                layout(".<name>.tracks.m4a", "your mic and the Mac audio apart, hidden")
            }
            .font(.callout)
        }
        Note(text: "Tags are Finder tags, so they show in Finder and Spotlight too. The accession number is written on the file itself and stays with it through a rename.")
            .task { used = await Self.size(of: folder) }
    }

    private func layout(_ name: String, _ what: String) -> some View {
        GridRow {
            Text(name).monospaced().font(.caption).lineLimit(1)
            Text(what).foregroundStyle(.secondary)
        }
    }

    /// Adds up every file in the folder, hidden ones included, off the main thread.
    private static func size(of folder: URL) async -> String {
        await Task.detached(priority: .utility) {
            let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey])
            var total: Int64 = 0
            while let url = files?.nextObject() as? URL { total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        }.value
    }
}

private struct PrivacySettings: View {
    @State private var mic = AVCaptureDevice.authorizationStatus(for: .audio)

    var body: some View {
        SettingRow(label: "Microphone") {
            Label(micText, systemImage: mic == .authorized ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(mic == .authorized ? Color.green : .orange)
        }
        SettingRow(label: "System audio") {
            Text("Asked on the first recording; changed in Screen & System Audio Recording").foregroundStyle(.secondary)
        }
        SettingRow(label: "") {
            Button("Open Privacy Settings...") { open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") }.controlSize(.small)
        }
        Note(text: "Recordings, transcripts and the speech model stay on this Mac. Kagu sends no recording or transcript anywhere; the only download is the speech model, when you ask for it.", icon: "lock")
            .onAppear { mic = AVCaptureDevice.authorizationStatus(for: .audio) }
    }

    private var micText: String {
        switch mic {
        case .authorized: "Allowed"
        case .notDetermined: "Asked on the first recording"
        default: "Not allowed"
        }
    }
}

private func open(_ link: String) {
    if let url = URL(string: link) { NSWorkspace.shared.open(url) }
}
