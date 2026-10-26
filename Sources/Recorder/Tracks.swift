import AVFoundation
import Foundation

/// Streams mono float samples at any rate into a 16 kHz mono 16 bit WAV, the format Whisper reads.
final class TrackWriter {
    static let rate = 16_000.0

    let url: URL
    private let file: AVAudioFile
    private let inFormat: AVAudioFormat
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
    private let converter: AVAudioConverter?

    init(url: URL, sampleRate: Double) throws {
        self.url = url
        inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        converter = sampleRate == Self.rate ? nil : AVAudioConverter(from: inFormat, to: outFormat)
        file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Self.rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    func write(_ samples: UnsafePointer<Float>, count: Int) throws {
        guard count > 0 else { return }
        // The caller's pointer is only valid during the call, so the samples are copied first.
        let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(count))!
        input.frameLength = AVAudioFrameCount(count)
        input.floatChannelData![0].update(from: samples, count: count)
        guard converter != nil else { return try file.write(from: input) }
        try convert(input)
    }

    /// Flushes the resampler. Call once, after the last `write`.
    func finish() throws {
        if converter != nil { try convert(nil) }
        file.close()  // writes the WAV header with the final length, so the file can be read at once
    }

    private func convert(_ input: AVAudioPCMBuffer?) throws {
        guard let converter else { return }
        let frames = Double(input?.frameLength ?? 0)
        let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount((frames * Self.rate / inFormat.sampleRate).rounded(.up)) + 1024)!
        nonisolated(unsafe) var pending = input
        let atEnd = input == nil
        var failure: NSError?
        let status = converter.convert(to: out, error: &failure) { _, status in
            if let buffer = pending {
                pending = nil
                status.pointee = .haveData
                return buffer
            }
            status.pointee = atEnd ? .endOfStream : .noDataNow
            return nil
        }
        if status == .error { throw failure ?? RecorderError("Could not resample the audio.") }
        if out.frameLength > 0 { try file.write(from: out) }
    }
}

/// The two tracks written while a recording is converted: the echo cleaned mic and the system audio.
final class TrackSink {
    let folder: URL
    let me: TrackWriter
    let them: TrackWriter
    private var mix: [Float] = []

    init(folder: URL, sampleRate: Double) throws {
        self.folder = folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        me = try TrackWriter(url: folder.appending(path: "me.wav"), sampleRate: sampleRate)
        them = try TrackWriter(url: folder.appending(path: "them.wav"), sampleRate: sampleRate)
    }

    func feed(mic: UnsafePointer<Float>, left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int) throws {
        if mix.count < count { mix = [Float](repeating: 0, count: count) }
        for i in 0..<count { mix[i] = (left[i] + right[i]) / 2 }
        try me.write(mic, count: count)
        try mix.withUnsafeBufferPointer { try them.write($0.baseAddress!, count: count) }
    }

    func finish() throws {
        try me.finish()
        try them.finish()
    }
}

