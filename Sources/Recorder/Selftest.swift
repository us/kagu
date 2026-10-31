import AVFoundation
import Foundation

/// `--selftest`: checks the logic that does not need a window, in a temporary folder.
@MainActor
enum Selftest {
    static func run() async -> [String] {
        var failures = Transcript.selfTest()
        func expect(_ ok: Bool, _ what: String) { if !ok { failures.append(what) } }

        // Turns: the far side in the mic is bleed, your own words are kept; words go to the stretch they were said in
        var far = [Float](repeating: -100, count: 600), mic = [Float](repeating: -60, count: 600)
        for i in 0..<200 { far[i] = -20; mic[i] = -35 }  // the far side, and its bleed 15 dB under it
        for i in 300..<400 { mic[i] = -30 }  // you, with the Mac quiet
        let turns = Turns.speech(me: mic, them: far)
        expect(turns.me.count == 1 && turns.me[0].lowerBound >= 290 && turns.me[0].upperBound <= 410, "bleed is not your speech: \(turns.me)")
        expect(turns.them == [0..<205], "the far side is one stretch: \(turns.them)")
        let chunks = [Turns.Chunk(packed: 0, start: 10, length: 2), Turns.Chunk(packed: 3.5, start: 20, length: 1)]
        let said = Turns.segments(words: [(0.5, "Hey,"), (1.9, "man."), (3.2, "How"), (2.6, "Thanks."), (4.0, "are")], chunks: chunks)
        expect(said == [Segment(start: 10, end: 12, text: "Hey, man."), Segment(start: 20, end: 21, text: "How are")], "words land in their stretch, one made up in the silence is dropped: \(said)")
        let job = Transcriber.Job(source: URL(fileURLWithPath: "/r/Recording 1.m4a"), title: "Recording 1", tracks: [], output: URL(fileURLWithPath: "/r/Recording 1.transcript.md"), cleanup: URL(fileURLWithPath: "/t"))
        let followed = job.following(URL(fileURLWithPath: "/r/x/Standup 2.m4a"))
        expect(followed.output.path == "/r/x/Standup 2.transcript.md" && followed.title == "Standup 2", "a job follows its recording: \(followed.output.path)")
        let heard = Transcript.merge([("You", [Segment(start: 3, end: 4, text: "Yeah."), Segment(start: 12, end: 13, text: "Yeah.")]), ("Them", [Segment(start: 0, end: 10, text: "So we ship it on Friday.")])], language: "en")
        expect(heard.lines.map(\.text) == ["So we ship it on Friday.", "Yeah."] && heard.struck.fillers == 1, "a yeah said while they talk is listening, a yeah after is an answer: \(heard.lines.map(\.text))")
        let both = Transcript.merge([("You", [Segment(start: 0, end: 0.4, text: "Yeah.")]), ("Them", [Segment(start: 0, end: 0.6, text: "Okay.")])], language: "en")
        expect(both.lines.count == 2 && both.struck.fillers == 0, "a yeah inside their okay is kept: \(both.lines.map(\.text))")
        // Calls: which mic users are a call
        expect(CallWatcher.callApp("com.hnc.Discord.helper") == "Discord" && CallWatcher.callApp("com.microsoft.teams2") == "Teams" && CallWatcher.callApp("com.apple.CoreSpeech") == nil, "call apps by bundle id")
        expect(CallWatcher.isChrome("com.google.Chrome.helper") && !CallWatcher.isChrome("com.google.Chrome.canary") && !CallWatcher.isChrome("com.google.Chrome.app.abcdef"), "Chrome, not Canary or a Chrome web app")
        expect(CallWatcher.isMeet("https://meet.google.com/abc-defg-hij?authuser=0") && !CallWatcher.isMeet("https://meet.google.com/landing") && !CallWatcher.isMeet("https://example.com/?u=https://meet.google.com/abc-defg-hij"), "a Meet call address")
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "recorder-selftest-\(UUID().uuidString)")
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        failures += TranscriptFile.selfTest(in: root)
        failures += Transcript.replaceSelfTest()
        failures += Transcript.speakerSelfTest()

