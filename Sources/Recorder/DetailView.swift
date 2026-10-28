import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// What a row's menu asks the recording's page to open: its title field or its tag editor.
struct DetailRequest: Equatable {
    enum Kind { case rename, tag }
    let url: URL
    let kind: Kind
}

/// One recording: an editable title with its actions, tags, the player, and the transcript or its details.
struct DetailView: View {
    let item: RecordingItem
    let model: Recorder
    let player: Player
    @Binding var request: DetailRequest?
    let onRename: (_ old: URL, _ new: URL) -> Void

    enum Tab { case transcript, details }

    @State private var title: String
    @State private var peaks: [Float] = []
    @State private var copied = false
    @State private var tab = CommandLine.arguments.contains("--details") ? Tab.details : .transcript  // `--details` is a test aid
    @State private var query = ""
    @State private var confirmReplace = false
    @State private var editingTitle = false
    @State private var addingTag = false
    @FocusState private var titleFocused: Bool
    @FocusState private var queryFocused: Bool

    /// The library search: its words are marked in the transcript, and the first line with them is scrolled to.
    let hint: String

    init(item: RecordingItem, model: Recorder, player: Player, hint: String = "", request: Binding<DetailRequest?>, onRename: @escaping (_ old: URL, _ new: URL) -> Void) {
        self.item = item
        self.hint = hint.trimmingCharacters(in: .whitespaces)
        self.model = model
        self.player = player
        _request = request
        self.onRename = onRename
        _title = State(initialValue: item.displayTitle)
        blocks = Transcript.parse(item.transcriptText)  // once per update, not once per place that shows it
    }

