import SwiftUI

/// The top of the Transcript tab: the summary the transcript file holds, or, while it has none and this Mac can
/// make one, the Summarize button with its progress. Nothing at all where the model is not available.
struct SummaryView: View {
    let item: RecordingItem
    let blocks: [Transcript.Block]
    let summaries: Summarizer

    var body: some View {
        if let parts = Summary.parts(in: item.transcriptText) {
            card(parts)
        } else if Summary.isAvailable, Summary.worthIt(blocks) {
            control
        }
    }

    // MARK: Card

    private func card(_ parts: Summary.Parts) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            section("Summary") { Text(parts.summary).fixedSize(horizontal: false, vertical: true) }
            if !parts.decisions.isEmpty { section("Decisions") { bullets(parts.decisions) } }
            if !parts.actions.isEmpty { section("Action items") { bullets(parts.actions) } }
            Text(Summary.disclaimer).font(.footnote).foregroundStyle(.secondary)
        }
        .font(Theme.body)
        .lineSpacing(3)
        .textSelection(.enabled)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
        .padding(.bottom, 6)
    }

    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout.weight(.semibold)).accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func bullets(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, text in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\u{2022}").foregroundStyle(.secondary).accessibilityHidden(true)
                    Text(text).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Making one

    @ViewBuilder private var control: some View {
        switch summaries.states[item.url] {
        case nil:
            HStack(spacing: 12) {
                Button { summaries.request(item.url, manual: true) } label: { Label("Summarize", systemImage: "text.alignleft") }
                    .buttonStyle(QuietButtonStyle())
                Text("Summary, decisions and action items.").font(.callout).foregroundStyle(.secondary)
            }
        case .waiting:
            progress(nil, summaries.shouldPause() ? "Waiting for the recording to finish" : "Waiting for another summary")
        case .running(let value):
            progress(value > 0 ? value : nil, value > 0 ? "Summarizing \(Int(value * 100))%" : "Summarizing")
        case .failed(let text):
            HStack(spacing: 12) {
                Label(text, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor).font(.callout)
                Button("Try Again") { summaries.cancel(item.url); summaries.request(item.url, manual: true) }
            }
        }
    }

    private func progress(_ value: Double?, _ label: String) -> some View {
        HStack(spacing: 12) {
            if let value { ProgressView(value: value).frame(width: 220).tint(Theme.accent) } else { ProgressView().controlSize(.small) }
            Text(label).font(.callout)
            Button("Cancel") { summaries.cancel(item.url) }.buttonStyle(.borderless)
        }
    }
}
