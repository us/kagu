import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Runs transcription jobs one at a time (the model needs several GB, so two never run together),
/// keeps the settings, and knows the state of every recording that is being worked on.
@MainActor @Observable
final class Transcriber {
    struct Job {
        var id = UUID()  // its entry in `places`
        var source: URL  // the recording (or file) the user sees; the state is keyed by it
        var title: String
        var tracks: [(speaker: String, wav: URL)]
        var output: URL
        var cleanup: URL  // deleted when the transcript is written; kept when the app is quit mid-job

        /// The same job for the recording at its new place: the transcript goes next to the new name.
        func following(_ url: URL) -> Job {
            let stem = url.deletingPathExtension().lastPathComponent
            let suffix = output.lastPathComponent.dropFirst(source.deletingPathExtension().lastPathComponent.count)  // ".md", ".transcript.md"
            var job = self
            job.source = url
            job.title = stem
            job.output = url.deletingLastPathComponent().appending(path: stem + suffix)
            return job
        }
    }

    enum State: Equatable {
        case queued  // preparing the audio or waiting for its turn
        case downloadingModel
        case running(Double)
        case failed(String)

        var isFailure: Bool { if case .failed = self { true } else { false } }
    }

    static let languages = ["auto", "en", "tr", "de", "es", "fr", "it", "pt", "nl", "ru", "ar", "ja", "zh"]

    let models = ModelStore()
    /// One entry per recording or file in progress. A finished job leaves nothing: its transcript file is the result.
    private(set) var states: [URL: State] = [:]
    /// Transcripts of files that are not in the library (File menu): where they went.
    private(set) var finishedElsewhere: [URL: URL] = [:]