        // Download verification
        let probe = root.appending(path: "probe")
        let right = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        try? Data("abc".utf8).write(to: probe)
        expect((try? ModelStore.sha256(of: probe)) == right, "sha256")
        let target = root.appending(path: "installed")
        expect((try? ModelStore.install(partial: probe, as: target, sha256: String(right.reversed()))) == nil && !fm.fileExists(atPath: probe.path) && !fm.fileExists(atPath: target.path), "a damaged download is rejected and deleted")
        try? Data("abc".utf8).write(to: probe)
        expect((try? ModelStore.install(partial: probe, as: target, sha256: right)) != nil && fm.fileExists(atPath: target.path) && !fm.fileExists(atPath: probe.path), "a good download is installed")

        // Library: names, dates, rename, collisions, tags
        let folder = root.appending(path: "Recordings")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        func touch(_ name: String) { fm.createFile(atPath: folder.appending(path: name).path, contents: Data("x".utf8)) }
        func has(_ name: String) -> Bool { fm.fileExists(atPath: folder.appending(path: name).path) }
        for name in ["Recording 2026-10-21 17.07.14.m4a", "Recording 2026-10-21 17.07.14.md", ".Recording 2026-10-21 17.07.14.tracks.m4a", "Other.m4a", "Other.md"] { touch(name) }
        let scan = Library.scan(folder, known: [:])
        expect(scan.items.count == 2, "hidden sidecar is not a recording: \(scan.items.map(\.stem))")
        guard let item = scan.items.first(where: { $0.hasDefaultName }) else { return failures + ["default name not recognised"] }
        expect(item.transcript?.lastPathComponent == "Recording 2026-10-21 17.07.14.md", "transcript is found next to the recording")
        let parts = Calendar.current.dateComponents([.hour, .minute, .second], from: item.date)
        expect(parts.hour == 17 && parts.minute == 7 && parts.second == 14, "the date comes from the name: \(item.date)")
        let second = RecordingItem(url: folder.appending(path: "Recording 2026-10-21 17.07.14 2.m4a"), date: .now, duration: 0, transcript: nil, transcriptText: "", tags: [])
        expect(second.hasDefaultName, "a second take in the same second still shows as its date")
        let relocated = item.moved(to: folder.appending(path: "Clients/Team sync.m4a"), folder: "Clients")
        expect(relocated.transcript?.path == folder.appending(path: "Clients/Team sync.md").path && relocated.folder == "Clients" && relocated.date == item.date, "a moved item points at its moved transcript: \(relocated.transcript?.path ?? "none")")
        expect(Library.cleanName(String(repeating: "ğ", count: 300)).utf8.count <= 200, "a long name is cut to fit the file system")

        let library = Library(folder: folder)
        // The title field hands back the displayed date title with plain spaces: that must not rename anything.
        expect(library.rename(item, to: item.displayTitle.normalizedSpaces) == nil && has("Recording 2026-10-21 17.07.14.m4a"), "the displayed title with plain spaces is not a new name")
        let renamed = library.rename(item, to: "Team sync")
        expect(renamed?.lastPathComponent == "Team sync.m4a", "rename returns the new file")
        expect(has("Team sync.m4a") && has("Team sync.md") && has(".Team sync.tracks.m4a"), "rename moves recording, transcript and sidecar")
        expect(!has("Recording 2026-10-21 17.07.14.m4a") && !has("Recording 2026-10-21 17.07.14.md") && !has(".Recording 2026-10-21 17.07.14.tracks.m4a"), "rename leaves nothing behind")

        guard let team = Library.scan(folder, known: [:]).items.first(where: { $0.stem == "Team sync" }) else { return failures + ["renamed recording not found"] }
        expect(library.rename(team, to: "Other")?.lastPathComponent == "Other 2.m4a", "rename onto an existing name gets a number")
        expect(has("Other.m4a") && has("Other.md") && has("Other 2.m4a") && has("Other 2.md"), "the existing recording is untouched")
        guard let other2 = Library.scan(folder, known: [:]).items.first(where: { $0.stem == "Other 2" }) else { return failures + ["Other 2 not found"] }
        expect(library.rename(other2, to: "  .hidden/x:y  ")?.lastPathComponent == "hidden-x-y.m4a", "a leading dot and slashes are cleaned")
        expect(library.rename(other2, to: "   ") == nil, "an empty name changes nothing")