enum Tracks {
    /// A small hidden copy of the two tracks (mic left, Mac audio right, 16 kHz AAC) kept next to a recording,
    /// so a transcript made weeks later can still tell the two sides apart.
    static func writeSidecar(me: URL, them: URL, to url: URL) throws {
        let left = try AVAudioFile(forReading: me, commonFormat: .pcmFormatFloat32, interleaved: false)
        let right = try AVAudioFile(forReading: them, commonFormat: .pcmFormatFloat32, interleaved: false)
        let partial = url.deletingPathExtension().appendingPathExtension("partial.m4a")  // the extension decides the container
        try? FileManager.default.removeItem(at: partial)
        var moved = false
        defer { if !moved { try? FileManager.default.removeItem(at: partial) } }
        let out = try AVAudioFile(forWriting: partial, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: TrackWriter.rate, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 96_000,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk: AVAudioFrameCount = 1 << 15
        let a = AVAudioPCMBuffer(pcmFormat: left.processingFormat, frameCapacity: chunk)!
        let b = AVAudioPCMBuffer(pcmFormat: right.processingFormat, frameCapacity: chunk)!
        let stereo = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: TrackWriter.rate, channels: 2, interleaved: false)!, frameCapacity: chunk)!
        while left.framePosition < left.length {
            try left.read(into: a, frameCount: chunk)
            try right.read(into: b, frameCount: chunk)
            let n = Int(min(a.frameLength, b.frameLength))
            if n == 0 { break }
            let data = stereo.floatChannelData!
            data[0].update(from: a.floatChannelData![0], count: n)
            data[1].update(from: b.floatChannelData![0], count: n)
            stereo.frameLength = AVAudioFrameCount(n)
            try out.write(from: stereo)
        }
        out.close()  // the encoder writes its last packets and the header on close
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: partial, to: url)
        moved = true
    }

    /// The reverse: me.wav and them.wav in `folder`, ready for Whisper.
    static func splitSidecar(_ url: URL, into folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let input = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard input.processingFormat.channelCount == 2 else { throw RecorderError("This recording has no separate tracks.") }
        let me = try TrackWriter(url: folder.appending(path: "me.wav"), sampleRate: input.processingFormat.sampleRate)
        let them = try TrackWriter(url: folder.appending(path: "them.wav"), sampleRate: input.processingFormat.sampleRate)
        let chunk: AVAudioFrameCount = 1 << 15
        let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: chunk)!
        while input.framePosition < input.length {
            try input.read(into: buffer, frameCount: chunk)
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            try me.write(buffer.floatChannelData![0], count: n)
            try them.write(buffer.floatChannelData![1], count: n)
        }
        try me.finish()
        try them.finish()
    }

    static let cache = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches/Recorder")

    /// Folder for the tracks of one recording; `stamp` is the date text in the recording's name.
    static func folder(stamp: String) -> URL { cache.appending(path: stamp) }

    /// Removes track folders older than a day: an interrupted transcription leaves its tracks behind.
    static func sweep(keeping: Set<URL> = []) {
        let items = (try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for item in items where !keeping.contains(item.standardizedFileURL) {
            let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if modified < Date(timeIntervalSinceNow: -86_400) { try? FileManager.default.removeItem(at: item) }
        }
    }

    /// Converts any audio file to one 16 kHz mono WAV in `folder`; several channels are averaged.
    static func convertFile(_ source: URL, into folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        let channels = Int(input.processingFormat.channelCount)
        let writer = try TrackWriter(url: folder.appending(path: "speaker.wav"), sampleRate: input.processingFormat.sampleRate)
        let chunk: AVAudioFrameCount = 1 << 16
        let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: chunk)!
        var mono = [Float](repeating: 0, count: Int(chunk))
        while input.framePosition < input.length {
            try input.read(into: buffer, frameCount: chunk)
            let n = Int(buffer.frameLength)
            if n == 0 { break }  // mp3 and m4a report an estimated length; a read at the real end returns nothing
            let c = buffer.floatChannelData!
            for i in 0..<n {
                var sum: Float = 0
                for ch in 0..<channels { sum += c[ch][i] }
                mono[i] = sum / Float(channels)
            }
            try mono.withUnsafeBufferPointer { try writer.write($0.baseAddress!, count: n) }
        }
        try writer.finish()
        return writer.url
    }
}

/// Who spoke when, read from the levels of the two tracks instead of guessed by Whisper.
/// The Mac audio is clean, so the far side speaks where it is loud. The mic also hears the far side through the
/// speakers, a steady 10 to 16 dB under the Mac audio after echo removal; a mic frame is your speech only when it is
/// louder than what the Mac audio of the last 300 ms can leave in it.
enum Turns {
    static let hop = 320  // 20 ms at 16 kHz
    static let gap = 1.5  // seconds of silence between two stretches in a packed file

    /// One stretch of speech: where it sits in the packed WAV and where it was in the recording, in seconds.
    struct Chunk: Equatable, Sendable {
        var packed: Double
        var start: Double
        var length: Double
    }

    /// The stretches of your speech and of the far side, as ranges of 20 ms frames.
    static func speech(me: [Float], them: [Float]) -> (me: [Range<Int>], them: [Range<Int>]) {
        let n = min(me.count, them.count)
        guard n > 0 else { return ([], []) }
        let farOn = (0..<n).map { them[$0] > -50 }
        // How much of the Mac audio the mic hears: the median over the minute around each second, since it changes
        // when the headphones come off or the volume moves; the whole call where a minute has too little Mac audio.
        let heard = (0..<n).filter { farOn[$0] }
        let all = heard.map { me[$0] - them[$0] }
        let whole = all.isEmpty ? nil : all.sorted()[all.count / 2]
        let coupling: [Float?] = stride(from: 0, to: n, by: 50).map { second in
            let from = firstAtLeast(heard, second - 1500), to = firstAtLeast(heard, second + 1550)
            guard to - from >= 150 else { return whole }
            let near = all[from..<to].sorted()
            return near[near.count / 2]
        }
        // The room with nobody talking: low enough that a talkative mic is not its own floor, and not digital silence.
        let room = me[..<n].filter { $0 > -90 }.sorted()
        let floor = room.isEmpty ? -90 : room[room.count / 20]
        var own = [Bool](repeating: false, count: n)
        for i in 0..<n where me[i] > floor + 8 {
            let ring = them[max(0, i - 15)...i].max()!  // the Mac audio of the last 300 ms still rings in the room
            own[i] = coupling[i / 50].map { me[i] > ring + $0 + 6 } ?? true
        }
        return (stretches(own, least: 8, levels: me), stretches(farOn, least: 8, levels: them))
    }

