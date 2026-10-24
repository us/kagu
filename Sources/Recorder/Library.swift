import AppKit
import AVFoundation
import Foundation

struct RecordingItem: Identifiable, Hashable, Sendable {
    let url: URL
    let date: Date
    let duration: Double
    let transcript: URL?
    let transcriptText: String
    let tags: [String]  // the Finder tags of the file
    var accession: String?  // "2026.43": its entry in the register, see `Register`
    var folder: String?  // the subfolder of the Recordings folder it lives in; nil for the top
    var preview = ""  // the first words of the transcript, read once in the scan (not on every redraw)

    var id: URL { url }
    var stem: String { url.deletingPathExtension().lastPathComponent }
    var sidecar: URL { Library.sidecarURL(for: url) }

    /// "Recording 2026-10-21 17.07.14" is shown as "Oct 21 at 5:07 PM"; a name the user chose is shown as it is.
    var hasDefaultName: Bool { stem.wholeMatch(of: /Recording \d{4}-\d{2}-\d{2} \d{2}\.\d{2}\.\d{2}/) != nil }
    var displayTitle: String { hasDefaultName ? date.formatted(.dateTime.month(.abbreviated).day().hour().minute()) : stem }
    var title: String { displayTitle }
}

/// The recordings in the Recordings folder (every visible `.m4a`) with their transcripts,
/// newest first. It reloads by itself when the folder changes.
@MainActor @Observable
final class Library {
    private(set) var items: [RecordingItem] = []
    /// False until the folder has been read once, so an empty list is not mistaken for an empty library.
    private(set) var loaded = false
    var allTags: [String] { Set(items.flatMap(\.tags)).sorted() }
    /// The subfolders of the Recordings folder, by name (a folder shows even while it is empty).
    private(set) var folders: [String] = []
    /// Every tag with the number of recordings that carry it, by name.
    var tagCounts: [(tag: String, count: Int)] { allTags.map { tag in (tag, items.filter { $0.tags.contains(tag) }.count) } }
    private(set) var register: Register

