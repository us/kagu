import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What the middle column shows: everything, one folder (nil is the Recordings folder itself) or one tag.
enum Scope: Hashable {
    case all
    case folder(String?)
    case tag(String)
}

/// Three columns, like Notes: folders and tags | the recordings in the chosen one | the recording.
struct ContentView: View {
    let model: Recorder

    @State private var selection: URL?
    @State private var search = ""
    @State private var scope = Scope.all
    @State private var columns = NavigationSplitViewVisibility.all
    @State private var renaming: String?  // the folder whose name is being edited
    @State private var draft = ""
    @State private var request: DetailRequest?  // Rename or New Tag from a row's menu, for the recording's page
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool
    @FocusState private var renameFocused: Bool
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    private var library: Library { model.library }
    private var transcriber: Transcriber { model.transcriber }
    private var selectedItem: RecordingItem? { library.items.first { $0.id == selection } }
    /// No recordings and nothing going on: the window is only the welcome screen, like the mockup's empty state.
    /// (A just saved first recording counts too: the folder is read again a moment after it is saved.)
    private var isEmpty: Bool {
        library.loaded && library.items.isEmpty && library.folders.isEmpty && model.state == .idle && model.message == nil && outsideFiles.isEmpty
            && !(model.lastFile.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
    }

    private func inScope(_ item: RecordingItem, _ scope: Scope) -> Bool {
        switch scope {
        case .all: true
        case .folder(let name): item.folder == name
        case .tag(let tag): item.tags.contains(tag)
        }
    }

    private var shown: [RecordingItem] {
        let scoped = library.items.filter { inScope($0, scope) }
        guard !search.isEmpty else { return scoped }
        return scoped.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(search)
                || $0.stem.localizedCaseInsensitiveContains(search)
                || $0.transcriptText.localizedCaseInsensitiveContains(search)
                || $0.tags.contains { $0.localizedCaseInsensitiveContains(search) }
                || $0.accession == search
        }
    }

    private var scopeTitle: String {
        switch scope {
        case .all: "All Recordings"
        case .folder(let name): name ?? "Recordings"
        case .tag(let tag): "#\(tag)"
        }
    }

    /// Today, Yesterday, Previous 7 Days, Previous 30 Days, then months, as in Notes. The list is newest first.
    private func sections(_ shown: [RecordingItem]) -> [(title: String, items: [RecordingItem])] {
        var result: [(title: String, items: [RecordingItem])] = []
        for item in shown {
            let title = Self.section(item.date)
            if let last = result.last, last.title == title { result[result.count - 1].items.append(item) } else { result.append((title, [item])) }
        }
        return result
    }

    private enum Line {
        case title(String)
        case row(RecordingItem, next: URL?)  // next: the recording under it in the same section, for the line between them

        var id: AnyHashable {  // a row by its file, so the scroll proxy finds it by the selection
            switch self {
            case .title(let title): AnyHashable("title " + title)
            case .row(let item, _): AnyHashable(item.id)
            }
        }
    }

    private func lines(_ sections: [(title: String, items: [RecordingItem])]) -> [Line] {
        sections.flatMap { section in
            [Line.title(section.title)] + section.items.indices.map { i in
                .row(section.items[i], next: i + 1 < section.items.count ? section.items[i + 1].id : nil)
            }
        }
    }