    /// The index of the first value in `sorted` that is at least `value`.
    private static func firstAtLeast(_ sorted: [Int], _ value: Int) -> Int {
        var low = 0, high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid] < value { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Frames joined over pauses up to 0.7 s and padded by 0.1 s; a stretch needs `least` frames of sound (a click
    /// or one loud frame is not speech) and is cut at its quietest frame when longer than 20 s (so a word's time
    /// always points into a short stretch).
    static func stretches(_ on: [Bool], least: Int, levels: [Float]) -> [Range<Int>] {
        var joined: [(range: Range<Int>, sound: Int)] = []
        for i in on.indices where on[i] {
            let frame = max(0, i - 5)..<min(on.count, i + 6)
            if let last = joined.last, frame.lowerBound - last.range.upperBound <= 25 {
                joined[joined.count - 1] = (last.range.lowerBound..<max(last.range.upperBound, frame.upperBound), last.sound + 1)
            } else {
                joined.append((frame, 1))
            }
        }
        var out: [Range<Int>] = []
        for (whole, sound) in joined where sound >= least {
            var range = whole
            while range.count > 1000 {
                let window = (range.lowerBound + 500)..<(range.lowerBound + 1000)
                let cut = window.min { levels[$0] < levels[$1] }!
                out.append(range.lowerBound..<cut)
                range = cut..<range.upperBound
            }
            out.append(range)
        }
        return out
    }

    /// Levels of a 16 kHz mono WAV in dBFS, one per 20 ms.
    static func levels(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(hop * 512))!
        var out: [Float] = []
        while file.framePosition < file.length {
            try file.read(into: buffer)
            let n = Int(buffer.frameLength) / hop
            if buffer.frameLength == 0 { break }
            let samples = buffer.floatChannelData![0]
            for f in 0..<n {
                var sum: Float = 0
                for i in (f * hop)..<((f + 1) * hop) { sum += samples[i] * samples[i] }
                out.append(10 * log10(sum / Float(hop) + 1e-10))
            }
        }
        return out
    }

    /// Writes the stretches of `source` one after another, with `gap` seconds of silence after each, to `url`.
    static func pack(_ source: URL, _ ranges: [Range<Int>], to url: URL) throws -> [Chunk] {
        let input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        let writer = try TrackWriter(url: url, sampleRate: TrackWriter.rate)
        let silence = [Float](repeating: 0, count: Int(gap * TrackWriter.rate))
        var chunks: [Chunk] = []
        var at = 0
        for range in ranges {
            let count = range.count * hop
            let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: AVAudioFrameCount(count))!
            input.framePosition = AVAudioFramePosition(range.lowerBound * hop)
            try input.read(into: buffer, frameCount: AVAudioFrameCount(count))
            let n = Int(buffer.frameLength)
            try writer.write(buffer.floatChannelData![0], count: n)
            try silence.withUnsafeBufferPointer { try writer.write($0.baseAddress!, count: $0.count) }
            chunks.append(Chunk(packed: Double(at) / TrackWriter.rate, start: Double(range.lowerBound * hop) / TrackWriter.rate, length: Double(n) / TrackWriter.rate))
            at += n + silence.count
        }
        try writer.finish()
        return chunks
    }

    /// The speech of `me` and `them` (16 kHz mono WAVs), each packed next to its source as `<name>.turns.wav`.
    static func pack(me: URL, them: URL) throws -> [(wav: URL, chunks: [Chunk])] {
        let ranges = speech(me: try levels(me), them: try levels(them))
        return try [(me, ranges.me), (them, ranges.them)].map { source, ranges in
            let wav = source.deletingPathExtension().appendingPathExtension("turns.wav")
            return (wav, try pack(source, ranges, to: wav))
        }
    }

    /// One Segment per stretch: a word belongs to the stretch it was spoken in, found by its time in the packed file.
    static func segments(words: [(time: Double, text: String)], chunks: [Chunk]) -> [Segment] {
        guard !chunks.isEmpty else { return [] }
        var texts = [[String]](repeating: [], count: chunks.count)
        for word in words {
            // A time in the silence between two stretches is closest to the stretch after it when past its middle.
            let index = chunks.lastIndex { $0.packed - gap / 2 <= word.time } ?? 0
            // Deep in the silence there was nothing to hear: that is text the model made up ("Thank you.").
            let chunk = chunks[index]
            guard word.time > chunk.packed - 0.4, word.time < chunk.packed + chunk.length + 0.4 else { continue }
            texts[index].append(word.text)
        }
        return zip(chunks, texts).compactMap { chunk, words in
            words.isEmpty ? nil : Segment(start: chunk.start, end: chunk.start + chunk.length, text: words.joined(separator: " "))
        }
    }
}
