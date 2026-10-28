import AppKit
import AVFoundation
import SwiftUI

@main
struct RecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage("showMenuBar") private var showMenuBar = true

    var body: some Scene {
        Window("Kagu", id: "main") {
            ContentView(model: delegate.model)
        }
        .defaultSize(width: 1180, height: 700)
        .defaultLaunchBehavior(.presented)  // also when it was closed at the last quit, else a launch shows nothing
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Recording") { Task { await delegate.model.start() } }
                    .keyboardShortcut("n")
                    .disabled(delegate.model.state != .idle)
                Button("Stop Recording") { delegate.model.stop() }
                    .keyboardShortcut(".")
                    .disabled(delegate.model.state != .recording)
                Button(delegate.model.isPaused ? "Resume Recording" : "Pause Recording") { delegate.model.togglePause() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(delegate.model.state != .recording)
                Divider()
                ImportCommand()
            }
            CommandGroup(replacing: .appInfo) {
                Button("About Kagu") {
                    NSApp.orderFrontStandardAboutPanel(options: [.credits: NSAttributedString(string: "Kagu. Rhynochetos jubatus. Sings in pairs.", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])])
                }
                Button("Check for Updates...") { Updater.shared?.check() }
            }
            CommandMenu("Playback") {
                Button("Play or Pause") { delegate.model.player.toggle() }.keyboardShortcut(.space, modifiers: .option)
                    .disabled(!delegate.model.player.isLoaded)
                // The keys are the plain arrows, outside text fields (ContentView); a menu shortcut would take them from text fields.
                Button("Skip Back 15 Seconds") { delegate.model.player.skip(-15) }
                    .disabled(!delegate.model.player.isLoaded)
                Button("Skip Forward 15 Seconds") { delegate.model.player.skip(15) }
                    .disabled(!delegate.model.player.isLoaded)
            }
        }
        Window("Transcribe Audio File", id: "import") {
            ImportView(transcriber: delegate.model.transcriber)
        }
        .windowStyle(.hiddenTitleBar)  // the title is inside the window, as in the mockup
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        Settings {
            SettingsView(transcriber: delegate.model.transcriber, folder: delegate.model.folder)
        }
        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarMenu(model: delegate.model)
        } label: {
            MenuBarLabel(model: delegate.model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor let model = Recorder()
    @MainActor private lazy var calls = CallWatcher(model: model)

    @MainActor func applicationDidFinishLaunching(_ notification: Notification) {
        // Scripted runs: `--record <seconds>` presses record on launch, stops and quits after N seconds.
        let args = CommandLine.arguments
        let scripted = ["--selftest", "--record", "--download", "--tag", "--play", "--transcribe-file", "--transcribe-raw"]
        if !args.contains(where: scripted.contains) {
            calls.start()
            Updater.shared = Updater(model: model)
        }
        // Test aid: `--appearance light|dark` forces the look of the whole app.
        if let i = args.firstIndex(of: "--appearance"), i + 1 < args.count {
            NSApp.appearance = NSAppearance(named: args[i + 1] == "light" ? .aqua : .darkAqua)
        }
        if args.contains("--selftest") {
            Task { @MainActor in
                let failures = await Selftest.run()
                print(failures.isEmpty ? "selftest ok" : "selftest FAILED:\n- " + failures.joined(separator: "\n- "))
                exit(failures.isEmpty ? 0 : 1)
            }
            return
        }
        if let i = args.firstIndex(of: "--record"), i + 1 < args.count, let seconds = Double(args[i + 1]) {
            model.whenIdle { [model] in
                Task { @MainActor in
                    await model.start()
                    // `--pause <a> <b>` pauses at a seconds and resumes at b (wall clock), a test aid for Pause.
                    if let p = args.firstIndex(of: "--pause"), p + 2 < args.count, let a = Double(args[p + 1]), let b = Double(args[p + 2]), a < b, b < seconds {
                        try? await Task.sleep(for: .seconds(a))
                        model.togglePause()
                        try? await Task.sleep(for: .seconds(b - a))
                        model.togglePause()
                        try? await Task.sleep(for: .seconds(seconds - b))
                    } else {
                        try? await Task.sleep(for: .seconds(seconds))
                    }
                    model.stop()
                    model.whenIdle { model.transcriber.whenIdle { NSApp.terminate(nil) } }
                }
            }
        }
        // Scripted runs: `--download largeV3|turbo` downloads and verifies a model, prints progress and quits.
        if let i = args.firstIndex(of: "--download"), i + 1 < args.count,
           let which = WhisperModel.allCases.first(where: { "\($0)" == args[i + 1] }) {
            let store = model.transcriber.models
            store.download(which)
            Task { @MainActor in
                while store.state(which) != .installed, store.state(which) != .missing {
                    print("\(store.state(which))")
                    try? await Task.sleep(for: .seconds(5))
                }
                print("final: \(store.state(which)) \(store.message ?? "")")
                NSApp.terminate(nil)
            }
        }
        // Scripted runs: `--tag <file name> <tag>` sets a Finder tag through the library, prints the tags read back and quits.
        if let i = args.firstIndex(of: "--tag"), i + 2 < args.count {
            let url = model.library.folder.appending(path: args[i + 1])
            model.library.setTags([args[i + 2]], for: url)
            Task { @MainActor [model] in
                try? await Task.sleep(for: .seconds(1.5))
                print("tags: \(model.library.items.first { $0.url == url }?.tags ?? [])")
                NSApp.terminate(nil)
            }
        }
        // Scripted runs: `--play <m4a>` plays one second through the player, prints where it got to and quits.
        if let i = args.firstIndex(of: "--play"), i + 1 < args.count {
            Task { @MainActor in
                let player = Player()
                player.load(URL(fileURLWithPath: args[i + 1]))
                player.toggle()
                try? await Task.sleep(for: .seconds(1.2))
                let first = player.time
                player.seek(to: 5)
                player.toggle()
                print("duration \(player.duration) s, after 1.2 s at \(first) s, playing \(player.isPlaying), after seek \(player.time) s, paused \(!player.isPlaying)")
                NSApp.terminate(nil)
            }
        }
        // Scripted runs: `--transcribe-file <audio file>` is Transcribe Audio File without the file picker.
        if let i = args.firstIndex(of: "--transcribe-file"), i + 1 < args.count {
            Task { @MainActor [model] in
                await model.transcriber.request(URL(fileURLWithPath: args[i + 1]))
                model.transcriber.whenIdle {
                    for (url, state) in model.transcriber.states { if case .failed(let text) = state { print("failed \(url.lastPathComponent): \(text)") } }
                    NSApp.terminate(nil)
                }
            }
        }
        // Scripted runs: `--transcribe-raw <Recording x.raw.caf>` transcribes a copy of a raw recording and quits.
        if let i = args.firstIndex(of: "--transcribe-raw"), i + 1 < args.count {
            let source = URL(fileURLWithPath: args[i + 1])
            Task { @MainActor [model] in
                await model.transcriber.transcribeRaw(source)
                model.transcriber.whenIdle {
                    for (url, state) in model.transcriber.states { if case .failed(let text) = state { print("failed \(url.lastPathComponent): \(text)") } }
                    NSApp.terminate(nil)
                }
            }
        }
    }

    /// With the menu bar item on (or a recording running) the app stays when its windows close.
    @MainActor func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        let menuBar = UserDefaults.standard.object(forKey: "showMenuBar") as? Bool ?? true
        return !menuBar && model.state == .idle
    }

    @MainActor func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // An update quits only when idle, but a transcript may have been asked for since: let it finish first.
        if model.updating, model.transcriber.isBusy {
            model.transcriber.whenIdle { NSApp.reply(toApplicationShouldTerminate: true) }
            return .terminateLater
        }
        model.transcriber.shutDown()  // the engine is a child process: it must not outlive the app
        guard model.state != .idle || model.isRecovering else { return .terminateNow }
        model.stop()
        model.whenIdle { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

@MainActor @Observable
final class Recorder {
    enum State { case idle, recording, saving }

    private(set) var state = State.idle
    private(set) var started: Date?
    private(set) var isPaused = false
    /// Seconds actually in the file (paused time not counted), from the frames the capture wrote.
    private(set) var elapsed: Double = 0
    /// The last levels (newest last), for the recording window's moving waveform.
    private(set) var levelHistory: [Float] = []
    /// Opens the library window from anywhere (set by a view that has `openWindow`).
    var openMainWindow: (() -> Void)?
    private let recordingWindow = RecordingWindow()
    private(set) var micLevel: Float = 0
    private(set) var systemLevel: Float = 0
    private(set) var micName = ""
    private(set) var lastFile: URL?
    private(set) var message: String?
    /// The log line of the error in `message`, shown under it as its condition report.
    private(set) var report: Int?
    /// A System Settings pane the notice can open (the mic permission).
    private(set) var messageLink: URL?
    /// While saving: when it began and how long it should take, from this Mac's earlier saves.
    private(set) var savingSince: Date?
    private(set) var savingEstimate: Double?
    private(set) var warning: String?

    let transcriber = Transcriber()
    let player = Player()
    let folder = Library.defaultFolder
    let library: Library
    private let keepRaw = CommandLine.arguments.contains("--keep-raw")
    private var capture: Capture?
    private var meterTimer: Timer?
    private var ticks = 0
    private var bluetoothMicWasInUse = false
    private(set) var starting = false  // true while waiting for the mic permission answer
    /// Set while an update installs: Kagu is about to quit, so nothing new starts.
    var updating = false
    private var idleWaiters: [() -> Void] = []
    /// Converting a recording left by a crash. Separate from `state`, so it never keeps a new recording from starting.
    private(set) var isRecovering = false
    /// Leftovers tried in this run: a file that failed is not tried (and reported) again by the second look.
    private var attempted: Set<URL> = []
    /// Frames in the file at the last tick and for how many ticks that stayed the same, to notice a stream that stopped.
    private var lastFrames = 0
    private var stalledTicks = 0
    /// For the warning about missing system audio permission: how long something played, and the loudest Mac sample so far.
    private var outputTicks = 0
    private var systemPeakEver: Float = 0
    /// Set every second while recording when the disk has under 15 minutes of room left.
    private var lowDisk: String?
    /// Warnings already sent as a notification during this recording: each once, however often it comes and goes.
    private var alerted: Set<String> = []

    init() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Reserves left by a crash; one whose recording is still written belongs to another copy of the app
        // (a crashed take younger than 10 s keeps its reserve until recovery converts it).
        let reserves = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "reserve" }
        if !reserves.isEmpty {
            let leftovers = Set(Convert.leftovers(in: folder))
            for file in reserves where !FileManager.default.fileExists(atPath: file.deletingPathExtension().path) || leftovers.contains(file.deletingPathExtension()) {
                try? FileManager.default.removeItem(at: file)
            }
        }
        library = Library(folder: folder)
        transcriber.shouldPause = { [unowned self] in self.state != .idle || self.isRecovering }
        library.onMove = { [transcriber] in transcriber.moved($0, to: $1) }
        transcriber.resumeInterrupted(recordings: folder)
        recoverLeftovers()
        // A file that changed in the last seconds is skipped above (it may still be written); look again once it settled.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            while self?.isRecovering == true { try? await Task.sleep(for: .seconds(1)) }  // after the first look, not instead of it
            self?.recoverLeftovers()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop(reason: "Saved because the Mac went to sleep.") }
        }
        // A save that failed on a full disk is kept as a leftover; switching back to Kagu after freeing space saves it.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self, self.state == .idle, self.freeBytes > 1 << 30 { self.recoverLeftovers() } }
        }
    }

    /// Space set aside on the recordings disk while recording and let go when saving begins, so the save has room
    /// even when another app fills the disk. Real zeros: a file that only claims its size holds nothing back.
    /// ponytail: best effort; a Time Machine snapshot taken meanwhile keeps its blocks until macOS purges it, so the disk watch stays the guard.
    nonisolated private static let reserveBytes = 60 * (8 << 20)  // about 500 MB, in whole chunks
    private var reserveTask: Task<Void, Never>?
    /// The reserve is written in full: only then does the disk watch count it.
    private var reserveHeld = false
    /// What saving takes per second of audio: the m4a, the hidden tracks file and the two WAVs for a transcript.
    private static let savingBytesPerSecond = 90_000

    private func setAside(while capture: Capture) {
        let url = capture.url.appendingPathExtension("reserve")
        reserveHeld = false
        reserveTask = Task.detached(priority: .utility) {
            let made = Self.writeZeros(url, bytes: Self.reserveBytes)
            await MainActor.run {
                // A short take may be saving already: then the space is not held back after all.
                if self.capture !== capture || self.state != .recording { try? FileManager.default.removeItem(at: url); return }
                self.reserveHeld = made
                log(made ? "reserve: set aside \(Self.reserveBytes / 1_000_000) MB" : "reserve: could not set space aside")
            }
        }
    }

    nonisolated private static func writeZeros(_ url: URL, bytes: Int) -> Bool {
        guard FileManager.default.createFile(atPath: url.path, contents: nil), let handle = try? FileHandle(forWritingTo: url) else { return false }
        defer { try? handle.close() }
        let chunk = Data(count: 8 << 20)
        do {
            for _ in 0..<(bytes / chunk.count) {
                if Task.isCancelled { throw CancellationError() }  // saving began: the space goes back now, not after 500 MB
                try handle.write(contentsOf: chunk)
            }
            try handle.synchronize()  // the blocks are really taken
            return true
        } catch {
            try? FileManager.default.removeItem(at: url)
            return false
        }
    }

    /// Free bytes on the recordings volume as `start()` counts them (space macOS can purge included), read fresh each time.
    private var freeBytes: Int { (try? URL(fileURLWithPath: folder.path).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage).map(Int.init) ?? 1 << 50 }  // unknown: plenty, never Int.max (sums follow)

    func toggle() {
        switch state {
        case .idle: Task { await start() }
        case .recording: stop()
        case .saving: break
        }
    }

    func start() async {
        if updating { return fail("Kagu is installing an update and opens again in a moment.") }
        guard state == .idle, !starting else { log("start ignored: \(state)"); return }
        starting = true
        defer { starting = false }
        dismissMessage()
        warning = nil
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else { return fail(Self.micDenied, link: Self.micSettings) }
        default:
            return fail(Self.micDenied, link: Self.micSettings)
        }
        let free = (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? 0
        guard free > 1 << 30 else { return fail("Not enough disk space. Free up at least 1 GB to record.") }

        let stamp = Date().formatted(.verbatim("\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)).\(minute: .twoDigits).\(second: .twoDigits)", timeZone: .current, calendar: .current))
        var url = folder.appending(path: ".Recording \(stamp).caf")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) || FileManager.default.fileExists(atPath: Convert.finalURL(for: url).path) {
            url = folder.appending(path: ".Recording \(stamp) \(n).caf")
            n += 1
        }
        do {
            let capture = try Capture(url: url)
            capture.onFault = { [weak self] reason in self?.stop(reason: "Saved early: \(reason).") }
            self.capture = capture
            micName = capture.micName
            bluetoothMicWasInUse = false
            started = Date()
            isPaused = false
            elapsed = 0
            levelHistory = []
            lastFrames = 0
            stalledTicks = 0
            outputTicks = 0
            systemPeakEver = 0
            lowDisk = nil
            alerted = []
            state = .recording
            setAside(while: capture)
            recordingWindow.show(model: self)
            AccessibilityNotification.Announcement("Recording started").post()
            log("recording: \(url.lastPathComponent)")
            let timer = Timer(timeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)  // keeps fault checks running while a menu is open
            meterTimer = timer
        } catch {
            fail(error.localizedDescription)
        }
    }

    func stop(reason: String? = nil) {
        guard state == .recording, let capture else { return }
        state = .saving
        reserveTask?.cancel()
        reserveTask = nil
        reserveHeld = false
        try? FileManager.default.removeItem(at: capture.url.appendingPathExtension("reserve"))  // its room is for the save
        let seconds = elapsed
        savingSince = Date()
        savingEstimate = SaveRate.estimate(for: seconds)
        meterTimer?.invalidate()
        started = nil
        isPaused = false
        recordingWindow.close()
        warning = nil
        micLevel = 0
        systemLevel = 0
        if let reason {
            log("stopped: \(reason)")
            notify(reason, expires: false)
            CallWatcher.alert("Recording stopped", reason)  // a stop nobody asked for, maybe behind a full-screen call
        }
        let keepRaw = keepRaw
        let m4a = Convert.finalURL(for: capture.url)
        let tracksFolder = Tracks.folder(stamp: m4a.deletingPathExtension().lastPathComponent)
        AccessibilityNotification.Announcement("Recording stopped").post()
        Task.detached {
            var error = capture.stop()
            var tracks: URL?
            let empty = error == nil && capture.framesWritten == 0
            if empty { try? FileManager.default.removeItem(at: capture.url) }
            if error == nil, !empty {
                do { tracks = try Convert.run(caf: capture.url, to: m4a, keepRaw: keepRaw, tracksFolder: tracksFolder) } catch let e { error = e }
            }
            await MainActor.run {
                self.capture = nil
                if error == nil, let since = self.savingSince { SaveRate.record(saving: Date().timeIntervalSince(since), audio: seconds) }
                self.savingSince = nil
                self.savingEstimate = nil
                if let error { self.fail("Could not finish saving: \(error.localizedDescription) The audio is kept: free up disk space, then switch back to Kagu to save it.") } else if empty { self.fail("Nothing was recorded: the audio stream did not start.") } else { self.lastFile = m4a }
                self.finishTracks(m4a: m4a, tracks: tracks)
                self.becomeIdle()
            }
        }
    }

    /// The two tracks of a saved recording go into a transcript right away, or are dropped: the hidden sidecar
    /// next to the recording keeps the two sides for a transcript made later.
    private func finishTracks(m4a: URL, tracks: URL?) {
        guard let tracks else { return }
        if transcriber.wantsTracks { transcriber.enqueueRecording(m4a: m4a, tracks: tracks) } else { try? FileManager.default.removeItem(at: tracks) }
    }

    func dismissMessage() {
        message = nil
        report = nil
        messageLink = nil
    }

    /// Pause keeps the mic open but writes nothing; Resume carries on in the same file.
    func togglePause() {
        guard state == .recording, let capture else { return }
        isPaused.toggle()
        capture.paused.store(isPaused, ordering: .relaxed)
        log(isPaused ? "recording: paused at \(Int(elapsed)) s" : "recording: resumed")
        AccessibilityNotification.Announcement(isPaused ? "Paused" : "Recording").post()
    }

    func showRecordingWindow() { if state != .idle { recordingWindow.show(model: self) } }

    /// A short notice from a view (a failed export, a transcript that could not be replaced).
    func show(_ text: String) { fail(text) }

    /// Runs `action` once nothing is recording or saving.
    func whenIdle(_ action: @escaping () -> Void) {
        if state == .idle && !isRecovering { action() } else { idleWaiters.append(action) }
    }

    private func tick() {
        guard let capture else { return }
        if let reason = Capture.faultText[capture.fault.load(ordering: .relaxed)] {
            return stop(reason: "Saved early: \(reason).")
        }
        let peaks = capture.takePeaks()
        systemPeakEver = max(systemPeakEver, peaks.system)
        micLevel = max(peaks.mic, micLevel * 0.85)
        systemLevel = max(peaks.system, systemLevel * 0.85)
        elapsed = Double(capture.framesKept.load(ordering: .relaxed)) / capture.sampleRate
        if !isPaused, ticks % 3 == 0 {  // 5 values a second
            levelHistory.append(max(micLevel, systemLevel))
            if levelHistory.count > 120 { levelHistory.removeFirst(levelHistory.count - 120) }
        }
        // A stream that stopped without any device notice (another app holding the mic, a stuck audio server).
        let frames = capture.framesKept.load(ordering: .relaxed)
        stalledTicks = !isPaused && frames == lastFrames ? stalledTicks + 1 : 0
        lastFrames = frames
        if stalledTicks > 75 { return stop(reason: "Saved early: the audio stream stopped.") }  // 5 s
        // The raw file grows 6 bytes a frame (3 channels of 16 bit at the file rate). Saving needs `savingBytesPerSecond`
        // for every second recorded, out of the free space plus the reserve; the file itself needs real free space.
        // `-diskReserveMB <n>` takes that much more off, a test aid for this path.
        if ticks % 15 == 0 {  // every second: another app can fill a disk fast
            let free = freeBytes - UserDefaults.standard.integer(forKey: "diskReserveMB") * 1_000_000
            let room = free + (reserveHeld ? Self.reserveBytes : 0)
            let need = 100_000_000 + Int(elapsed) * Self.savingBytesPerSecond
            if room < need || free < 50_000_000 { return stop(reason: "Saved early: the disk is almost full.") }
            let raw = Int(Capture.fileRate) * 6
            let seconds = min((room - need) / (raw + Self.savingBytesPerSecond), (free - 50_000_000) / raw)
            lowDisk = seconds < 15 * 60 ? "The disk is almost full. Free up space, or Kagu saves and stops before it runs out." : nil
        }
        // Without the system audio permission the tap delivers exact zeros while something plays.
        if !isPaused, ticks % 15 == 0, capture.outputIsPlayingElsewhere() { outputTicks += 15 }  // paused, nothing is heard on purpose
        let silent = !isPaused && capture.micZeroRun.load(ordering: .relaxed) > Int(capture.sampleRate)
        // A running output can be silent (a call before anyone talks), so a whole minute, and not one sample heard.
        let deaf = !isPaused && systemPeakEver == 0 && outputTicks >= 900
        let text = lowDisk ?? (silent ? "No sound from the mic. Another app may be using it, or Kagu has no mic access."
            : deaf ? "No sound from the Mac yet. If you hear the call, allow Kagu in System Settings, Privacy & Security, Screen & System Audio Recording." : nil)
        if let text, text != warning {
            AccessibilityNotification.Announcement(text).post()
            log("warning: \(text)")
            if alerted.insert(text).inserted { CallWatcher.alert("Kagu is still recording", text) }
        }
        warning = text

        ticks += 1
        if capture.micIsBluetooth, ticks % 75 == 0 {  // every 5 s
            if capture.micStillNeeded {
                bluetoothMicWasInUse = true
            } else if bluetoothMicWasInUse {
                stop(reason: "Saved: the call ended, so Kagu let go of the headset mic.")
            }
        }
    }

    private func becomeIdle() {
        state = .idle
        runIdleWaiters()
    }

    /// Recovery ends on its own time: a recording may be running by then, so it only runs the waiters, never sets `state`.
    private func runIdleWaiters() {
        guard state == .idle, !isRecovering else { return }
        let waiters = idleWaiters
        idleWaiters = []
        waiters.forEach { $0() }
    }

    static let micDenied = "Kagu needs the microphone. Allow it in System Settings, Privacy & Security, Microphone."
    static let micSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")

    /// The notice is in the library window, so the window comes up when it is closed (a recording started from the menu bar).
    /// An error stays until it is dismissed: it may be read only after a call.
    private func fail(_ text: String, link: URL? = nil) {
        notify(text, expires: false)
        report = log("error: \(text)")
        messageLink = link
        openMainWindow?()
        CallWatcher.alert("Kagu", text)
    }

    /// A short line at the top of the list; a confirmation goes away by itself.
    private func notify(_ text: String, expires: Bool = true) {
        message = text
        report = nil
        messageLink = nil
        AccessibilityNotification.Announcement(text).post()
        guard expires, !text.contains("/") else { return }  // a line that names a file stays until it is dismissed
        Task {
            try? await Task.sleep(for: .seconds(12))
            if message == text { dismissMessage() }
        }
    }

    private func recoverLeftovers() {
        guard !isRecovering else { return }
        let leftovers = Convert.leftovers(in: folder).filter { $0 != capture?.url && !attempted.contains($0) }  // never the take being saved right now
        guard !leftovers.isEmpty else { return }
        attempted.formUnion(leftovers)
        isRecovering = true
        let keepRaw = keepRaw
        Task.detached {
            var recovered: URL?
            var failed: URL?
            var transcripts: [(m4a: URL, tracks: URL)] = []
            for caf in leftovers {
                let m4a = Convert.finalURL(for: caf)
                // A marker survives a crash inside the conversion; the next try then skips echo
                // removal, so one bad file cannot crash the app on every launch.
                let marker = caf.appendingPathExtension("trying")
                let tries = (try? String(contentsOf: marker, encoding: .utf8)).map { Int($0) ?? 1 } ?? 0
                guard tries < 2 else {  // crashed with and without echo removal: leave it be
                    failed = caf
                    log("recover skipped for \(caf.lastPathComponent): it stopped the app twice")
                    continue
                }
                let retry = tries > 0
                try? FileManager.default.removeItem(at: caf.appendingPathExtension("reserve"))  // the crashed take's reserve: room for this
                try? "\(tries + 1)".write(to: marker, atomically: true, encoding: .utf8)
                do {
                    let tracksFolder = Tracks.folder(stamp: m4a.deletingPathExtension().lastPathComponent)
                    let tracks = try Convert.run(caf: caf, to: m4a, keepRaw: keepRaw, cancelEcho: !retry, tracksFolder: tracksFolder)
                    try? FileManager.default.removeItem(at: marker)
                    recovered = m4a
                    transcripts.append((m4a, tracks))
                } catch {
                    try? FileManager.default.removeItem(at: marker)  // a plain error, not a crash: keep echo removal next time
                    failed = caf
                    log("recover failed for \(caf.lastPathComponent): \(error)")
                }
            }
            await MainActor.run {
                for item in transcripts { self.finishTracks(m4a: item.m4a, tracks: item.tracks) }
                if let recovered {
                    self.lastFile = recovered
                    self.notify("Recovered an unfinished recording.")
                }
                if let failed { self.fail("Could not recover an unfinished recording; it is kept at \(failed.path).") }
                self.isRecovering = false
                self.runIdleWaiters()
            }
        }
    }
}

/// How long saving takes on this Mac: the median of the last five saves, in seconds of saving per second of audio.
enum SaveRate {
    private static let key = "saveRates"
    private static let measured = 80.0 / 3600  // about 80 s per recorded hour on an M4 Pro, until this Mac has its own

    static func median(_ rates: [Double]) -> Double {
        guard !rates.isEmpty else { return measured }
        let sorted = rates.sorted()
        return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }

    /// Nil when there is nothing worth saying: under 20 s, or no audio length to go by (a recovered recording).
    static func estimate(for audio: Double) -> Double? {
        let rates = UserDefaults.standard.array(forKey: key) as? [Double] ?? []
        let seconds = (audio * median(rates)).rounded()
        return audio > 0 && seconds >= 20 ? seconds : nil
    }

    static func record(saving: Double, audio: Double) {
        guard audio > 60 else { return }  // a short test take says little about an hour
        let rates = (UserDefaults.standard.array(forKey: key) as? [Double] ?? []) + [saving / audio]
        UserDefaults.standard.set(Array(rates.suffix(5)), forKey: key)
    }
}