    private var transcriber: Transcriber { model.transcriber }
    private let blocks: [Transcript.Block]
    private var shownBlocks: [(offset: Int, element: Transcript.Block)] {
        let all = Array(blocks.enumerated())
        guard !query.isEmpty else { return all }
        return all.filter { $0.element.text.localizedCaseInsensitiveContains(query) || $0.element.speaker.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                header
                PlayerBar(player: player, peaks: peaks)
                tabs
            }
            .padding(.horizontal, 32)
            .padding(.top, 10)
            ScrollViewReader { proxy in
                ScrollView {
                    Group {
                        switch tab {
                        case .transcript: transcript
                        case .details: DetailsTable(item: item, folder: model.library.folder)
                        }
                    }
                    .padding(.horizontal, 32)
                    .padding(.top, 18)
                    .padding(.bottom, 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .task(id: hint) {
                    try? await Task.sleep(for: .milliseconds(300))  // after typing settles, and after the lines are laid out
                    guard !Task.isCancelled, !hint.isEmpty, query.isEmpty,
                          let first = blocks.firstIndex(where: { $0.text.range(of: hint, options: [.caseInsensitive, .diacriticInsensitive]) != nil }) else { return }
                    proxy.scrollTo(first, anchor: .top)
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .confirmationDialog("Replace the transcript?", isPresented: $confirmReplace) {
            Button("Transcribe Again") { transcribeAgain() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current transcript goes to the Trash and a new one is made with the model chosen in Settings.")
        }
        .onChange(of: request, initial: true) { _, request in
            guard let request, request.url == item.url else { return }
            self.request = nil
            switch request.kind {
            case .rename: editingTitle = true
            case .tag: addingTag = true
            }
        }
        .task {
            player.load(item.url)
            peaks = await Waveform.peaks(url: item.url, count: 130)
        }
        .onDisappear {
            // Another row was clicked while the title was being edited: keep the new name.
            if title.normalizedSpaces != item.displayTitle.normalizedSpaces, FileManager.default.fileExists(atPath: item.url.path) { commitTitle() }
            player.unload(item.url)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The actions sit next to the title when both fit, else under it, so the title is never cut short.
            // One layout for both, so the title field is never rebuilt (and loses its focus) on a resize.
            TitleAndActions {
                titleRow
                actions.fixedSize()
            }
            Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            TagBar(item: item, library: model.library, adding: $addingTag)
        }
    }

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 10) {
            // The title is text; a click, the pencil or Rename puts a field over it, sized by the text, so the
            // pencil sits right after it. A field left on screen kept a height it once measured wrong (15 pt for
            // the 28 pt title, the lower half of the title cut off), so the field is only there while editing.
            Text(title.isEmpty ? "Title" : title)
                .font(Theme.title)
                .lineLimit(1)
                .padding(.trailing, 10)  // the text field draws a few points wider than the text
                .opacity(editingTitle ? 0 : 1)
                .onTapGesture { editingTitle = true }
                .accessibilityHidden(editingTitle)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Press to rename")
                .accessibilityAction { editingTitle = true }
                .overlay(alignment: .leading) {
                    if editingTitle {
                        TextField("Title", text: $title)
                            .textFieldStyle(.plain)
                            .font(Theme.title)
                            .focused($titleFocused)
                            .onAppear { Task { @MainActor in titleFocused = true } }  // after the field is in the window, and after a menu closes
                            .onSubmit { titleFocused = false }
                            .accessibilityHint("Edit and press Return to rename")
                            .onChange(of: titleFocused) { _, focused in
                                guard !focused else { return }
                                editingTitle = false
                                commitTitle()
                            }
                    }
                }
                .clipped()
            Button { editingTitle = true } label: { Image(systemName: "pencil") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Rename").accessibilityLabel("Rename")
        }
    }

    /// "October 21, 2026 at 5:07 PM  ·  27:23  ·  ~/Music/Recordings"
    private var subtitle: String {
        let folder = item.url.deletingLastPathComponent().path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
        return "\(item.date.formatted(date: .long, time: .shortened))   ·   \(duration(item.duration))   ·   \(folder)"
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if !blocks.isEmpty {
                Button(action: copy) { Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") }
                    .buttonStyle(QuietButtonStyle())
                    .help("Copy the transcript with speakers and times")
            }
            transcribeButton
            Menu {
                if !blocks.isEmpty {
                    Button("Transcript as Markdown...") { export(.transcriptMarkdown) }
                    Button("Transcript as Text...") { export(.transcriptText) }
                    Divider()
                }
                Button("Audio (.m4a)...") { export(.audio) }
            } label: {
                Label("Export...", systemImage: "square.and.arrow.up")
            }
            .menuStyle(.button)
            .buttonStyle(QuietButtonStyle())
            .menuIndicator(.hidden)
            .fixedSize()
            Menu {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                Button("Rename") { editingTitle = true }
                Divider()
                Button("Move to Trash") {
                    transcriber.cancel(item.url)  // a job for a recording that is going away would only leave an orphan transcript
                    model.library.trash(item)
                }
            } label: {
                Image(systemName: "ellipsis").frame(width: 14)
            }
            .menuStyle(.button)
            .buttonStyle(QuietButtonStyle())
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More")
        }
        .labelStyle(.titleAndIcon)
    }

    @ViewBuilder private var transcribeButton: some View {
        switch transcriber.states[item.url] {
        case .running, .queued, .downloadingModel:
            Button {} label: { Label("Transcribing", systemImage: "asterisk") }
                .buttonStyle(AccentButtonStyle()).disabled(true).opacity(0.7)
        default:
            Button {
                if item.transcript != nil { confirmReplace = true } else { transcriber.request(item.url) }
            } label: { Label("Transcribe", systemImage: "asterisk") }
                .buttonStyle(AccentButtonStyle())
                .help(item.transcript != nil ? "Make a new transcript" : "Make a text version on this Mac")
        }
    }

    // MARK: Tabs

    private var tabs: some View {
        HStack(alignment: .center, spacing: 22) {
            tabButton("Transcript", .transcript).fixedSize()  // the tabs keep their width; the search field gives way
            tabButton("Details", .details).fixedSize()
            Spacer(minLength: 12)
            if tab == .transcript && !blocks.isEmpty {
                SearchField(prompt: "Search transcript...", text: $query, focus: $queryFocused).frame(minWidth: 140, maxWidth: 260)
            }
        }
        .frame(height: 34)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func tabButton(_ label: String, _ value: Tab) -> some View {
        Button { tab = value } label: {
            Text(label)
                .font(.callout.weight(tab == value ? .semibold : .regular))
                .foregroundStyle(tab == value ? Color.primary : .secondary)
                .padding(.horizontal, 6)
                .frame(maxHeight: .infinity)
                .overlay(alignment: .bottom) { Rectangle().fill(tab == value ? Theme.accent : .clear).frame(height: 2) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(tab == value ? .isSelected : [])
    }

    // MARK: Transcript

    @ViewBuilder private var transcript: some View {
        if !blocks.isEmpty {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(shownBlocks, id: \.offset) { _, block in
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Button(duration(block.seconds)) {
                            player.seek(to: block.seconds)
                            if !player.isPlaying { player.toggle() }
                        }
                            .buttonStyle(.plain)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(width: 58, alignment: .leading)
                            .help("Play from here")
                            .accessibilityLabel("Play from \(spoken(block.seconds))")
                        Text(block.speaker)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(block.speaker == "You" ? Theme.you : Color.primary)
                            .frame(width: 70, alignment: .leading)
                        Text(highlighted(block.text))
                            .font(Theme.body)
                            .lineSpacing(4)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if shownBlocks.isEmpty { Text("No lines contain \u{201C}\(query)\u{201D}.").foregroundStyle(.secondary) }
                if query.isEmpty { footnote }
            }
            .frame(maxWidth: 760, alignment: .leading)
        } else if item.transcript != nil {
            VStack(alignment: .leading, spacing: 18) {
                Text("No speech found.").foregroundStyle(.secondary)
                footnote
            }
        } else {
            TranscribeControl(item: item, transcriber: transcriber)
        }
    }

    /// What the cleaning took out, as the transcript file records it at its foot.
    @ViewBuilder private var footnote: some View {
        if let note = Transcript.footnote(item.transcriptText) {
            Text(note)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
                .overlay(alignment: .topLeading) { Rectangle().fill(Theme.line).frame(width: 120, height: 1) }
                .padding(.leading, 128)  // under the text column, past the time and speaker columns
        }
    }

    /// The search words get a soft red mark.
    private func highlighted(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        let mark = query.isEmpty ? hint : query
        guard !mark.isEmpty else { return result }
        var searchFrom = result.startIndex
        while let range = result[searchFrom...].range(of: mark, options: [.caseInsensitive, .diacriticInsensitive]) {
            result[range].backgroundColor = Theme.accent.opacity(0.22)
            searchFrom = range.upperBound
        }
        return result
    }

    // MARK: Actions

    private func commitTitle() {
        guard !model.library.trashing.contains(item.url) else { return }  // on its way to the Trash: nothing to rename
        // Unchanged, also when it only differs by what a file name drops ("Meeting ", "Meeting.m4a").
        guard title.trimmingCharacters(in: .whitespacesAndNewlines).normalizedSpaces != item.displayTitle.normalizedSpaces,
              Library.cleanName(title) != item.stem else { return title = item.displayTitle }
        guard let url = model.library.rename(item, to: title) else {
            let problem = model.library.moveProblem
            if problem != nil { model.library.moveProblem = nil }
            // An empty name, or one made only of what a file name cannot hold, is no rename at all.
            if problem != nil || !Library.cleanName(title).isEmpty { model.show(problem ?? "Could not rename \(item.displayTitle).") }
            return title = item.displayTitle
        }
        onRename(item.url, url)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Transcript.plainText(title: item.displayTitle, date: item.date, blocks: blocks), forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    /// The old transcript goes to the Trash (recoverable), then the normal Transcribe path makes a new one.
    private func transcribeAgain() {
        guard let old = item.transcript else { return }
        do {
            try FileManager.default.trashItem(at: old, resultingItemURL: nil)
        } catch {
            return model.show("Could not move the old transcript to the Trash: \(error.localizedDescription)")
        }
        transcriber.request(item.url)
        model.library.reload()
    }

    enum Export { case transcriptMarkdown, transcriptText, audio }

    private func export(_ kind: Export) {
        let panel = NSSavePanel()
        let name = item.displayTitle.replacingOccurrences(of: ":", with: ".")
        switch kind {
        case .transcriptMarkdown: panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]; panel.nameFieldStringValue = name + ".md"
        case .transcriptText: panel.allowedContentTypes = [.plainText]; panel.nameFieldStringValue = name + ".txt"
        case .audio: panel.allowedContentTypes = [.mpeg4Audio]; panel.nameFieldStringValue = name + ".m4a"
        }
        guard panel.runModal() == .OK, let target = panel.url else { return }
        do {
            switch kind {
            case .transcriptMarkdown: try item.transcriptText.write(to: target, atomically: true, encoding: .utf8)
            case .transcriptText: try Transcript.plainText(title: item.displayTitle, date: item.date, blocks: blocks).write(to: target, atomically: true, encoding: .utf8)
            case .audio:
                // Exporting onto the recording itself would delete it before the copy: nothing to do then.
                guard target.standardizedFileURL.resolvingSymlinksInPath() != item.url.standardizedFileURL.resolvingSymlinksInPath() else { return }
                // A copy next to the target first, then a swap: a failed copy leaves the file that was there.
                let copy = target.deletingLastPathComponent().appending(path: ".\(UUID().uuidString).m4a")
                try FileManager.default.copyItem(at: item.url, to: copy)
                Register.clear(copy)
                do {
                    if FileManager.default.fileExists(atPath: target.path) { _ = try FileManager.default.replaceItemAt(target, withItemAt: copy, options: .usingNewMetadataOnly) } else { try FileManager.default.moveItem(at: copy, to: target) }
                } catch {
                    try? FileManager.default.removeItem(at: copy)
                    throw error
                }
            }
        } catch {
            model.show("Export failed: \(error.localizedDescription)")
        }
    }
}

/// Two children: the title at the leading edge and the actions at the trailing edge on one line when both fit,
/// else the actions on a line of their own under the title.
private struct TitleAndActions: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let width = proposal.width ?? .infinity
        let title = subviews[0].sizeThatFits(.unspecified), actions = subviews[1].sizeThatFits(.unspecified)
        if title.width + 16 + actions.width <= width { return CGSize(width: proposal.width ?? title.width + 16 + actions.width, height: max(title.height, actions.height)) }
        let wrapped = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: proposal.width ?? max(wrapped.width, actions.width), height: wrapped.height + 10 + actions.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let title = subviews[0].sizeThatFits(.unspecified), actions = subviews[1].sizeThatFits(.unspecified)
        if title.width + 16 + actions.width <= bounds.width {
            let height = max(title.height, actions.height)
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY + (height - title.height) / 2), proposal: ProposedViewSize(title))
            subviews[1].place(at: CGPoint(x: bounds.maxX - actions.width, y: bounds.minY + (height - actions.height) / 2), proposal: ProposedViewSize(actions))
        } else {
            let wrapped = subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: wrapped.height))
            subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + wrapped.height + 10), proposal: ProposedViewSize(actions))
        }
    }
}