        guard let tagged = Library.scan(folder, known: [:]).items.first(where: { $0.stem == "Other" }) else { return failures + ["Other not found"] }
        library.setTags(["meeting", "ideas"], for: tagged.url)
        let tags = Library.scan(folder, known: [:]).items.first(where: { $0.stem == "Other" })?.tags ?? []
        expect(Set(tags) == ["meeting", "ideas"], "Finder tags are written and read back: \(tags)")
        library.setTags([], for: tagged.url)
        expect((Library.scan(folder, known: [:]).items.first(where: { $0.stem == "Other" })?.tags ?? ["x"]).isEmpty, "tags can be removed")

        // Folders: a move takes every part and keeps the number, a rename stays in the folder, a folder that
        // still holds other files is kept when its recordings come back.
        for name in ["Move me.m4a", "Move me.md", ".Move me.tracks.m4a", "Move me.raw.caf"] { touch(name) }
        _ = Register.write("2026.99", to: folder.appending(path: "Move me.m4a"))
        try? fm.createDirectory(at: folder.appending(path: "Fake.m4a"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: folder.appending(path: "Fake.md"), withIntermediateDirectories: true)
        expect(!Library.scan(folder, known: [:]).items.contains { $0.stem == "Fake" }, "a folder named like a recording is not a recording")
        expect(!Library.subfolders(of: folder).contains { $0.hasPrefix("Fake") }, "a folder named like a part is not a sidebar folder")
        expect(Library.cleanName("Notes.md") == "Notes" && Library.cleanName("x.tracks.m4a") == "x", "names cannot end like a part")
        let made = library.createFolder("Clients")
        expect(made == "Clients" && has("Clients") && library.createFolder("Clients") == "Clients 2", "folders are made, a taken name gets a number")
        guard let mover = Library.scan(folder, known: [:]).items.first(where: { $0.stem == "Move me" }) else { return failures + ["Move me not found"] }
        let moved = library.move(mover, to: "Clients")
        expect(moved?.lastPathComponent == "Move me.m4a" && moved?.deletingLastPathComponent().lastPathComponent == "Clients", "move returns the new place")
        expect(has("Clients/Move me.m4a") && has("Clients/Move me.md") && has("Clients/.Move me.tracks.m4a") && has("Clients/Move me.raw.caf"), "a move takes every part")
        expect(!has("Move me.m4a") && !has("Move me.md") && !has(".Move me.tracks.m4a") && !has("Move me.raw.caf"), "a move leaves nothing behind")
        expect(moved.flatMap(Register.read) == "2026.99", "a move keeps the accession number")
        guard let inside = Library.scan(folder, known: [:]).items.first(where: { $0.stem == "Move me" }) else { return failures + ["moved recording not found"] }
        expect(inside.folder == "Clients", "the scan finds a recording in its folder: \(inside.folder ?? "top")")
        expect(library.rename(inside, to: "Kept inside")?.deletingLastPathComponent().lastPathComponent == "Clients" && has("Clients/Kept inside.md"), "a rename stays in the folder")
        expect(library.renameFolder("Clients", to: "Customers") == "Customers" && has("Customers/Kept inside.m4a") && !has("Clients"), "a folder rename keeps its recordings")
        touch("Customers/stray.wav")
        let deleted = library.deleteFolder("Customers")
        expect(has("Kept inside.m4a") && has("Kept inside.md") && has(".Kept inside.tracks.m4a") && has("Kept inside.raw.caf"), "deleting a folder brings its recordings back with every part")
        expect(deleted.note != nil && has("Customers/stray.wav"), "a folder that still holds other files is kept, and the user is told")
        expect(deleted.moved.values.map(\.lastPathComponent) == ["Kept inside.m4a"], "delete folder reports where each recording went")
        expect(library.createFolder("recordings") == "New Folder", "a subfolder cannot be called Recordings")
        guard let lower = Library.scan(folder, known: [:]).items.first(where: { $0.stem == "Kept inside" }) else { return failures + ["Kept inside not found"] }
        expect(library.rename(lower, to: "KEPT inside")?.lastPathComponent == "KEPT inside.m4a" && has("KEPT inside.md"), "a rename that only changes case is not taken for a new name")
        // ponytail: the empty-folder delete goes through the real Trash, so it is not run here.

        // Register: numbers are given oldest first, written on the file, kept by a rename and never given twice
        let shelf = root.appending(path: "Register")
        try? fm.createDirectory(at: shelf, withIntermediateDirectories: true)
        for stamp in ["2026-05-02 10.00.00", "2025-03-01 10.00.00", "2026-01-02 10.00.00"] { fm.createFile(atPath: shelf.appending(path: "Recording \(stamp).m4a").path, contents: Data("x".utf8)) }
        var register = Register(folder: shelf)
        defer { UserDefaults.standard.removeObject(forKey: register.key); UserDefaults.standard.removeObject(forKey: Register(folder: folder).key) }
        let numbered = register.number(Library.scan(shelf, known: [:]).items).sorted { $0.date < $1.date }.map(\.accession)
        expect(numbered == ["2025.1", "2026.1", "2026.2"], "accession numbers, oldest first: \(numbered)")
        expect(Library.scan(shelf, known: [:]).items.compactMap(\.accession).sorted() == ["2025.1", "2026.1", "2026.2"], "the number is read back from the file")
        try? fm.removeItem(at: shelf.appending(path: "Recording 2026-05-02 10.00.00.m4a"))
        fm.createFile(atPath: shelf.appending(path: "Recording 2026-06-01 10.00.00.m4a").path, contents: Data("x".utf8))
        let again = register.number(Library.scan(shelf, known: [:]).items)
        expect(again.first { $0.stem.hasSuffix("2026-06-01 10.00.00") }?.accession == "2026.3", "a deleted number is not given again: \(again.map(\.accession))")
        expect(register.total - again.filter { $0.accession != nil }.count == 1, "the deleted one counts as withdrawn")
        expect(register.next(for: Date(timeIntervalSince1970: 1_800_000_000)) == "2027.1", "a new year starts at 1")
        expect(SaveRate.median([3, 1, 2]) == 2 && SaveRate.median([1, 2, 3, 4]) == 2.5 && SaveRate.median([]) == 80.0 / 3600, "save rate median")

        // Sidecar: two tracks in, the same two tracks out
        let tracks = root.appending(path: "tracks")
        do {
            let sink = try TrackSink(folder: tracks, sampleRate: 48_000)
            let n = 48_000 * 2
            var mic = [Float](repeating: 0, count: n), sys = [Float](repeating: 0, count: n)
            for i in 0..<n { mic[i] = i < n / 2 ? 0.5 * sinf(Float(i) * 0.05) : 0; sys[i] = i >= n / 2 ? 0.5 * sinf(Float(i) * 0.03) : 0 }
            try mic.withUnsafeBufferPointer { m in try sys.withUnsafeBufferPointer { s in try sink.feed(mic: m.baseAddress!, left: s.baseAddress!, right: s.baseAddress!, count: n) } }
            try sink.finish()
            let sidecar = root.appending(path: ".x.tracks.m4a")
            try Tracks.writeSidecar(me: sink.me.url, them: sink.them.url, to: sidecar)
            let back = root.appending(path: "back")
            try Tracks.splitSidecar(sidecar, into: back)
            let me = try AVAudioFile(forReading: back.appending(path: "me.wav"))
            let them = try AVAudioFile(forReading: back.appending(path: "them.wav"))
            expect(abs(me.length - 32_000) < 2_000 && abs(them.length - 32_000) < 2_000, "sidecar keeps the length: \(me.length) \(them.length)")
            let meFirst = Waveform.peaks(in: me, count: 4), themFirst = Waveform.peaks(in: them, count: 4)
            // Quarters, so the boundary (which falls inside a 512 frame block) does not matter.
            expect(meFirst[0] > 0.3 && meFirst[3] < 0.1, "you are loud in the first half only: \(meFirst)")
            expect(themFirst[3] > 0.3 && themFirst[0] < 0.1, "them are loud in the second half only: \(themFirst)")
        } catch {
            failures.append("sidecar round trip: \(error)")
        }

        // Waveform
        let peaks = await Waveform.peaks(url: root.appending(path: "tracks/me.wav"), count: 96)
        expect(peaks.count == 96 && (peaks.max() ?? 0) > 0.99, "waveform has 96 values scaled to 1")
        return failures
    }
}
