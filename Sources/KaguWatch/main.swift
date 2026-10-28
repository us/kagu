import Calls
import CoreAudio
import Darwin
import Foundation

// KaguWatch: the only part of Kagu that stays running (a launch agent). It sleeps until Core Audio says an app
// started or stopped using a mic; when a call app (or Chrome, which Kagu then asks about Google Meet) holds one
// for 4 s, it opens Kagu without a window, and Kagu asks to record the call.

let system = AudioObjectID(kAudioObjectSystemObject)
let queue = DispatchQueue(label: "watch")
/// .../Kagu.app/Contents/MacOS/KaguWatch -> .../Kagu.app
let app = URL(fileURLWithPath: path(of: getpid())).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let kagu = app.appending(path: "Contents/MacOS/Recorder").path
// The state below is only touched on `queue`.
/// Processes whose mic use is listened to already.
nonisolated(unsafe) var watched: Set<AudioObjectID> = []
nonisolated(unsafe) var pending: DispatchWorkItem?
/// The apps Kagu was opened for: not again for one until it lets go of the mic (Kagu may have found no call there).
nonisolated(unsafe) var opened: Set<String> = []

func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
}

func processes() -> [AudioObjectID] {
    var addr = address(kAudioHardwarePropertyProcessObjectList)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.stride)
    guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &list) == noErr else { return [] }
    return Array(list.prefix(Int(size) / MemoryLayout<AudioObjectID>.stride))
}

func usesMic(_ process: AudioObjectID) -> Bool {
    var addr = address(kAudioProcessPropertyIsRunningInput)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(process, &addr, 0, nil, &size, &value) == noErr && value != 0
}

func bundleID(_ process: AudioObjectID) -> String? {
    var addr = address(kAudioProcessPropertyBundleID)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(process, &addr, 0, nil, &size, &value) == noErr else { return nil }
    return value?.takeRetainedValue() as String?  // Core Audio hands over a retained string
}

func log(_ text: String) {
    let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/Recorder.log")
    guard let handle = try? FileHandle(forWritingTo: url) else { return }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: Data("\(Date().formatted(.iso8601)) watch: \(text)\n".utf8))
    try? handle.close()
}

func path(of pid: pid_t) -> String {
    var path = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return "" }
    return String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

func kaguRunning() -> Bool {
    var pids = [pid_t](repeating: 0, count: 4096)
    let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
    return pids.prefix(max(count, 0)).contains { path(of: $0) == kagu }
}

/// Listens to every audio process's mic use; a new process shows up through the process list listener.
func watchProcesses() {
    for process in processes() where !watched.contains(process) {
        var addr = address(kAudioProcessPropertyIsRunningInput)
        if AudioObjectAddPropertyListenerBlock(process, &addr, queue, { _, _ in changed() }) == noErr { watched.insert(process) }
    }
    watched.formIntersection(processes())
}

/// A mic started or stopped somewhere: look in 4 s, so a brief use (a sound check, dictation) is let go.
/// Counted from the first change, so steady changes (sounds starting and stopping) never put it off.
func changed(after seconds: Double = 4) {
    guard pending == nil else { return }
    let work = DispatchWorkItem {
        pending = nil
        check()
    }
    pending = work
    queue.asyncAfter(deadline: .now() + seconds, execute: work)
}

func check() {
    // By app name, so Chrome and its helper process count as one.
    let calls = Set(processes().filter(usesMic).compactMap(bundleID).compactMap { Calls.callApp($0) ?? (Calls.isChrome($0) ? "Chrome" : nil) })
    opened.formIntersection(calls)
    guard let call = calls.subtracting(opened).first else { return }
    opened.formUnion(calls)
    guard !kaguRunning() else { return }  // Kagu watches calls itself while it runs (and does not quit while a call app holds a mic)
    log("\(call) holds a mic, opening Kagu")
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = ["-g", "--env", "KAGU_CALL=1"] + (Calls.testApp.map { ["--env", "KAGU_WATCH_AS_CALL=\($0)"] } ?? []) + [app.path]
    do { try open.run() } catch { log("could not open Kagu: \(error.localizedDescription)") }
}

queue.async {
    log("started for \(app.path)")
    var list = address(kAudioHardwarePropertyProcessObjectList)
    AudioObjectAddPropertyListenerBlock(system, &list, queue) { _, _ in
        watchProcesses()
        changed()
    }
    watchProcesses()
    changed()  // a call already going on when the watch starts
}
dispatchMain()
