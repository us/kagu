import AppKit
import SwiftUI

/// The design tokens: warm off white in light, near black in dark, one red.
enum Theme {
    static let canvas = dynamic(light: 0xFAF8F5, dark: 0x1E1E1E)
    static let sidebar = dynamic(light: 0xF1EEEA, dark: 0x262626)
    static let card = dynamic(light: 0xECE9E4, dark: 0x2C2C2C)
    static let line = dynamic(light: 0xE2DED8, dark: 0x3A3A3A)
    static let accent = dynamic(light: 0xEF4136, dark: 0xF0473C)
    static let you = dynamic(light: 0x2F6FE4, dark: 0x5B9BFF)
    static let selection = dynamic(light: 0xEF4136, dark: 0xF0473C, alpha: (0.14, 0.24))
    static let raised = dynamic(light: 0xFFFFFF, dark: 0x3A3A3A)  // the round play button

    static let title = Font.system(size: 28, weight: .bold)
    static let body = Font.system(size: 14)

    /// Finder's tag colors, by the number Finder writes next to a tag's name, in the order its menu shows them.
    static let tagColors: [(number: Int, color: Color)] = [(6, .red), (7, .orange), (5, .yellow), (2, .green), (4, .blue), (3, .purple), (1, .gray)]
    static func tagColor(_ number: Int?) -> Color? { tagColors.first { $0.number == number }?.color }

    private static func dynamic(light: UInt32, dark: UInt32, alpha: (Double, Double) = (1, 1)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: isDark ? alpha.1 : alpha.0)
        })
    }
}

/// A rounded search field like the mockup's: magnifier, placeholder, a clear button while it has text.
struct SearchField: View {
    let prompt: String
    @Binding var text: String
    var focus: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).imageScale(.small)
            TextField(prompt, text: $text).textFieldStyle(.plain).focused(focus)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear search")
            }
        }
        .font(.callout)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
    }
}

/// The bordered header buttons (Copy, Export...): quiet, with an icon.
struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.raised.opacity(configuration.isPressed ? 0.6 : 1)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.line))
    }
}

/// The filled red header button (Transcribe).
struct AccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.accent.opacity(configuration.isPressed ? 0.75 : 1)))
    }
}