    private static func section(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: Date())).day ?? 0
        if days < 7 { return "Previous 7 Days" }
        if days < 30 { return "Previous 30 Days" }
        return date.formatted(.dateTime.month(.wide).year())
    }

    /// Files transcribed from the File menu are not in the library; they get a row of their own while they run.
    private var outsideFiles: [URL] {
        let known = Set(library.items.map(\.url))
        return Set(transcriber.states.keys).union(transcriber.finishedElsewhere.keys).filter { !known.contains($0) }.sorted { $0.path < $1.path }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            sidebar
                .frame(minWidth: 220)
                .navigationSplitViewColumnWidth(220)  // fixed: a saved narrower width would cut the folder names
                .toolbar(removing: .sidebarToggle)
        } content: {
            list
                .frame(minWidth: 290)
                .navigationSplitViewColumnWidth(min: 290, ideal: 310, max: 400)
        } detail: {
            Group {
                if isEmpty {
                    EmptyLibrary(model: model)
                } else if let item = selectedItem {
                    // Only while it is still the one shown: a title committed as another row is clicked must not pull the selection back.
                    DetailView(item: item, model: model, player: model.player, hint: search, request: $request) { old, new in if selection == old { selection = new } }.id(item.id)
                } else {
                    ContentUnavailableView("Select a Recording", systemImage: "waveform")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.canvas)
        }
        .navigationTitle(selectedItem?.displayTitle ?? "Recordings")
        .toolbar(removing: .title)  // the recording's own title is already large in the detail pane
        .toolbarBackground(.hidden, for: .windowToolbar)
        .frame(minWidth: 960, minHeight: 520)
        // Space plays wherever the focus is (the list after a click, the detail), except in a text field.
        .onKeyPress(.space) {
            if NSApp.keyWindow?.firstResponder is NSText || !model.player.isLoaded { return .ignored }
            model.player.toggle()
            return .handled
        }
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            if !press.modifiers.isEmpty || NSApp.keyWindow?.firstResponder is NSText || !model.player.isLoaded { return .ignored }
            model.player.skip(press.key == .leftArrow ? -15 : 15)
            return .handled
        }
        .onAppear {
            columns = isEmpty ? .detailOnly : .all
            model.openMainWindow = { [openWindow] in openWindow(id: "main") }
            // Test aids: `--select <file name>` opens that recording, `--search <text>` fills the search box, `--settings` opens Settings, `--import` the Transcribe Audio File window, `--folder <name>` shows one folder.
            if let i = CommandLine.arguments.firstIndex(of: "--search"), i + 1 < CommandLine.arguments.count {
                search = CommandLine.arguments[i + 1]
            }
            if CommandLine.arguments.contains("--settings") { openSettings() }
            if CommandLine.arguments.contains("--import") { openWindow(id: "import") }
            if let i = CommandLine.arguments.firstIndex(of: "--folder"), i + 1 < CommandLine.arguments.count {
                scope = .folder(CommandLine.arguments[i + 1])
            }
            if let i = CommandLine.arguments.firstIndex(of: "--select"), i + 1 < CommandLine.arguments.count {
                selection = library.folder.appending(path: CommandLine.arguments[i + 1])
            }
        }
        .onChange(of: isEmpty) { _, empty in columns = empty ? .detailOnly : .all }
        .onChange(of: library.allTags) { _, tags in if case .tag(let chosen) = scope, !tags.contains(chosen) { scope = .all } }
        .onChange(of: selection) { _, new in if request?.url != new { request = nil } }  // a request left over must not fire on a later visit
        .onChange(of: library.folders) { _, folders in if case .folder(let name?) = scope, !folders.contains(name) { scope = .all } }
        .onChange(of: model.lastFile) { _, file in
            library.reload()
            guard let file else { return }
            if case .folder(let name?) = scope, file.deletingLastPathComponent().lastPathComponent != name { scope = .all }  // a new recording is in Recordings
            if case .tag = scope { scope = .all }
            selection = file
        }
        // Another folder, tag or search: what was selected may not be in the list any more. As in Notes, the first one shown is.
        .onChange(of: scope) { keepSelectionShown() }
        .onChange(of: search) { keepSelectionShown() }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button(action: newFolder) { Image(systemName: "folder.badge.plus").font(.system(size: 14)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 24)
                    .contentShape(Rectangle())
                    .help("New Folder")
                    .accessibilityLabel("New Folder")
            }
            .padding(.horizontal, 10)
            .padding(.top, 2)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    SidebarHeader(title: "Library")
                    SourceRow(icon: "tray.full", title: "All Recordings", count: library.items.count, selected: scope == .all) { scope = .all }
                    folderRow(nil)
                    ForEach(library.folders, id: \.self) { folderRow($0) }
                    if !library.allTags.isEmpty {
                        SidebarHeader(title: "Tags").padding(.top, 14)
                        TagStrip(tags: library.tagCounts, colors: library.tagColors, selected: Binding(
                            get: { if case .tag(let tag) = scope { tag } else { nil } },
                            set: { scope = $0.map(Scope.tag) ?? .all }
                        ))
                        .padding(.horizontal, 8)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
            .scrollContentBackground(.hidden)
            RecordBar(model: model)
        }
        .background(Theme.sidebar)
    }

    /// The Recordings folder (nil) or a subfolder: a drop target, and for a subfolder rename and delete.
    @ViewBuilder private func folderRow(_ name: String?) -> some View {
        let count = library.items.filter { $0.folder == name }.count
        if let name, renaming == name {
            HStack(spacing: 8) {
                Image(systemName: "folder").foregroundStyle(Theme.accent).frame(width: 18)
                TextField("Folder name", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .focused($renameFocused)
                    .onSubmit { finishRename(name) }
                    .onExitCommand { renaming = nil }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .onAppear { renameFocused = true }
            .onChange(of: renameFocused) { _, focused in if !focused, renaming == name { finishRename(name) } }
        } else {
            SourceRow(icon: "folder", title: name ?? "Recordings", count: count, selected: scope == .folder(name)) { scope = .folder(name) }
                .dropDestination(for: String.self) { paths, _ in move(paths.map { URL(fileURLWithPath: $0) }, to: name) }
                .contextMenu {
                    if let name {
                        Button("Rename Folder") { draft = name; renaming = name }
                        Button("Delete Folder") { deleteFolder(name) }
                            .help("Its recordings go back to Recordings")
                    }
                }
        }
    }

    // MARK: List

    private var list: some View {
        let shown = self.shown  // the search runs through every transcript: once per draw
        let sections = sections(shown)
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(scopeTitle).font(.system(size: 17, weight: .bold)).lineLimit(1)
                Text(shown.count == 1 ? "1 recording" : "\(shown.count) recordings").font(.callout).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.top, 6)
            SearchField(prompt: "Search recordings...", text: $search, focus: $searchFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if model.message != nil || model.state != .idle || !outsideFiles.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                if let text = model.message { NoticeRow(text: text, report: model.report, link: model.messageLink, dismiss: model.dismissMessage) }
                                if model.state != .idle { LiveRow(model: model) }
                                ForEach(outsideFiles, id: \.self) { OutsideRow(url: $0, transcriber: transcriber) }
                            }
                            .padding(.horizontal, 8)
                            .padding(.bottom, 10)
                        }
                        // One flat ForEach of titles and rows: with one ForEach per section, a row that changed section (a
                        // rename, or midnight) was never drawn again, and kept showing itself selected.
                        ForEach(lines(sections), id: \.id) { line in
                            switch line {
                            case .title(let title):
                                Text(title).font(.system(size: 15, weight: .bold)).padding(.horizontal, 8).padding(.top, 10).padding(.bottom, 6)
                                    .accessibilityAddTraits(.isHeader)
                            case .row(let item, let next):
                                ListRow(item: item, state: transcriber.states[item.url], selected: item.id == selection, showFolder: !isFolderScope && !library.folders.isEmpty)  // with no folders every row would say Recordings
                                    .contentShape(Rectangle())
                                    .onTapGesture { selection = item.id; listFocused = true }
                                    .accessibilityAction { selection = item.id; listFocused = true }  // VoiceOver and keyboard access select it too
                                    .draggable(item.url.path)  // a path, not the file: a drop outside the app cannot take the audio away from its parts
                                    .contextMenu { rowMenu(item) }
                                if let next, item.id != selection, next != selection {
                                    Rectangle().fill(Theme.line).frame(height: 1).padding(.horizontal, 12)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }
                .scrollContentBackground(.hidden)
                .focusable()
                .focused($listFocused)
                .focusEffectDisabled()
                .onMoveCommand { direction in moveSelection(direction, ids: sections.flatMap { $0.items.map(\.id) }, proxy: proxy) }
                .onDeleteCommand { if let item = selectedItem, shown.contains(where: { $0.id == item.id }) { trash(item) } }
                // Audio files from Finder (a phone recording) land in the folder on screen.
                .dropDestination(for: URL.self) { urls, _ in
                    let audio = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .audio) == true }
                    guard !audio.isEmpty else { return false }
                    if case .folder(let name?) = scope { model.importAudio(audio, into: library.directory(name)) } else { model.importAudio(audio, into: library.folder) }
                    return true
                }
                .overlay {
                    if shown.isEmpty, !search.isEmpty {
                        ContentUnavailableView.search(text: search)
                    } else if shown.isEmpty, model.state == .idle {
                        ContentUnavailableView(isFolderScope ? "Empty Folder" : "No Recordings", systemImage: isFolderScope ? "folder" : "waveform",
                                               description: Text(isFolderScope ? "Drag a recording onto this folder in the sidebar, or use Move to in its menu." : ""))
                    }
                }
            }
        }
        .background(Theme.canvas)
        .background {
            Button("") { searchFocused = true }.keyboardShortcut("f").hidden()  // ⌘F focuses the search field
        }
    }

    private var isFolderScope: Bool { if case .folder = scope { true } else { false } }

    @ViewBuilder private func rowMenu(_ item: RecordingItem) -> some View {
        Button("Rename") { open(item, .rename) }
        if item.transcript == nil, transcriber.states[item.url]?.isFailure ?? true { Button("Transcribe") { transcriber.request(item.url) } }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        Menu("Move to") {
            ForEach([String?.none] + library.folders.map(Optional.some), id: \.self) { name in
                Button(name ?? "Recordings") { _ = move([item.url], to: name) }.disabled(item.folder == name)
            }
            Divider()
            Button("New Folder...") { if let name = library.createFolder() { _ = move([item.url], to: name); draft = name; renaming = name } }
        }
        Divider()
        // Finder's color dots, then every other tag in the library; each one switches on or off.
        ControlGroup {
            ForEach(Theme.tagColors, id: \.number) { tag in
                if let name = Library.colorTagName(tag.number) {
                    Toggle(isOn: tagBinding(item, name)) { Label(name, systemImage: "circle.fill") }.tint(tag.color)
                }
            }
        }
        .controlGroupStyle(.palette)
        Menu("Tags") {
            let colorNames = Set(Theme.tagColors.compactMap { Library.colorTagName($0.number) })
            let others = library.allTags.filter { !colorNames.contains($0) }
            ForEach(others, id: \.self) { tag in Toggle(tag, isOn: tagBinding(item, tag)) }
            if !others.isEmpty { Divider() }
            Button("New Tag...") { open(item, .tag) }
        }
        Divider()
        Button("Move to Trash") { trash(item) }
    }

    private func tagBinding(_ item: RecordingItem, _ tag: String) -> Binding<Bool> {
        Binding(get: { item.tags.contains(tag) }, set: { library.setTag(tag, $0, for: item.url) })
    }

    /// Selects the recording and opens its title field or its tag editor on its page.
    private func open(_ item: RecordingItem, _ kind: DetailRequest.Kind) {
        selection = item.id
        request = DetailRequest(url: item.url, kind: kind)
    }

    // MARK: Actions

    /// A folder is renamed or deleted only while nothing writes next to its recordings: the app saving, or a
    /// transcript of one of them. (A recording itself can move: its transcript follows it.)
    private func canChange(_ item: RecordingItem) -> Bool {
        model.state != .saving && (transcriber.states[item.url].map(\.isFailure) ?? true)
    }

    private func move(_ urls: [URL], to name: String?) -> Bool {
        let items = urls.compactMap { url in library.items.first { $0.url.standardizedFileURL == url.standardizedFileURL } }.filter { $0.folder != name }
        guard !items.isEmpty else { return false }
        guard model.state != .saving else {
            model.show("Wait until saving is finished, then move it.")
            return false
        }
        var failed: [String] = []
        library.moveProblem = nil
        for item in items {
            if let url = library.move(item, to: name) {
                if item.id == selection { selection = url }
            } else {
                failed.append(item.displayTitle)
            }
        }
        if let problem = library.moveProblem {
            library.moveProblem = nil
            model.show(problem)
        } else if !failed.isEmpty {
            model.show("Could not move \(failed.joined(separator: ", ")). Nothing was changed.")
        }
        return failed.count < items.count
    }

    private func newFolder() {
        guard let name = library.createFolder() else { return model.show("Could not make a new folder in \(library.folder.path).") }
        draft = name
        renaming = name
        scope = .folder(name)
    }

    private func finishRename(_ name: String) {
        renaming = nil
        guard draft != name else { return }
        guard library.items.filter({ $0.folder == name }).allSatisfy(canChange) else { return model.show("Wait until saving or the transcript is finished, then rename the folder.") }
        if let new = library.renameFolder(name, to: draft) {
            if scope == .folder(name) { scope = .folder(new) }
            if let item = selectedItem, item.folder == name { selection = library.directory(new).appending(path: item.url.lastPathComponent) }
        } else if case let clean = Library.cleanName(draft), !clean.isEmpty, clean != name {  // an emptied or unchanged name keeps the old one
            model.show(FileManager.default.fileExists(atPath: library.folder.appending(path: clean).path)
                ? "A folder called \(clean) already exists." : "A folder cannot be called \(clean).")
        }
    }

    private func deleteFolder(_ name: String) {
        guard library.items.filter({ $0.folder == name }).allSatisfy(canChange) else { return model.show("Wait until saving or the transcript is finished, then delete the folder.") }
        if scope == .folder(name) { scope = .folder(nil) }
        let result = library.deleteFolder(name)
        if let current = selection, let moved = result.moved[current] { selection = moved }
        if let note = result.note { model.show(note) }
    }

    /// Up and down arrows move the selection through the visible rows, like a list.
    private func moveSelection(_ direction: MoveCommandDirection, ids: [URL], proxy: ScrollViewProxy) {
        guard !ids.isEmpty else { return }
        let index = selection.flatMap { ids.firstIndex(of: $0) }
        switch direction {
        case .up: selection = ids[max(0, (index ?? 1) - 1)]
        case .down: selection = ids[min(ids.count - 1, (index ?? -1) + 1)]
        case .left: return model.player.skip(-15)  // as the window's arrow keys, in case the list takes them first
        case .right: return model.player.skip(15)
        default: return
        }
        if let selection { proxy.scrollTo(selection) }
    }

    private func keepSelectionShown() {
        let visible = shown
        if let selection {
            // A selection the library has not read yet (a recording that was just saved) is left alone.
            guard library.items.contains(where: { $0.id == selection }), !visible.contains(where: { $0.id == selection }) else { return }
        }
        selection = visible.first?.id  // also after a search that matched nothing is cleared
    }

    private func trash(_ item: RecordingItem) {
        transcriber.cancel(item.url)  // a job for a recording that is going away would only leave an orphan transcript
        if selection == item.id {
            // The next row takes its place, or the one before at the end, as in Notes and Mail.
            let ids = sections(shown).flatMap { $0.items.map(\.id) }
            let i = ids.firstIndex(of: item.id)
            selection = i.flatMap { ids.indices.contains($0 + 1) ? ids[$0 + 1] : $0 > 0 ? ids[$0 - 1] : nil }
        }
        library.trash(item)
    }
}

