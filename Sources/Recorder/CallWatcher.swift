import AppKit
import Calls
import UserNotifications

/// Notices a call (a call app, or Chrome on a Google Meet tab, holding a mic) and asks to record it.
/// When the call ends during a recording it asks to stop, and stops and saves by itself 2 minutes later.
@MainActor
final class CallWatcher: NSObject, UNUserNotificationCenterDelegate {
    nonisolated static func callApp(_ bundle: String) -> String? { Calls.callApp(bundle) }
    nonisolated static func isChrome(_ bundle: String) -> Bool { Calls.isChrome(bundle) }
    nonisolated static func isMeet(_ url: String) -> Bool { url.range(of: #"^https://meet\.google\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}(?![a-z])"#, options: .regularExpression) != nil }

    private unowned let model: Recorder
    private var timer: Timer?
    /// The app of the call going on: set once an app held a mic for 4 s, cleared after 10 s without.
    private var call: String?
    /// A call app holds a mic (or Kagu is asking Chrome about Meet), a call is on, or one ended under a minute ago
    /// (one back by then is the same call, see `endedAt`): Kagu stays open meanwhile.
    var isInCall: Bool { seenSince != nil || askingChrome || call != nil || endedAt.map { Date().timeIntervalSince($0) < 60 } == true }
    private var seenSince: Date?
    private var goneSince: Date?
    /// When the last call ended: one back within a minute (a mute, a dropped line) is the same call, not asked again.
    private var endedAt: Date?
    /// The start prompt was posted for this call (or a recording ran during it).
    private var asked = false
    /// `started` of a recording that ran during a call, and of one the owner said to keep.
    private var recordingInCall: Date?
    private var keep: Date?
    private var autoStop: Task<Void, Never>?
    /// Whether a Chrome tab is on a Meet call, asked again every 10 s while Chrome holds the mic.
    private var meetTab: Bool?
    private var askedChrome: Date?
    private var askingChrome = false
    /// Counts Chrome letting go of the mic, so an answer that arrives after that is dropped.
    private var chromeTurn = 0
    /// Test aid: `--call-test` counts Chrome holding the mic as a call, without asking it for its tabs.
    private let chromeIsCall = CommandLine.arguments.contains("--call-test")

    nonisolated private static let startID = "call-start", endID = "call-end"

    init(model: Recorder) {
        self.model = model
    }

    func start() {
        guard Bundle.main.bundleIdentifier != nil else { return }  // UNUserNotificationCenter needs an app bundle
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.startID, actions: [
                UNNotificationAction(identifier: "record", title: "Record"),
                UNNotificationAction(identifier: "later", title: "Not Now"),
            ], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.endID, actions: [
                UNNotificationAction(identifier: "stop", title: "Stop Now"),
                UNNotificationAction(identifier: "keep", title: "Keep Recording"),
            ], intentIdentifiers: []),
        ])
        // ponytail: polls every 2 s (a few property reads); a CoreAudio listener per process if it ever shows up in a profile.
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard UserDefaults.standard.object(forKey: "askToRecordCalls") as? Bool ?? true else {
            if call != nil { call = nil; seenSince = nil; autoStop?.cancel(); remove(Self.startID, Self.endID) }
            return
        }
        let users = micUsers()
        var app = users.lazy.compactMap(Self.callApp).first
        if app == nil, users.contains(where: Self.isChrome) {
            if chromeIsCall { meetTab = true } else if askedChrome.map({ Date().timeIntervalSince($0) >= 10 }) ?? true { askChrome() }
            if meetTab == true { app = "Google Meet" }
        } else if !users.contains(where: Self.isChrome), askedChrome != nil || meetTab != nil {
            meetTab = nil
            askedChrome = nil
            chromeTurn += 1
        }
        let now = Date()
        if app != nil { goneSince = nil; seenSince = seenSince ?? now } else { seenSince = nil; goneSince = goneSince ?? now }