/// The Details tab: facts read from the files, nothing made up.
private struct DetailsTable: View {
    let item: RecordingItem
    let folder: URL
    @State private var format = ""
    @State private var size = ""
    @State private var transcriptSize = ""
    @State private var model = ""

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 24, verticalSpacing: 10) {
            if let number = item.accession { row("Accession", number) }
            parts
            row("Folder", item.url.deletingLastPathComponent().path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
            row("Recorded", item.date.formatted(date: .complete, time: .standard))
            row("Duration", duration(item.duration))
            row("Size", size)
            row("Audio", format)
            row("Speakers", FileManager.default.fileExists(atPath: item.sidecar.path) ? "You and Them kept apart (mic and Mac audio)" : "One mixed track")
            row("Transcript", item.transcript?.lastPathComponent ?? "None yet")
            if !model.isEmpty { row("Made with", model) }
            row("Tags", item.tags.isEmpty ? "None" : item.tags.joined(separator: ", "))
        }
        .font(.callout)
        .textSelection(.enabled)
        .task(id: item.url) { load() }
    }

    /// The files the recording is made of, numbered as parts of its entry: the audio, the transcript, the two
    /// tracks kept apart. The tracks file is hidden in Finder, so it is the one part not on view.
    @ViewBuilder private var parts: some View {
        let number = item.accession.map { $0 + "." } ?? ""
        GridRow {
            Text("Parts").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
                part("\(number)1", item.url, size)
                if let transcript = item.transcript { part("\(number)2", transcript, transcriptSize) }
                if FileManager.default.fileExists(atPath: item.sidecar.path) {
                    GridRow {
                        Text("\(number)3").monospacedDigit().foregroundStyle(.secondary)
                        Text(item.sidecar.lastPathComponent).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Text("not on view").foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private func part(_ number: String, _ url: URL, _ size: String) -> some View {
        GridRow {
            Text(number).monospacedDigit().foregroundStyle(.secondary)
            Button(url.lastPathComponent) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                .buttonStyle(.plain).lineLimit(1).truncationMode(.middle).help("Show in Finder")
            Text(size).foregroundStyle(.secondary)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value)
        }
    }

    private func load() {
        func bytes(_ url: URL?) -> String {
            guard let n = url.flatMap({ try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }) else { return "" }
            return ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
        }
        size = bytes(item.url)
        transcriptSize = bytes(item.transcript)
        if let file = try? AVAudioFile(forReading: item.url) {
            let f = file.fileFormat
            let codec = f.settings[AVFormatIDKey] as? UInt32 == kAudioFormatMPEG4AAC ? "AAC" : "PCM"
            format = "\(codec), \(Int(f.sampleRate / 1000)) kHz, \(f.channelCount == 2 ? "stereo" : "\(f.channelCount) channels")"
        }
        // The second line of a transcript names the model, for example "Large v3 turbo, ... transcribed Oct 21".
        model = item.transcriptText.split(separator: "\n", omittingEmptySubsequences: true).dropFirst().first.map(String.init) ?? ""
    }
}

/// The one button that makes a transcript, and everything that can happen after pressing it.
private struct TranscribeControl: View {
    let item: RecordingItem
    let transcriber: Transcriber

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch transcriber.states[item.url] {
            case nil:
                Text(transcriber.models.state(transcriber.model) == .installed
                     ? "No transcript yet. Transcribe makes a text version on this Mac."
                     : "No transcript yet. The first time, a speech model (\(transcriber.model.sizeText)) is downloaded once.")
                    .font(.callout).foregroundStyle(.secondary)
            case .queued:
                progress(nil, transcriber.shouldPause() ? "Waiting for the recording to finish"
                         : transcriber.isBusyElsewhere(item.url) ? "Waiting for another transcript to finish" : "Preparing")
            case .downloadingModel:
                if case .downloading(let value) = transcriber.models.state(transcriber.model) { progress(value, "Downloading the speech model \(Int(value * 100))%") } else { progress(nil, "Checking the speech model") }
            case .running(let value):
                progress(value > 0 ? value : nil, value > 0 ? "Transcribing \(Int(value * 100))%" : "Transcribing")
            case .failed(let text):
                Label(text, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor).foregroundStyle(.secondary)
                Button("Try Again") { transcriber.request(item.url) }
            }
        }
    }

    private func progress(_ value: Double?, _ label: String) -> some View {
        HStack(spacing: 12) {
            if let value { ProgressView(value: value).frame(width: 220).tint(Theme.accent) } else { ProgressView().controlSize(.small) }
            Text(label).foregroundStyle(.secondary)
            Button("Cancel") { transcriber.cancel(item.url) }.buttonStyle(.borderless)
        }
    }
}