// MARK: - Sidebar and list rows

private struct SidebarHeader: View {
    let title: String

    var body: some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A row of the sidebar: an icon, a name, a count; the chosen one is tinted, as in Notes.
private struct SourceRow: View {
    let icon: String
    let title: String
    let count: Int
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(Theme.accent).frame(width: 18)
                Text(title).font(.callout).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(count)").font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Theme.selection : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A recording in the list, like a note: the title, then the time or date and the first words, then its folder.
private struct ListRow: View {
    let item: RecordingItem
    let state: Transcriber.State?
    let selected: Bool
    let showFolder: Bool
    @Environment(\.colorScheme) private var scheme

    private var solid: Bool { selected && scheme == .dark }
    private var secondary: Color { solid ? Color.white.opacity(0.8) : .secondary }

    private var when: String {
        Calendar.current.isDateInToday(item.date) ? item.date.formatted(date: .omitted, time: .shortened)
            : Calendar.current.isDate(item.date, equalTo: Date(), toGranularity: .weekOfYear) ? item.date.formatted(.dateTime.weekday(.wide))
            : item.date.formatted(date: .numeric, time: .omitted)
    }

    /// What the label leaves out: when, the transcript state, the folder and the tags.
    private var spokenState: String {
        let status: String? = switch state {
        case .queued, .downloadingModel: "preparing a transcript"
        case .running(let value): value > 0 ? "transcribing, \(Int(value * 100)) percent" : "transcribing"
        case .failed: "transcript failed"
        case nil: item.transcript != nil ? "transcribed" : nil
        }
        return ([when, status, showFolder ? item.folder ?? "Recordings" : nil] + item.tags).compactMap { $0 }.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.displayTitle).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                Text(duration(item.duration)).font(.caption).monospacedDigit().foregroundStyle(secondary)
            }
            HStack(spacing: 6) {
                Text(when).font(.caption.weight(.medium))
                Text(item.preview).font(.caption).foregroundStyle(secondary).lineLimit(1)
            }
            switch state {
            case .queued, .downloadingModel:
                HStack(spacing: 5) { ProgressView().controlSize(.mini); Text("Preparing") }.font(.caption).foregroundStyle(secondary)
            case .running(let value):
                HStack(spacing: 5) {
                    if value > 0 { ProgressView(value: value).progressViewStyle(.circular).controlSize(.mini) } else { ProgressView().controlSize(.mini) }
                    Text(value > 0 ? "Transcribing \(Int(value * 100))%" : "Transcribing")
                }
                .font(.caption).foregroundStyle(secondary)
            case .failed:
                Label("Transcript failed", systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor).font(.caption)
            case nil:
                if showFolder || !item.tags.isEmpty {
                    HStack(spacing: 8) {
                        if showFolder { Label(item.folder ?? "Recordings", systemImage: "folder") }
                        ForEach(item.tags, id: \.self) { tag in
                            HStack(spacing: 3) {
                                if let color = Theme.tagColor(item.colors[tag]) { Circle().fill(color).frame(width: 7, height: 7) }
                                Text(tag)
                            }
                        }
                    }
                    .font(.caption).foregroundStyle(secondary).lineLimit(1)
                }
            }
        }
        .foregroundStyle(solid ? Color.white : Color.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9).fill(selected ? (solid ? Theme.accent.opacity(0.8) : Theme.selection) : .clear))
        .accessibilityElement(children: .combine)
        .accessibilityValue(spokenState)
        .accessibilityLabel("\(item.displayTitle), \(spoken(item.duration))")
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

