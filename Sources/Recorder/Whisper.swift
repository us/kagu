import Foundation
import Synchronization

struct Segment: Sendable, Equatable {
    var start: Double  // seconds
    var end: Double
    var text: String
}

/// Owns the running `whisper-cli` so a quit or a cancel can stop it.
final class WhisperProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var launched = false

    fileprivate func set(_ p: Process) -> Bool {
        lock.withLock {
            guard !cancelled else { return false }
            process = p
            return true
        }
    }

    /// Called right after `Process.run()`; stops the child if a cancel arrived in between.
    fileprivate func didLaunch() {
        lock.withLock {
            launched = true
            if cancelled { process?.terminate() }
        }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            if launched { process?.terminate() }  // terminate() on a process that never started raises
        }
    }

    var isCancelled: Bool { lock.withLock { cancelled } }
}

enum Whisper {
    static var binary: URL? { Bundle.main.url(forAuxiliaryExecutable: "whisper-cli") }
    static var vadModel: URL? { Bundle.main.url(forResource: "ggml-silero-v5.1.2", withExtension: "bin") }

    /// Transcribes each WAV in `tracks` with one model load. `progress` gets 0 to 1 over all tracks.
    ///
    /// `-mc 20` keeps a very short carry of text, with a one line prompt that is always prepended:
    /// that is what makes Whisper punctuate and capitalise (with no context at all it often writes
    /// lowercase text without a single full stop). A long carry makes it repeat itself, so it stays
    /// short; the result was checked against `-mc 0` on a 68 minute meeting (same terms found).
    /// `--vad` skips silence, so it cannot invent text there; the segment times in the JSON are on
    /// the original timeline (token times are not, so they are not used).
    static func run(model: URL, tracks: [URL], language: String, handle: WhisperProcess, progress: @escaping @Sendable (Double) -> Void) async throws -> [[Segment]] {
        guard let binary, let vad = vadModel else { throw RecorderError("The transcription engine is missing from the app.") }
        var arguments = ["-m", model.path, "-l", language, "-mc", "20", "--carry-initial-prompt", "--prompt", prompt(for: language), "--vad", "-vm", vad.path, "-oj", "-pp"]
        for track in tracks { arguments += ["-f", track.path] }

        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.qualityOfService = .utility  // the Mac stays usable while a long meeting is transcribed
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice

        let state = Mutex(ProgressState(total: tracks.count))
        defer { errors.fileHandleForReading.readabilityHandler = nil }
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let value = state.withLock { $0.consume(String(decoding: data, as: UTF8.self)) }
            if let value { progress(value) }
        }

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                guard handle.set(process) else { return continuation.resume(throwing: CancellationError()) }
                try process.run()
                try? errors.fileHandleForWriting.close()  // only the child holds the write end, so reading ends at EOF
                handle.didLaunch()
            } catch {
                continuation.resume(throwing: error)
            }
        }
        errors.fileHandleForReading.readabilityHandler = nil
        let rest = errors.fileHandleForReading.readDataToEndOfFile()  // what the handler had not read yet
        if !rest.isEmpty { _ = state.withLock { $0.consume(String(decoding: rest, as: UTF8.self) + "\n") } }
        if handle.isCancelled { throw CancellationError() }
        guard status == 0 else {
            let tail = state.withLock { $0.tail }
            log("whisper exited with \(status): \(tail)")
            throw RecorderError("Transcription stopped unexpectedly. Try again.")
        }
        return try tracks.map { try segments(in: URL(fileURLWithPath: $0.path + ".json")) }
    }

    /// A short sentence with punctuation, in the language it nudges. Other languages get the English one:
    /// with a Turkish recording and "auto" it did not pull the text out of Turkish.
    static func prompt(for language: String) -> String {
        language == "tr" ? "Merhaba, herkese. Başlayalım." : "Hello, everyone. Let's get started."
    }

    /// Reads `segments` from whisper's `-oj` file.
    static func segments(in json: URL) throws -> [Segment] {
        struct File: Decodable {
            struct Offsets: Decodable { let from: Int; let to: Int }
            struct Item: Decodable { let offsets: Offsets; let text: String }
            let transcription: [Item]
        }
        // whisper.cpp can cut a multi-byte character between two segments; a strict decode would refuse the whole file.
        let file = try JSONDecoder().decode(File.self, from: Data(String(decoding: try Data(contentsOf: json), as: UTF8.self).utf8))
        return file.transcription.map { Segment(start: Double($0.offsets.from) / 1000, end: Double($0.offsets.to) / 1000, text: $0.text) }
    }
}

/// Turns whisper's stderr (`progress =  52%`, repeated per file) into one 0 to 1 value over all files.
struct ProgressState {
    let total: Int
    private var done = 0
    private var last = 0.0
    private var pending = ""
    private(set) var tail = ""

    init(total: Int) { self.total = max(1, total) }

    mutating func consume(_ text: String) -> Double? {
        pending += text
        var latest: Double?
        while let newline = pending.firstIndex(of: "\n") {
            let line = String(pending[..<newline])
            pending = String(pending[pending.index(after: newline)...])
            if !line.isEmpty { tail = line }
            guard let range = line.range(of: #"progress =\s*(\d+)%"#, options: .regularExpression),
                  let percent = Double(line[range].filter(\.isNumber)) else { continue }
            if percent < last { done += 1 }  // the percentage starts again: the next file
            last = percent
            latest = min(1, (Double(done) + percent / 100) / Double(total))
        }
        return latest
    }
}