        if call == nil, let app, let seenSince, now.timeIntervalSince(seenSince) >= 4 {
            call = app
            if endedAt.map({ now.timeIntervalSince($0) >= 60 }) ?? true { asked = false }
            autoStop?.cancel()
            remove(Self.endID)
            log("call started in \(app)")
        }
        if call != nil, app == nil, let goneSince, now.timeIntervalSince(goneSince) >= 10 {
            log("call ended")
            call = nil
            endedAt = now
            remove(Self.startID)
            ended()
        }
        if let call {
            if model.state == .recording { recordingInCall = model.started; asked = true; model.callApp = call }
            if model.state == .idle, !asked {
                asked = true
                post(Self.startID, title: "Call in \(call)", body: "Record it with Kagu?")
            }
        }
        if model.state != .recording, autoStop != nil {
            autoStop?.cancel()
            autoStop = nil
            remove(Self.endID)
        }
        if model.state != .idle { remove(Self.startID) }
    }

    private func ended() {
        guard model.state == .recording, let started = model.started, recordingInCall == started, keep != started else { return }
        post(Self.endID, title: "Call ended", body: "Kagu stops and saves the recording in 2 minutes.")
        autoStop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard let self, !Task.isCancelled, self.call == nil, self.model.started == started, self.keep != started else { return }
            log("calls: stopping, the call ended 2 minutes ago")
            self.model.stop(reason: "Saved: the call ended 2 minutes ago.")
        }
    }

    /// Asks Chrome for its tab addresses off the main thread (the first time macOS asks the owner to allow it).
    private func askChrome() {
        guard !askingChrome else { return }
        askingChrome = true
        askedChrome = Date()
        let turn = chromeTurn
        Task.detached {
            let found = Self.chromeHasMeetTab()
            await MainActor.run {
                self.askingChrome = false
                if self.chromeTurn == turn { self.meetTab = found }
            }
        }
    }

    nonisolated private static func chromeHasMeetTab() -> Bool {
        let script = Process()
        script.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        script.arguments = ["-e", "with timeout of 5 seconds", "-e", "tell application id \"com.google.Chrome\" to get URL of every tab of every window", "-e", "end timeout"]
        let out = Pipe(), err = Pipe()
        script.standardOutput = out
        script.standardError = err
        do { try script.run() } catch { return false }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        script.waitUntilExit()
        guard script.terminationStatus == 0 else {
            let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            log("calls: could not read Chrome tabs: \(text)")
            if text.contains("-1743") { UserDefaults.standard.set(true, forKey: "chromeTabsDenied") }  // Automation denied: Settings says so
            return false
        }
        if UserDefaults.standard.bool(forKey: "chromeTabsDenied") { UserDefaults.standard.set(false, forKey: "chromeTabsDenied") }
        return String(decoding: data, as: UTF8.self).components(separatedBy: ", ").contains { isMeet($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private func post(_ id: String, title: String, body: String) {
        // Asks once; later calls return the stored answer. Here, not at launch, so turning the switch on later also asks.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in if !granted { log("calls: notifications not allowed") } }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = id
        if let started = model.started { content.userInfo = ["started": started.timeIntervalSinceReferenceDate] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in log("calls: posted \(id)\(error.map { ", failed: \($0.localizedDescription)" } ?? "")") }
    }

    /// Something that needs the owner while Kagu's windows are behind another app (a call in full screen):
    /// a recording that stopped by itself, a warning, an error. In front, the notice in the window is enough.
    static func alert(_ title: String, _ body: String) {
        guard Bundle.main.bundleIdentifier != nil, !NSApp.isActive else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { error in log("notice posted: \(title)\(error.map { ", failed: \($0.localizedDescription)" } ?? "")") }
    }

    private func remove(_ ids: String...) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]  // also while Kagu is in front
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        let content = response.notification.request.content
        let started = (content.userInfo["started"] as? Double).map(Date.init(timeIntervalSinceReferenceDate:))
        let isStart = content.categoryIdentifier == Self.startID
        await MainActor.run { self.answer(action, isStart: isStart, started: started) }
    }

    /// A clicked start banner records, as its Record button does, while the call is still on. An answer to an end banner only acts on the recording it was about.
    private func answer(_ action: String, isStart: Bool, started: Date?) {
        if isStart, action == "record" || action == UNNotificationDefaultActionIdentifier, model.state == .idle, call != nil {
            Task { await model.start() }
            return
        }
        guard !isStart, let started, model.started == started else { return }
        if action == "stop" { model.stop() }
        if action == "keep" {
            keep = started
            autoStop?.cancel()
            autoStop = nil
        }
    }
}
