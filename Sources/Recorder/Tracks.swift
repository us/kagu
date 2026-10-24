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
    static func sweep() {
        let items = (try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for item in items {
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
