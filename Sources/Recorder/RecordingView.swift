import AppKit
import SwiftUI

/// The small dark "Recording" window: it opens when a recording starts and closes when it is saved.
@MainActor
final class RecordingWindow {
    private var window: NSWindow?

    func show(model: Recorder) {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 300), styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.title = "Recording"
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = NSColor(srgbRed: 0.11, green: 0.11, blue: 0.11, alpha: 1)
            window.contentView = NSHostingView(rootView: RecordingView(model: model))
            window.setFrameAutosaveName("RecordingWindow")
            if !window.setFrameUsingName("RecordingWindow") { window.center() }
            self.window = window
        }
        window?.orderFrontRegardless()
    }

    func close() { window?.close() }
}

/// Timer, a moving waveform, Pause, Stop and the way back to the library.
struct RecordingView: View {
    let model: Recorder

    var body: some View {
        VStack(spacing: 14) {
            Text(clock(model.elapsed))
                .font(.system(size: 44, weight: .light, design: .default).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.top, 30)
                .accessibilityLabel("Recorded \(spoken(model.elapsed))")
            HistoryBars(levels: model.levelHistory, paused: model.isPaused)
                .frame(height: 46)
                .padding(.horizontal, 22)
                .accessibilityHidden(true)
            VStack(spacing: 2) {
                Text(model.state == .saving ? "Saving..." : model.isPaused ? "Paused" : "Recording...")
                    .font(.callout).foregroundStyle(.white.opacity(0.85))
                Text(model.isPaused ? "Nothing is recorded. The mic stays open." : "Microphone + System Audio")
                    .font(.caption).foregroundStyle(.white.opacity(0.55))
                if let warning = model.warning {
                    Text(warning).font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center).padding(.top, 2)
                }
            }
            HStack(spacing: 26) {
                ring(model.isPaused ? "play.fill" : "pause.fill", label: model.isPaused ? "Resume" : "Pause", action: model.togglePause)
                Button(action: model.toggle) {
                    ZStack {
                        Circle().fill(Theme.accent)
                        RoundedRectangle(cornerRadius: 4).fill(.white).frame(width: 18, height: 18)
                    }
                    .frame(width: 56, height: 56)
                }
                .buttonStyle(PressStyle())
                .disabled(model.state != .recording)
                .help("Stop and save (⌘.)")
                .accessibilityLabel("Stop recording")
                ring("waveform", label: "Show Recordings") { model.openMainWindow?(); NSApp.activate() }
            }
            .padding(.bottom, 22)
        }
        .frame(width: 340, height: 300)
        .background(Color(white: 0.11))
        .environment(\.colorScheme, .dark)
    }

    private func ring(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1.5))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .disabled(model.state != .recording)
        .help(label)
        .accessibilityLabel(label)
    }

    private func clock(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }
}

/// Recorded levels in red from the left, the rest of the line in grey; all grey while paused.
private struct HistoryBars: View {
    let levels: [Float]
    let paused: Bool

    var body: some View {
        Canvas { context, size in
            let slots = 56
            let filled = Int(Double(slots) * 0.62)  // where the newest bar sits
            let slot = size.width / CGFloat(slots)
            let recent = Array(levels.suffix(filled))
            for i in 0..<slots {
                let index = i - (filled - recent.count)
                let level: CGFloat
                if i < filled, index >= 0 {
                    let value = recent[index]
                    let db = value > 0 ? CGFloat(min(1, max(0, (20 * log10(value) + 60) / 60))) : 0
                    level = max(0.06, pow(db, 2.2))  // a curve, so speech shows peaks and dips instead of a flat top
                } else {
                    level = 0.1 + 0.08 * CGFloat(abs(sin(Double(i) * 1.7)))  // the quiet rest of the line
                }
                let height = max(3, level * size.height)
                let rect = CGRect(x: CGFloat(i) * slot + slot * 0.25, y: (size.height - height) / 2, width: slot * 0.5, height: height)
                let red = i < filled && index >= 0 && !paused
                context.fill(Path(roundedRect: rect, cornerRadius: slot * 0.25), with: .color(red ? Theme.accent : Color.white.opacity(0.28)))
            }
        }
    }
}