/// Finder tags as small chips, with "Add Tag".
private struct TagBar: View {
    let item: RecordingItem
    let library: Library
    @Binding var adding: Bool

    @State private var draft = ""

    var body: some View {
        Flow(spacing: 6) {  // wraps: many tags in a narrow window stay whole
            ForEach(item.tags, id: \.self) { tag in
                HStack(spacing: 5) {
                    if let color = Theme.tagColor(item.colors[tag]) { Circle().fill(color).frame(width: 8, height: 8) }
                    Text(tag).lineLimit(1)
                }
                .font(.callout)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.card))
                .contextMenu { Button("Remove Tag") { library.setTag(tag, false, for: item.url) } }
                .accessibilityAction(named: "Remove Tag") { library.setTag(tag, false, for: item.url) }
            }
            Button { adding = true } label: { Label("Add Tag", systemImage: "plus").font(.callout) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
                .frame(minHeight: 24)
                .contentShape(Rectangle())
                .popover(isPresented: $adding, arrowEdge: .bottom) { editor }
        }
    }

    private var suggestions: [String] {
        library.allTags.filter { !item.tags.contains($0) && (draft.isEmpty || $0.localizedCaseInsensitiveContains(draft)) }
    }

    private var editor: some View { TagEditor(draft: $draft, suggestions: suggestions, colors: library.tagColors, add: add) }

    private func add(_ name: String) {
        let tag = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty, !item.tags.contains(tag) else { return }
        library.setTag(tag, true, for: item.url)
        draft = ""
        adding = false
    }
}