/// No recordings yet: a calm welcome with the record button.
private struct EmptyLibrary: View {
    let model: Recorder
    private var register: Register { model.library.register }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform").font(.system(size: 64, weight: .light)).foregroundStyle(.secondary)
            Text("No Recordings Yet").font(.system(size: 30, weight: .bold))
            Text("Click the record button to capture\nyour first conversation.")
                .font(.system(size: 18)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(2)
            RecordButton(model: model, label: "Start Recording", size: 72).padding(.top, 14)
            Text(register.total == 0 ? "Register is empty. Next accession: \(register.next(for: Date()))." : "No entries on file. \(register.total) withdrawn. Next accession: \(register.next(for: Date())).")
                .font(.caption).foregroundStyle(.tertiary).padding(.top, 18)
        }
        .padding(40)
    }
}

/// "1 hour 8 minutes", for VoiceOver.
func spoken(_ seconds: Double) -> String {
    Duration.seconds(seconds.rounded()).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
}

func duration(_ seconds: Double) -> String {
    let s = Int(seconds.rounded())
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

/// While recording (or saving) the list starts with a live row, like Voice Memos.
private struct LiveRow: View {
    let model: Recorder
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(model.state == .saving ? "Saving" : "New Recording").font(.body.weight(.medium)).foregroundStyle(.red)
                Spacer()
                Text(model.isPaused ? "Paused  \(duration(model.elapsed))" : duration(model.elapsed)).font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
            }
            if model.state == .recording {
                TimelineView(.animation(minimumInterval: reduceMotion ? 0.5 : nil)) { context in
                    LiveBars(level: max(model.micLevel, model.systemLevel), time: reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate)
                }
                .frame(height: 14)
                .accessibilityHidden(true)
            } else {
                ProgressView().controlSize(.small)
                if let estimate = model.savingEstimate, let since = model.savingSince {
                    // Redrawn every second, so the line changes once the estimate has passed.
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(context.date.timeIntervalSince(since) <= estimate ? "About \(spoken(estimate))." : "Still saving. The estimate was \(spoken(estimate)).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let warning = model.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { model.showRecordingWindow() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.state == .saving ? "Saving the recording" : "Recording")
        .accessibilityValue(model.warning ?? "")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.showRecordingWindow() }
    }
}

private struct LiveBars: View {
    let level: Float
    let time: Double

    var body: some View {
        // -60 dB to 0 dB mapped to 0 to 1, then a little motion so a steady tone still looks alive.
        let fraction = level > 0 ? CGFloat(min(1, max(0, (20 * log10(level) + 60) / 60))) : 0
        HStack(spacing: 2) {
            ForEach(0..<48, id: \.self) { i in
                let wobble = time == 0 ? 0.8 : 0.55 + 0.45 * CGFloat(sin(time * 7 + Double(i) * 0.9))
                Capsule().fill(.secondary).frame(width: 2.5, height: max(3, 14 * (0.12 + fraction * wobble)))
            }
        }
    }
}

/// One short line at the top of the list (a saved-early reason, a missing permission). A confirmation goes away by itself.
private struct NoticeRow: View {
    let text: String
    let report: Int?
    let link: URL?
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
            VStack(alignment: .leading, spacing: 3) {
                Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
                // An error is filed: where its line is in the log, for whoever looks into it.
                if let report {
                    Text("Condition report: line \(report) of Recorder.log.").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let link { Button("Open System Settings") { NSWorkspace.shared.open(link) }.controlSize(.small).padding(.top, 2) }
            }
            Spacer(minLength: 0)
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary).frame(minWidth: 24, minHeight: 24).contentShape(Rectangle()).accessibilityLabel("Dismiss")
        }
        .padding(.vertical, 2)
    }
}