    var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: "transcribeAfterRecording") } }
    var model: WhisperModel { didSet { UserDefaults.standard.set(model.rawValue, forKey: "whisperModel") } }
    var language: String { didSet { UserDefaults.standard.set(language, forKey: "whisperLanguage") } }

    private var queue: [Job] = []
    private var current: (job: Job, process: WhisperProcess)?
    private var working = false
    private var shuttingDown = false
    private var idleWaiters: [() -> Void] = []
    private var pollers: [URL: Task<Void, Never>] = [:]
    /// The model each waiting request downloads (the one chosen when it was asked for).
    private var waiting: [URL: WhisperModel] = [:]
    /// Downloads a Transcribe press started (not Settings): they stop when their last waiting request is cancelled.
    private var ownedDownloads: Set<WhisperModel> = []
    /// The latest preparation per recording: one that was cancelled and asked for again must not queue twice.
    private var preparing: [URL: UUID] = [:]
    /// Where the recording of each request in progress is now (by the request's id): a rename or a move updates it,
    /// and every step of the job looks its place up here.
    private var places: [UUID: URL] = [:]
    /// Set by the recorder: a new job does not start while a recording is running (CPU and memory for the capture).
    var shouldPause: () -> Bool = { false }

    init() {
        let defaults = UserDefaults.standard
        enabled = defaults.object(forKey: "transcribeAfterRecording") as? Bool ?? false
        model = defaults.string(forKey: "whisperModel").flatMap(WhisperModel.init) ?? .turbo
        language = defaults.string(forKey: "whisperLanguage") ?? "auto"
        // One model on disk and another one selected: use the one that is there.
        if models.state(model) != .installed, let installed = WhisperModel.allCases.first(where: { models.state($0) == .installed }) { model = installed }
    }

    /// True when a finished recording should go straight into a transcript.
    var wantsTracks: Bool { enabled && models.state(model) == .installed && Whisper.binary != nil }

    var isBusy: Bool { working || !queue.isEmpty || states.values.contains { !$0.isFailure } }

    // MARK: - Asking for a transcript

    /// The Transcribe button: downloads the model first when it is missing, then prepares the audio and queues the job.
    func request(_ source: URL) {
        guard !shuttingDown, states[source].map(\.isFailure) ?? true else { return }
        // Already transcribed: the result is next to the recording, a second one would only be a hidden copy.
        let stem = source.deletingPathExtension()
        if [stem.appendingPathExtension("md"), stem.appendingPathExtension("transcript.md")].contains(where: { FileManager.default.fileExists(atPath: $0.path) }) { return }
        finishedElsewhere[source] = nil
        if models.state(model) == .installed {
            prepare(source)
        } else {
            let wanted = model  // Settings may pick another model meanwhile; this request waits for this one
            states[source] = .downloadingModel
            var running = false
            if case .downloading = models.state(wanted) { running = true }
            if !running { ownedDownloads.insert(wanted) }
            waiting[source] = wanted
            models.download(wanted)
            pollers[source]?.cancel()
            let ticket = UUID()
            places[ticket] = source
            pollers[source] = Task {
                while models.state(wanted) != .installed, models.state(wanted) != .missing {
                    try? await Task.sleep(for: .milliseconds(400))
                    if Task.isCancelled { places[ticket] = nil; return }
                }
                let source = places.removeValue(forKey: ticket) ?? source
                pollers[source] = nil
                waiting[source] = nil
                ownedDownloads.remove(wanted)  // finished or stopped: nothing left to own
                guard states[source] == .downloadingModel else { return }
                if models.state(wanted) == .installed { prepare(source) } else { fail(source, models.message ?? "The download was stopped.") }
            }
        }
    }

    /// Stops a transcript in progress for one recording.
    func cancel(_ source: URL) {
        let wait = waiting.removeValue(forKey: source)
        states[source] = nil
        preparing[source] = nil
        pollers[source]?.cancel()
        pollers[source] = nil
        for job in queue where job.source == source {
            try? FileManager.default.removeItem(at: job.cleanup)
            places[job.id] = nil
        }
        queue.removeAll { $0.source == source }
        if current?.job.source == source { current?.process.cancel() }
        // Nobody else waits for the model and this request started the download (not Settings): stop it.
        if let wait, ownedDownloads.contains(wait), !waiting.values.contains(wait) {
            ownedDownloads.remove(wait)
            models.cancelDownload(wait)
        }
        checkIdle()
    }

    /// A recording was renamed or moved (the library tells): its state and its job follow it.
    func moved(_ old: URL, to new: URL) {
        guard old != new else { return }
        for (id, url) in places where url == old { places[id] = new }
        if let state = states.removeValue(forKey: old) { states[new] = state }
        if let wait = waiting.removeValue(forKey: old) { waiting[new] = wait }
        if let token = preparing.removeValue(forKey: old) { preparing[new] = token }
        if let poller = pollers.removeValue(forKey: old) { pollers[new] = poller }
        for i in queue.indices where queue[i].source == old { queue[i] = queue[i].following(new) }
        if let job = current?.job, job.source == old { current?.job = job.following(new) }
        // The tracks of a recording's own job are found again at the next launch by its name (see `resumeInterrupted`).
        for job in queue + [current?.job].compactMap({ $0 }) where job.source == new && !job.cleanup.lastPathComponent.hasPrefix("job-") {
            try? new.path.write(to: job.cleanup.appending(path: Self.nameFile), atomically: true, encoding: .utf8)
        }
    }

    /// In a recording's tracks folder: the recording's path after a rename or a move (the folder keeps the first name).
    private static let nameFile = "recording.txt"

    /// A recording just saved with its two tracks (automatic transcription, or an interrupted job found at launch).
    func enqueueRecording(m4a: URL, tracks: URL) {
        enqueue(Job(
            source: m4a,
            title: m4a.deletingPathExtension().lastPathComponent,
            tracks: [("You", tracks.appending(path: "me.wav")), ("Them", tracks.appending(path: "them.wav"))],
            output: m4a.deletingPathExtension().appendingPathExtension("md"),
            cleanup: tracks))
    }

    /// Reads the audio of `source` into tracks and queues it. With the hidden sidecar the two sides stay apart;
    /// any other file is one "Speaker" track, because a mixed file cannot be split.
    private func prepare(_ source: URL) {
        states[source] = .queued
        let token = UUID()
        preparing[source] = token
        places[token] = source
        // ponytail: a folder of its own per job (two folders can hold a "Meeting.m4a"), so a quit in the middle of a manual
        // transcript is not resumed; the sidecar stays, Transcribe again starts over.
        let folder = Tracks.folder(stamp: "job-\(token.uuidString)")
        Task {
            do {
                var tracks: [(speaker: String, wav: URL)] = []
                var kind = "md"
                // Read at its place now: it may have been renamed since Transcribe was pressed, or while it was opened.
                @MainActor func read<T: Sendable>(_ work: @escaping @Sendable (URL) throws -> T) async throws -> T {
                    let first = places[token] ?? source
                    do { return try await Task.detached { try work(first) }.value } catch {
                        let now = places[token] ?? source
                        guard now != first else { throw error }
                        return try await Task.detached { try work(now) }.value
                    }
                }
                if FileManager.default.fileExists(atPath: Library.sidecarURL(for: places[token] ?? source).path) {
                    do {
                        try await read { try Tracks.splitSidecar(Library.sidecarURL(for: $0), into: folder) }
                        tracks = [("You", folder.appending(path: "me.wav")), ("Them", folder.appending(path: "them.wav"))]
                    } catch {
                        log("sidecar unreadable, using the mixed audio: \(error)")  // a damaged sidecar must not block the transcript
                    }
                }
                if tracks.isEmpty {
                    let wav = try await read { try Tracks.convertFile($0, into: folder) }
                    tracks = [("Speaker", wav)]
                    kind = "transcript.md"
                }
                let source = places[token] ?? source  // renamed while its audio was read
                guard states[source] == .queued, preparing[source] == token else {  // cancelled meanwhile (and maybe asked for again)
                    try? FileManager.default.removeItem(at: folder)  // this preparation's own folder
                    places[token] = nil
                    return
                }
                preparing[source] = nil
                enqueue(Job(id: token, source: source, title: source.deletingPathExtension().lastPathComponent, tracks: tracks, output: source.deletingPathExtension().appendingPathExtension(kind), cleanup: folder))
            } catch {
                try? FileManager.default.removeItem(at: folder)
                let source = places.removeValue(forKey: token) ?? source
                guard preparing[source] == token else { return }
                preparing[source] = nil
                fail(source, "Could not read the audio: \(error.localizedDescription)")
            }
        }
    }

    /// A quit in the middle of a transcription leaves its two tracks in the cache. On the next launch the
    /// job runs again, so an interrupted recording still gets its transcript.
    func resumeInterrupted(recordings: URL) {
        // Old leftovers go only after the interrupted jobs are picked up (a quit on Friday, opened on Monday).
        var resumed: Set<URL> = []
        defer { Tracks.sweep(keeping: resumed) }
        // Test runs (any `--flag`) must not start real work.
        guard models.state(model) == .installed, Whisper.binary != nil, !CommandLine.arguments.dropFirst().contains(where: { $0.hasPrefix("--") }) else { return }
        let folders = (try? FileManager.default.contentsOfDirectory(at: Tracks.cache, includingPropertiesForKeys: nil)) ?? []
        for folder in folders {
            let stem = folder.lastPathComponent
            // Renamed or moved during the job: its path is written down; else it may have been moved into a folder of the library since.
            let noted = (try? String(contentsOf: folder.appending(path: Self.nameFile), encoding: .utf8)).map { URL(fileURLWithPath: $0) }
            let places = [recordings] + Library.subfolders(of: recordings).map { recordings.appending(path: $0, directoryHint: .isDirectory) }
            let candidates = noted.map { [$0] } ?? places.map { $0.appending(path: stem + ".m4a") }
            guard let m4a = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
                  FileManager.default.fileExists(atPath: folder.appending(path: "me.wav").path),
                  FileManager.default.fileExists(atPath: folder.appending(path: "them.wav").path),
                  !FileManager.default.fileExists(atPath: m4a.deletingPathExtension().appendingPathExtension("md").path) else { continue }
            log("resuming an interrupted transcript: \(stem)")
            resumed.insert(folder.standardizedFileURL)
            enqueueRecording(m4a: m4a, tracks: folder)
        }
    }

    /// File menu: pick any audio file and transcribe it.
    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.message = "Choose an audio file to transcribe. The transcript is saved next to it."
        if panel.runModal() == .OK, let url = panel.url { request(url) }
    }

    func dismissFinished(_ source: URL) { finishedElsewhere[source] = nil }

    /// Test aid behind `--transcribe-raw <caf>`: runs a copy of a raw recording through the normal
    /// conversion, so the original file is never touched. The transcript lands next to it.
    func transcribeRaw(_ source: URL) async {
        let folder = Tracks.folder(stamp: "raw-\(UUID().uuidString)")
        let copy = folder.appending(path: ".Recording \(source.deletingPathExtension().lastPathComponent).caf")
        let tracks = folder.appending(path: "tracks")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: copy)
            try await Task.detached { _ = try Convert.run(caf: copy, to: Convert.finalURL(for: copy), keepRaw: false, tracksFolder: tracks) }.value
            enqueue(Job(
                source: source,
                title: source.deletingPathExtension().lastPathComponent,
                tracks: [("You", tracks.appending(path: "me.wav")), ("Them", tracks.appending(path: "them.wav"))],
                output: source.deletingPathExtension().appendingPathExtension("transcript.md"),
                cleanup: folder))
        } catch {
            try? FileManager.default.removeItem(at: folder)
            fail(source, error.localizedDescription)
        }
    }

    // MARK: - The queue

    /// Stops everything for good: used at quit, so nothing may start afterwards. The tracks stay for the next launch.
    func shutDown() {
        shuttingDown = true
        queue.removeAll()
        current?.process.cancel()
    }

    /// Runs `action` once nothing is being prepared, queued or run.
    func whenIdle(_ action: @escaping () -> Void) {
        if isBusy { idleWaiters.append(action) } else { action() }
    }

    private func checkIdle() {
        guard !isBusy else { return }
        let waiters = idleWaiters
        idleWaiters = []
        waiters.forEach { $0() }
    }

    private func fail(_ source: URL, _ text: String) {
        states[source] = .failed(text)
        log("transcript failed for \(source.lastPathComponent): \(text)")
        checkIdle()
    }

    private func enqueue(_ job: Job) {
        guard !shuttingDown else { return }
        states[job.source] = .queued
        places[job.id] = job.source
        queue.append(job)
        guard !working else { return }
        working = true
        Task { await drain() }
    }

    private func drain() async {
        while !queue.isEmpty {
            while shouldPause(), !shuttingDown { try? await Task.sleep(for: .seconds(1)) }
            guard !queue.isEmpty else { break }
            await run(queue.removeFirst())
        }
        working = false
        checkIdle()
    }

    private func run(_ job: Job) async {
        guard states[job.source] != nil else {  // cancelled while waiting
            try? FileManager.default.removeItem(at: job.cleanup)
            places[job.id] = nil
            return
        }
        let process = WhisperProcess()
        current = (job, process)
        defer {
            current = nil
            places[job.id] = nil
        }
        states[job.source] = .running(0)
        let language = language
        // The chosen model, or one that is on disk: Settings may have picked a model that is not downloaded yet.
        let model = models.state(model) == .installed ? model : WhisperModel.allCases.first { models.state($0) == .installed } ?? model
        do {
            guard models.state(model) == .installed else { throw RecorderError("The speech model is not downloaded.") }
            let results = try await Whisper.run(model: models.url(model), tracks: job.tracks.map(\.wav), language: language, handle: process) { [weak self] value in
                Task { @MainActor in
                    guard let self else { return }
                    let source = self.places[job.id] ?? job.source
                    if case .running = self.states[source] { self.states[source] = .running(value) }
                }
            }
            let now = job.following(places[job.id] ?? job.source)  // the recording may have been renamed or moved meanwhile
            let (lines, struck) = Transcript.merge(zip(now.tracks, results).map { ($0.speaker, $1) }, language: language)
            let text = Transcript.render(lines, struck: struck, title: now.title, model: model.name, language: language, date: Date())
            // The recording may have been moved or renamed meanwhile (for example by a second copy of the app);
            // a transcript at the old place would be hidden from it.
            guard FileManager.default.fileExists(atPath: now.source.path) else {
                throw RecorderError("The recording was moved or renamed while it was transcribed. Transcribe it again.")
            }
            let output = Self.unused(now.output)
            try text.write(to: output, atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(at: now.cleanup)
            states[now.source] = nil
            if !now.source.path.hasPrefix(Library.defaultFolder.path + "/") { finishedElsewhere[now.source] = output }
            log("transcript: \(output.lastPathComponent), \(lines.count) paragraphs")
            AccessibilityNotification.Announcement("Transcript ready").post()
        } catch is CancellationError {
            // Quitting keeps the tracks of a recording for the next launch; a cancel, or a one-off file, leaves nothing behind.
            if !shuttingDown || job.cleanup.lastPathComponent.hasPrefix("job-") { try? FileManager.default.removeItem(at: job.cleanup) }
            let source = places[job.id] ?? job.source
            if case .running = states[source] { states[source] = nil }  // a new request made meanwhile keeps its state
        } catch {
            try? FileManager.default.removeItem(at: job.cleanup)  // Try Again prepares the audio again
            fail(places[job.id] ?? job.source, error.localizedDescription)
        }
    }

    /// A transcript never replaces an existing file: "name.md" becomes "name 2.md", "name 3.md", ...
    nonisolated static func unused(_ url: URL) -> URL {
        var candidate = url
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let base = url.deletingPathExtension().lastPathComponent
            candidate = url.deletingLastPathComponent().appending(path: "\(base) \(n)").appendingPathExtension(url.pathExtension)
            n += 1
        }
        return candidate
    }
}