/// The player card: a round play button, the time, the waveform with a red playhead, the length.
private struct PlayerBar: View {
    let player: Player
    let peaks: [Float]

    var body: some View {
        HStack(spacing: 12) {
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Theme.raised).shadow(color: .black.opacity(0.12), radius: 1.5, y: 0.5))
            }
            .buttonStyle(.plain)
            .help(player.isPlaying ? "Pause (Space)" : "Play (Space)")
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            Text(duration(player.time)).font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(minWidth: 40, alignment: .leading)
            Scrubber(peaks: peaks, progress: player.duration > 0 ? player.time / player.duration : 0) { player.seek(to: $0 * player.duration) }
                .frame(height: 40)
                // For VoiceOver and the keyboard the waveform is a slider: arrow keys move five seconds.
                .accessibilityRepresentation {
                    Slider(value: Binding(get: { player.time }, set: { player.seek(to: $0) }), in: 0...max(player.duration, 1), step: min(5, max(player.duration, 1)))  // a step longer than the range crashes
                        .accessibilityLabel("Playback position")
                        .accessibilityValue("\(spoken(player.time)) of \(spoken(player.duration))")
                }
            Text(duration(player.duration)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card.opacity(0.7)))
    }
}

/// The waveform; a click or a drag moves the red playhead. The last bars fade out, as in the mockup.
private struct Scrubber: View {
    let peaks: [Float]
    let progress: Double
    let seek: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                let count = peaks.isEmpty ? 130 : peaks.count
                let slot = size.width / CGFloat(count)
                for i in 0..<count {
                    let level = peaks.isEmpty ? 0.1 : CGFloat(peaks[i])
                    let height = max(2, level * size.height * 0.9)
                    let rect = CGRect(x: CGFloat(i) * slot + slot * 0.3, y: (size.height - height) / 2, width: max(1.5, slot * 0.4), height: height)
                    let fade = min(1, Double(count - i) / 14)  // the right end fades
                    let played = (Double(i) + 0.5) / Double(count) <= progress
                    context.fill(Path(roundedRect: rect, cornerRadius: slot * 0.25), with: .color(Color.secondary.opacity((played ? 0.95 : 0.6) * fade)))
                }
                let x = CGFloat(progress) * size.width
                context.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)), with: .color(Theme.accent))
                context.fill(Path(ellipseIn: CGRect(x: x - 3.5, y: -1, width: 7, height: 7)), with: .color(Theme.accent))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { seek(min(1, max(0, $0.location.x / geometry.size.width))) })
        }
    }
}

/// The popover's own view, so its text field owns its focus (a focus state of the parent does not reach into a popover).
private struct TagEditor: View {
    @Binding var draft: String
    let suggestions: [String]
    let colors: [String: Int]
    let add: (String) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Tag", text: $draft).textFieldStyle(.roundedBorder).frame(width: 190).focused($focused).onSubmit { add(draft) }
            ForEach(suggestions, id: \.self) { tag in
                Button { add(tag) } label: {
                    HStack(spacing: 5) {
                        if let color = Theme.tagColor(colors[tag]) { Circle().fill(color).frame(width: 8, height: 8) }
                        Text(tag)
                    }
                }
                .buttonStyle(.plain).padding(.vertical, 2)
            }
        }
        .padding(12)
        .onAppear { focused = true }
        .task {
            try? await Task.sleep(for: .milliseconds(150))
            focused = true
        }
    }
}