/// A file from the File menu that is not in the library: shown while it runs, and where its transcript went.
private struct OutsideRow: View {
    let url: URL
    let transcriber: Transcriber

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(url.lastPathComponent).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
            if let output = transcriber.finishedElsewhere[url] {
                HStack {
                    Text("Transcript saved").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([output]); transcriber.dismissFinished(url) }.controlSize(.small)
                    Button { transcriber.dismissFinished(url) } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary).frame(minWidth: 24, minHeight: 24).contentShape(Rectangle()).accessibilityLabel("Dismiss")
                }
            } else {
                switch transcriber.states[url] {
                case .running(let value):
                    HStack {
                        ProgressView(value: value).accessibilityLabel("Transcribing \(url.lastPathComponent)")
                        Button("Cancel") { transcriber.cancel(url) }.controlSize(.small)
                    }
                case .failed(let text):
                    HStack {
                        Label(text, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Try Again") { transcriber.request(url) }.controlSize(.small)
                    }
                default:
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(transcriber.states[url] == .downloadingModel ? "Downloading the speech model" : "Preparing").font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") { transcriber.cancel(url) }.controlSize(.small)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// Every tag in the library as a chip with its count; one click shows only those recordings, a second click all.
private struct TagStrip: View {
    let tags: [(tag: String, count: Int)]
    let colors: [String: Int]
    @Binding var selected: String?

    var body: some View {
        Flow(spacing: 6) {
            ForEach(tags, id: \.tag) { item in
                let on = selected == item.tag
                Button { selected = on ? nil : item.tag } label: {
                    HStack(spacing: 4) {
                        if let color = Theme.tagColor(colors[item.tag]) { Circle().fill(color).frame(width: 7, height: 7) }
                        Text(item.tag).lineLimit(1)
                        Text("\(item.count)").foregroundStyle(on ? Theme.accent : Color.secondary).monospacedDigit()
                    }
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(on ? Theme.selection : Theme.card))
                    .overlay(Capsule().strokeBorder(on ? Theme.accent.opacity(0.5) : .clear))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(on ? "Show all recordings" : "Show recordings tagged \(item.tag)")
                .accessibilityLabel("\(item.tag), \(item.count)")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Lays its children out in rows, left to right, wrapping at the width it is given.
struct Flow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(width: proposal.width ?? .infinity, subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in rows(width: bounds.width, subviews) {
            var x = bounds.minX
            for index in row.indices {
                var size = subviews[index].sizeThatFits(.unspecified)
                size.width = min(size.width, bounds.width)  // a tag wider than the strip is cut, not pushed outside
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private func rows(width: CGFloat, _ subviews: Subviews) -> [(indices: [Int], y: CGFloat, width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], y: CGFloat, width: CGFloat, height: CGFloat)] = []
        var y: CGFloat = 0
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            if let last = rows.last, last.width + spacing + size.width <= width {
                rows[rows.count - 1].indices.append(index)
                rows[rows.count - 1].width += spacing + size.width
                rows[rows.count - 1].height = max(last.height, size.height)
            } else {
                if let last = rows.last { y = last.y + last.height + spacing }
                rows.append(([index], y, size.width, size.height))
            }
        }
        return rows
    }
}

// MARK: - The record button

/// The record button with its label, at the bottom of the sidebar.
private struct RecordBar: View {
    let model: Recorder

    var body: some View {
        RecordButton(model: model, label: nil)
            .padding(.top, 12)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

/// A flat red disc in a thin ring (no gloss); a red square while recording, a spinner while saving.
struct RecordButton: View {
    let model: Recorder
    let label: String?
    var size: CGFloat = 56
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var caption: String {
        switch model.state {
        case .idle: label ?? "New Recording"
        case .recording: "Stop Recording"
        case .saving: "Saving"
        }
    }

    var body: some View {
        Button(action: model.toggle) {
            VStack(spacing: 6) {
                ZStack {
                    Circle().strokeBorder(Theme.line, lineWidth: 3).background(Circle().fill(Theme.raised.opacity(0.6)))
                    if model.state == .saving {
                        ProgressView().controlSize(.small)
                    } else {
                        let disc = size * 0.78
                        RoundedRectangle(cornerRadius: model.state == .recording ? size * 0.09 : disc / 2)
                            .fill(Theme.accent)
                            .frame(width: model.state == .recording ? size * 0.36 : disc, height: model.state == .recording ? size * 0.36 : disc)
                    }
                }
                .frame(width: size, height: size)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: model.state)
                Text(caption).font(size > 60 ? .title3 : .callout).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .disabled(model.state == .saving)
        .accessibilityLabel(model.state == .recording ? "Stop recording" : model.state == .saving ? "Saving" : "Start recording")
        .help(model.state == .recording ? "Stop and save (⌘.)" : "Record (⌘N)")
    }
}

/// A plain button that dims a little while it is pressed.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.6 : 1)
    }
}