    /// `~/Music/Recordings`, or the folder after `--library` (a test aid, so screenshots never touch real recordings).
    /// `--selftest` gets an empty folder of its own: a check must not number, recover or transcribe real recordings.
    static let defaultFolder: URL = {
        if CommandLine.arguments.contains("--selftest") { return FileManager.default.temporaryDirectory.appending(path: "recorder-selftest-library") }
        if let i = CommandLine.arguments.firstIndex(of: "--library"), i + 1 < CommandLine.arguments.count {
            return URL(fileURLWithPath: CommandLine.arguments[i + 1], isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: "Music/Recordings")
    }()

    /// Hidden next to the recording: ".<name>.tracks.m4a".
    nonisolated static func sidecarURL(for m4a: URL) -> URL {
        m4a.deletingLastPathComponent().appending(path: "." + m4a.deletingPathExtension().lastPathComponent + ".tracks.m4a")
    }

    let folder: URL
    private var stream: FSEventStreamRef?
    private var debounce: Task<Void, Never>?
    private var loading = false
    private var again = false
    private var known: [URL: (modified: Date, duration: Double)] = [:]

    init(folder: URL) {
        self.folder = folder
        register = Register(folder: folder)
        reload()
        watch()
    }

    /// The stream holds an unretained pointer to this library: it must stop before the library goes.
    isolated deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    func reload() {
        guard !loading else { again = true; return }
        loading = true
        let folder = folder
        let known = known
        Task {
            let scan = await Task.detached { Self.scan(folder, known: known) }.value
            items = register.number(scan.items)
            folders = scan.folders
            loaded = true
            self.known = scan.durations
            loading = false
            if again {
                again = false
                reload()
            }
        }
    }

    /// Reads the folder off the main thread. Durations come from the file header and are cached per modification date.
    nonisolated static func scan(_ folder: URL, known: [URL: (modified: Date, duration: Double)]) -> (items: [RecordingItem], durations: [URL: (modified: Date, duration: Double)], folders: [String]) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .creationDateKey, .tagNamesKey, .isRegularFileKey]
        let subfolders = Self.subfolders(of: folder)
        let places: [(url: URL, name: String?)] = [(folder, nil)] + subfolders.map { (folder.appending(path: $0, directoryHint: .isDirectory), $0) }
        var durations: [URL: (modified: Date, duration: Double)] = [:]
        var items: [RecordingItem] = []
        for place in places {
        let files = (try? FileManager.default.contentsOfDirectory(at: place.url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        // Regular files only: a folder named "x.m4a" is not a recording.
        for url in files where url.pathExtension == "m4a" && !url.lastPathComponent.contains(".partial") && ((try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false) {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let modified = values?.contentModificationDate ?? .distantPast
            var duration = 0.0
            if let cached = known[url], cached.modified == modified {
                duration = cached.duration
            } else if let file = try? AVAudioFile(forReading: url) {
                duration = Double(file.length) / file.fileFormat.sampleRate
            }
            durations[url] = (modified, duration)

            let stem = url.deletingPathExtension()
            let transcript = [stem.appendingPathExtension("md"), stem.appendingPathExtension("transcript.md")]
                .first { Self.isFile($0) }
            let text = transcript.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
            // A default name holds the moment the recording started; the file date is when it was saved (later, for a recovered one).
            let started = DateFormatter.recordingStamp.date(from: String(stem.lastPathComponent.dropFirst("Recording ".count)))
            let preview = Transcript.parse(text).first.map { String($0.text.prefix(160)) } ?? (transcript != nil ? "No speech found" : "No transcript")
            items.append(RecordingItem(url: url, date: stem.lastPathComponent.hasPrefix("Recording ") ? started ?? values?.creationDate ?? modified : values?.creationDate ?? modified, duration: duration, transcript: transcript, transcriptText: text, tags: values?.tagNames ?? [], accession: Register.read(url), folder: place.name, preview: preview))
        }
        }
        return (items.sorted { $0.date > $1.date }, durations, subfolders)
    }

    /// Visible, real subfolders on the same disk, by name. A link or a mounted volume is skipped, so a move or
    /// a folder delete can never reach outside the library.
    nonisolated static func subfolders(of folder: URL) -> [String] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .volumeIdentifierKey, .isPackageKey]
        let home = (try? folder.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
        return entries.compactMap { url -> String? in
            guard let v = try? url.resourceValues(forKeys: keys), v.isDirectory == true, v.isSymbolicLink != true, v.isPackage != true,
                  (v.volumeIdentifier as? NSObject) == home, Self.isFolderName(url.lastPathComponent) else { return nil }
            return url.lastPathComponent
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    nonisolated static func isFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
    }

    /// The endings a recording's own files use. A folder or a recording name must not end like one,
    /// or it would be taken for a part of another recording.
    nonisolated static let reservedEndings = [".m4a", ".md", ".caf", ".partial", ".transcript", ".tracks", ".raw", ".mic-clean"]

    /// The top folder is shown as "Recordings", so a subfolder of that name would be a second one.
    nonisolated static func isFolderName(_ name: String) -> Bool {
        !reservedEndings.contains { name.lowercased().hasSuffix($0) } && name.lowercased() != "recordings"
    }

    /// Every file that belongs to a recording, by the name it has next to the audio.
    nonisolated static func parts(of m4a: URL) -> [URL] {
        let stem = m4a.deletingPathExtension()
        return [m4a, stem.appendingPathExtension("md"), stem.appendingPathExtension("transcript.md"),
                stem.appendingPathExtension("raw.caf"), stem.appendingPathExtension("mic-clean.caf"), sidecarURL(for: m4a)]
    }

    /// A name for a file or a folder: no slash or colon, no leading dot, no ending of a recording's parts.
    nonisolated static func cleanName(_ name: String) -> String {
        var clean = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        while clean.hasPrefix(".") { clean.removeFirst() }  // a leading dot would hide it
        var changed = true
        while changed {
            changed = false
            for ending in reservedEndings where clean.lowercased().hasSuffix(ending) {
                clean = String(clean.dropLast(ending.count)).trimmingCharacters(in: .whitespaces)
                changed = true
            }
        }
        return clean
    }

    /// Moves every part of a recording to `stem` in `directory`, adding " 2", " 3" when the name is taken.
    /// All or nothing: a failure puts back what already moved. Returns the new audio file.
    private func moveParts(of item: RecordingItem, to directory: URL, stem: String) -> URL? {
        let from = Self.parts(of: item.url)
        func targets(_ name: String) -> [URL] { Self.parts(of: directory.appending(path: name).appendingPathExtension("m4a")) }
        var name = stem
        var n = 2
        // A target that is the source itself (only the case of a letter changes, on a case-insensitive disk) is free.
        while zip(from, targets(name)).contains(where: { $0 != $1 && FileManager.default.fileExists(atPath: $1.path) && !Self.sameFile($0, $1) }) {
            name = "\(stem) \(n)"
            n += 1
        }
        var done: [(URL, URL)] = []
        for (source, target) in zip(from, targets(name)) where source != target && Self.isFile(source) {
            do {
                try FileManager.default.moveItem(at: source, to: target)
                done.append((source, target))
            } catch {
                log("move failed: \(error)")
                var stuck: [URL] = []
                for (source, target) in done.reversed() {
                    do { try FileManager.default.moveItem(at: target, to: source) } catch { stuck.append(target) }
                }
                if !stuck.isEmpty {
                    moveProblem = "\(item.displayTitle) is split: \(stuck.map(\.lastPathComponent).joined(separator: ", ")) stayed in \(directory.lastPathComponent), the rest is in \(item.url.deletingLastPathComponent().lastPathComponent). Move them together in Finder."
                    log("move rollback incomplete: \(stuck.map(\.path))")
                }
                return nil
            }
        }
        guard !done.isEmpty else { return nil }
        return targets(name)[0]
    }

    /// Set when a failed move could not be put back completely; the view shows it once.
    var moveProblem: String?

    nonisolated static func sameFile(_ a: URL, _ b: URL) -> Bool {
        let key = URLResourceKey.fileResourceIdentifierKey
        guard let x = try? a.resourceValues(forKeys: [key]).fileResourceIdentifier as? NSObject,
              let y = try? b.resourceValues(forKeys: [key]).fileResourceIdentifier as? NSObject else { return false }
        return x.isEqual(y)
    }

    /// The folder on disk for a sidebar folder (nil is the Recordings folder itself).
    func directory(_ name: String?) -> URL {
        name.map { folder.appending(path: $0, directoryHint: .isDirectory) } ?? folder
    }

    /// Moves a recording and all its parts into another folder. Returns the new location.
    func move(_ item: RecordingItem, to name: String?) -> URL? {
        guard item.folder != name else { return nil }
        let url = moveParts(of: item, to: directory(name), stem: item.stem)
        reload()
        return url
    }

    /// Makes "New Folder" (or " 2" and on) and returns its name.
    func createFolder(_ wanted: String = "New Folder") -> String? {
        let base = Self.cleanName(wanted).isEmpty || !Self.isFolderName(Self.cleanName(wanted)) ? "New Folder" : Self.cleanName(wanted)
        var name = base
        var n = 2
        while FileManager.default.fileExists(atPath: folder.appending(path: name).path) {
            name = "\(base) \(n)"
            n += 1
        }
        do {
            try FileManager.default.createDirectory(at: folder.appending(path: name, directoryHint: .isDirectory), withIntermediateDirectories: false)
        } catch {
            log("new folder failed: \(error)")
            return nil
        }
        reload()
        return name
    }

    /// Renames a folder; nothing inside it changes. Returns the new name.
    func renameFolder(_ name: String, to wanted: String) -> String? {
        let clean = Self.cleanName(wanted)
        let onlyCase = clean.lowercased() == name.lowercased()
        guard !clean.isEmpty, clean != name, Self.isFolderName(clean), Self.subfolders(of: folder).contains(name),
              onlyCase || !FileManager.default.fileExists(atPath: folder.appending(path: clean).path) else { return nil }
        do {
            try FileManager.default.moveItem(at: directory(name), to: directory(clean))
        } catch {
            log("rename folder failed: \(error)")
            return nil
        }
        reload()
        return clean
    }

    /// Puts the folder's recordings back in the Recordings folder, then moves the folder to the Trash only when
    /// nothing else is left in it. Returns a sentence for the user when something stayed.
    /// `moved` maps each recording's old place to its new one (a taken name gets " 2").
    func deleteFolder(_ name: String) -> (note: String?, moved: [URL: URL]) {
        guard Self.subfolders(of: folder).contains(name) else { return (nil, [:]) }
        var moved: [URL: URL] = [:]
        // Read from disk, not from the last reload: the folder may have changed a moment ago.
        for item in Self.scan(folder, known: known).items where item.folder == name {
            guard let url = moveParts(of: item, to: folder, stem: item.stem) else {
                reload()
                return (moveProblem ?? "Could not move \(item.displayTitle) out of \(name), so the folder was kept.", moved)
            }
            moved[item.url] = url
        }
        let place = directory(name)
        let left = ((try? FileManager.default.contentsOfDirectory(atPath: place.path)) ?? []).filter { $0 != ".DS_Store" }
        if left.isEmpty {
            NSWorkspace.shared.recycle([place]) { [weak self] _, _ in Task { @MainActor in self?.reload() } }
            return (nil, moved)
        }
        reload()
        return ("The recordings of \(name) are back in Recordings. The folder still holds \(left.count) other file\(left.count == 1 ? "" : "s"), so it was kept.", moved)
    }

    /// Renames a recording and everything that belongs to it. Returns the new location, or nil when nothing changed.
    /// Either every file moves or none does.
    func rename(_ item: RecordingItem, to name: String) -> URL? {
        // A text field turns the non-breaking space in a date title into a plain space: that is not a new name.
        guard name.trimmingCharacters(in: .whitespacesAndNewlines).normalizedSpaces != item.displayTitle.normalizedSpaces else { return nil }
        let clean = Self.cleanName(name).replacingOccurrences(of: ".partial", with: "")
        guard !clean.isEmpty, clean != item.stem else { return nil }
        // It stays in its own folder.
        let url = moveParts(of: item, to: item.url.deletingLastPathComponent(), stem: clean)
        reload()
        return url
    }

    /// Moves a recording, its transcript and its sidecar to the Trash (they can be put back from there).
    func trash(_ item: RecordingItem) {
        let files = Self.parts(of: item.url).filter { Self.isFile($0) }
        NSWorkspace.shared.recycle(files) { [weak self] _, _ in
            Task { @MainActor in self?.reload() }
        }
    }

    /// Tags are Finder tags, so they show up in Finder and Spotlight too. Changing one does not touch the
    /// folder, so there is no file event: reload by hand.
    func setTags(_ tags: [String], for url: URL) {
        try? (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
        reload()
    }

    /// One FSEvents stream over the Recordings folder and its subfolders. The library lives as long as the app.
    private func watch() {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let library = Unmanaged<Library>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { library.scheduleReload() }  // the stream runs on the main queue
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, [folder.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    /// At most one reload every 0.6 s: a recording being written touches the folder all the time, and a
    /// debounce would put every reload off until it stops.
    private func scheduleReload() {
        guard debounce == nil else { return }
        debounce = Task {
            try? await Task.sleep(for: .milliseconds(600))
            debounce = nil
            reload()
        }
    }
}

/// The accession register: every recording gets "<year>.<n>", n counting per year, and a number is never
/// given twice, so a deleted recording leaves a gap that is counted as withdrawn. The number lives on the
/// file (an extended attribute, which a rename keeps); the counts issued live in the app's defaults, per folder.
struct Register {
    static let attribute = "local.recorder.accession"
    let key: String
    private(set) var issued: [String: Int]  // year: the last number given that year

    init(folder: URL) {
        key = "accession \(folder.standardizedFileURL.path)"
        issued = UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:]
    }

    var total: Int { issued.values.reduce(0, +) }

    func next(for date: Date) -> String {
        let year = String(Calendar.current.component(.year, from: date))
        return "\(year).\(issued[year, default: 0] + 1)"
    }

    /// Gives every item without a number the next one, oldest first, and writes it onto the file.
    // ponytail: a Finder duplicate copies the attribute, so two files can share a number; renumber the copy if that ever matters.
    mutating func number(_ items: [RecordingItem]) -> [RecordingItem] {
        var items = items
        // The highest count wins: another copy of the app may have numbered since this one started, and a
        // number on disk above the count (files from elsewhere) moves it up. Both before anything is given.
        let stored = UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:]
        issued.merge(stored, uniquingKeysWith: max)
        for case let number? in items.map(\.accession) {
            let parts = number.split(separator: ".")
            if parts.count == 2, let n = Int(parts[1]), n > issued[String(parts[0]), default: 0] { issued[String(parts[0])] = n }
        }
        for i in items.indices.sorted(by: { items[$0].date < items[$1].date }) where items[i].accession == nil {
            let number = next(for: items[i].date)
            guard Self.write(number, to: items[i].url) else { continue }
            issued[String(number.prefix { $0 != "." }), default: 0] += 1
            items[i].accession = number
        }
        UserDefaults.standard.set(issued, forKey: key)
        return items
    }

    /// A copy made by the app (Export) is not a second entry: it leaves the register's number behind.
    static func clear(_ url: URL) { removexattr(url.path, attribute, 0) }

    static func read(_ url: URL) -> String? {
        var buffer = [UInt8](repeating: 0, count: 32)
        let length = getxattr(url.path, attribute, &buffer, buffer.count, 0, 0)
        guard length > 0 else { return nil }
        return String(decoding: buffer[..<length], as: UTF8.self)
    }

    static func write(_ number: String, to url: URL) -> Bool {
        let bytes = Array(number.utf8)
        return setxattr(url.path, attribute, bytes, bytes.count, 0, 0) == 0
    }
}

extension DateFormatter {
    /// "2026-10-21 17.07.14", the date text in a default recording name.
    nonisolated(unsafe) static let recordingStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f
    }()
}

extension String {
    /// Narrow and no-break spaces (the date formatter puts one before AM and PM) as plain spaces.
    var normalizedSpaces: String { replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ") }
}
