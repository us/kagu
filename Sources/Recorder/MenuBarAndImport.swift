import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The menu bar item's menu: record, stop, the windows, Settings, Quit.
struct MenuBarMenu: View {
    let model: Recorder
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button { Task { await model.start() } } label: { Label { Text("New Recording") } icon: { Image(nsImage: Self.redDot) } }
            .keyboardShortcut("n")
            .disabled(model.state != .idle)
        Button { model.stop() } label: { Label("Stop Recording", systemImage: "stop.fill") }
            .keyboardShortcut(".")
            .disabled(model.state != .recording)
        Divider()
        Button { show("main") } label: { Label("Show App", systemImage: "macwindow") }
        Button { show("import") } label: { Label("Transcribe Audio File...", systemImage: "waveform") }
        Divider()
        Button {
            openSettings()
            NSApp.activate()
        } label: { Label("Settings...", systemImage: "gearshape") }
            .keyboardShortcut(",")
        Divider()
        Button { NSApp.terminate(nil) } label: { Label("Quit Kagu", systemImage: "power") }
            .keyboardShortcut("q")
        Divider()
        Text(footer)
    }

    /// "On the record 00:41:12." while recording, else what the register holds: "On file: 43 entries, 61 h 24 min. 1 withdrawn."
    private var footer: String {
        if model.state == .recording { return "On the record \(Transcript.clock(model.elapsed))." }
        let items = model.library.items
        let minutes = Int(items.reduce(0) { $0 + $1.duration } / 60)
        let hours = "\(minutes / 60) h \(minutes % 60) min"
        // ponytail: a Finder duplicate shares its number and hides one withdrawn; count distinct numbers if that matters.
        let withdrawn = max(0, model.library.register.total - Set(items.compactMap(\.accession)).count)
        return "On file: \(items.count) \(items.count == 1 ? "entry" : "entries"), \(hours)." + (withdrawn > 0 ? " \(withdrawn) withdrawn." : "")
    }

    /// Menus draw symbols in one colour; a non-template image keeps the record dot red, as in the mockup.
    private static let redDot: NSImage = {
        let image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.systemRed])) ?? NSImage()
        image.isTemplate = false
        return image
    }()

    private func show(_ id: String) {
        openWindow(id: id)
        NSApp.activate()
    }
}

/// The menu bar icon. It is always drawn, so it is also where the app learns how to reopen the library window.
struct MenuBarLabel: View {
    let model: Recorder
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: model.state != .recording ? "record.circle" : model.isPaused ? "pause.circle.fill" : "record.circle.fill")
            .accessibilityLabel(model.state != .recording ? "Kagu" : model.isPaused ? "Kagu, paused" : "Kagu, recording")
            .onAppear { model.openMainWindow = { [openWindow] in openWindow(id: "main") } }
    }
}

/// The File menu item that opens the Transcribe Audio File window.
struct ImportCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Transcribe Audio File...") { openWindow(id: "import") }
            .keyboardShortcut("t", modifiers: [.command, .shift])
    }
}

/// Drop an audio file (or choose one) and get a transcript next to it, made on this Mac.
struct ImportView: View {
    let transcriber: Transcriber
    @State private var file: URL?
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 14) {
            Text("Transcribe Audio File").font(.headline).padding(.top, 4)
            VStack(spacing: 12) {
                ZStack {
                    Image(systemName: "doc").font(.system(size: 46, weight: .light))
                    Image(systemName: "waveform").font(.system(size: 15, weight: .medium)).offset(y: 5)
                }
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
                Text("Drag and drop an audio file here\nor choose a file to transcribe.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 150)
            .background(RoundedRectangle(cornerRadius: 12).fill(targeted ? Theme.selection : Theme.card.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(targeted ? Theme.accent : Theme.line))
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first(where: Self.isAudio) else { return false }
                start(url)
                return true
            } isTargeted: { targeted = $0 }
            Button(action: choose) { Text("Choose Audio File...").frame(maxWidth: .infinity) }
                .controlSize(.large)
            Text("Supports MP3, WAV, M4A, AAC, AIFF").font(.caption).foregroundStyle(.secondary)
            if let file { status(file) }
        }
        .padding(18)
        .frame(width: 340)
        .background(Theme.canvas)
    }

    /// What happened to the chosen file: progress, a failure, or where the transcript is.
    @ViewBuilder private func status(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(url.lastPathComponent).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
            if let output = transcriber.finishedElsewhere[url] {
                HStack {
                    Label("Transcript saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([output]) }.controlSize(.small)
                }
            } else {
                switch transcriber.states[url] {
                case .running(let value):
                    HStack { ProgressView(value: value).tint(Theme.accent); Button("Cancel") { transcriber.cancel(url) }.controlSize(.small) }
                case .failed(let text):
                    Label(text, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor).font(.caption).foregroundStyle(.secondary)
                    Button("Try Again") { transcriber.request(url) }.controlSize(.small)
                case .queued, .downloadingModel:
                    HStack { ProgressView().controlSize(.small); Text(transcriber.states[url] == .downloadingModel ? "Downloading the speech model" : "Preparing").font(.caption).foregroundStyle(.secondary) }
                case nil:
                    if Self.hasTranscript(url) {
                        Text("A transcript for this file already exists next to it.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Cancelled.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card.opacity(0.6)))
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.message = "Choose an audio file to transcribe. The transcript is saved next to it."
        if panel.runModal() == .OK, let url = panel.url { start(url) }
    }

    private func start(_ url: URL) {
        file = url
        transcriber.request(url)
    }

    private static func hasTranscript(_ url: URL) -> Bool {
        let stem = url.deletingPathExtension()
        return ["md", "transcript.md"].contains { FileManager.default.fileExists(atPath: stem.appendingPathExtension($0).path) }
    }

    private static func isAudio(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)?.conforms(to: .audio) ?? false
    }
}
