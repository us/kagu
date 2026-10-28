import AVFoundation
import Foundation

/// Linear up to 0.8, then a gentle curve that never passes 1: a boosted voice on top of loud audio must not clip.
private func softClip(_ x: Float) -> Float {
    let a = abs(x)
    if a <= 0.8 { return x }
    return (x < 0 ? -1 : 1) * (0.8 + 0.2 * tanhf((a - 0.8) / 0.2))
}

enum Convert {
    /// Mixes the 3 channel CAF (mic, system L, system R) into a mono AAC m4a, the format Whisper reads: the mic,
    /// with the speaker echo removed, over the system audio, and one gain for the whole file keeps the loudest
    /// moment under full scale. The m4a is written under a temporary name and moved into place only
    /// when it reads back with the full length; then the CAF is deleted. The same pass also writes the
    /// cleaned mic and the system audio as two 16 kHz mono WAVs into `tracksFolder` (returned; it is
    /// removed again if the conversion fails) and a small hidden sidecar next to the m4a, so a transcript
    /// can be made later with the two sides apart. The caller deletes `tracksFolder` unless it transcribes now.
    @discardableResult
    static func run(caf: URL, to m4a: URL, keepRaw: Bool, cancelEcho: Bool = true, tracksFolder: URL) throws -> URL {
        let input = try AVAudioFile(forReading: caf, commonFormat: .pcmFormatFloat32, interleaved: false)
        let rate = input.processingFormat.sampleRate
        guard input.processingFormat.channelCount == 3 else { throw RecorderError("\(caf.lastPathComponent) is not a Kagu file.") }
        let frame = EchoCanceller.frameSize(sampleRate: rate)
        let chunk = frame * 128  // a whole number of canceller frames
        let inBuffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: AVAudioFrameCount(chunk))!
        let mic = UnsafeMutablePointer<Float>.allocate(capacity: chunk)
        let reference = UnsafeMutablePointer<Float>.allocate(capacity: chunk)
        defer { mic.deallocate(); reference.deallocate() }

        /// Reads the whole file, handing each chunk's cleaned mic and the system channels to `body`.
        /// A fresh canceller each time, so every pass sees the same cleaned mic (Speex is deterministic).
        func pass(cancelEcho: Bool, _ body: (_ mic: UnsafePointer<Float>, _ rawMic: UnsafePointer<Float>, _ left: UnsafePointer<Float>, _ right: UnsafePointer<Float>, _ count: Int) throws -> Void) throws -> EchoCanceller? {
            input.framePosition = 0
            let canceller = cancelEcho ? EchoCanceller(sampleRate: rate) : nil
            while input.framePosition < input.length {
                try input.read(into: inBuffer, frameCount: AVAudioFrameCount(chunk))
                if inBuffer.frameLength == 0 { break }  // a file shorter than its header says; the length check below catches it
                let c = inBuffer.floatChannelData!
                let n = Int(inBuffer.frameLength)
                mic.update(from: c[0], count: n)
                if let canceller {
                    let padded = (n + frame - 1) / frame * frame  // the last partial frame is zero padded
                    for i in 0..<padded {
                        reference[i] = i < n ? (c[1][i] + c[2][i]) / 2 : 0
                        if i >= n { mic[i] = 0 }
                    }
                    for start in stride(from: 0, to: padded, by: frame) {
                        canceller.process(mic: mic + start, reference: reference + start)
                    }
                }
                try body(mic, c[0], c[1], c[2], n)
            }
            return canceller
        }

        // Pass 1 finds the peak for both outcomes and whether there is any echo to remove at all. The peak depends on
        // the mic boost, which is only known after this pass, so it is kept for each boost the mic can get.
        let boosts: [Float] = [1, 1.5, 2, 3, 4, 5, 6]
        var cleanPeaks = [Float](repeating: 0, count: boosts.count), rawPeaks = cleanPeaks
        // Loudness of the voice parts only (samples above about -42 dBFS), for the mic and for the Mac audio.
        var micSquares = 0.0, micCount = 0.0, sysSquares = 0.0, sysCount = 0.0
        let floor: Float = 0.008
        let probe = try pass(cancelEcho: cancelEcho) { m, raw, l, r, n in
            for i in 0..<n {
                for (k, b) in boosts.enumerated() {
                    cleanPeaks[k] = max(cleanPeaks[k], abs(l[i] + m[i] * b), abs(r[i] + m[i] * b))
                    rawPeaks[k] = max(rawPeaks[k], abs(l[i] + raw[i] * b), abs(r[i] + raw[i] * b))
                }
                if abs(m[i]) > floor { micSquares += Double(m[i] * m[i]); micCount += 1 }
                let system = (l[i] + r[i]) / 2
                if abs(system) > floor { sysSquares += Double(system * system); sysCount += 1 }
            }
        }
        // A quiet mic (the input volume of the Mac is often low) is brought up to the level of the other
        // side, or to a normal speech level when nobody else talks. Never turned down, at most 6 times up.
        let minimum = rate  // one second of voice, else there is nothing to measure
        let micRMS = micCount > minimum ? Float((micSquares / micCount).squareRoot()) : 0
        let sysRMS = sysCount > minimum ? Float((sysSquares / sysCount).squareRoot()) : 0
        let wanted: Float = micRMS > 0 ? min(6, max(1, max(sysRMS, 0.07) / micRMS)) : 1
        let step = boosts.lastIndex { $0 <= wanted } ?? 0  // the boost is rounded down to one whose peak is known
        let micGain = boosts[step]
        let reduction = probe?.echoReductionDB ?? 0
        let removeEcho = reduction >= 2  // headphones measure about 0.4 dB: then the mic stays exactly as recorded
        let peak = removeEcho ? cleanPeaks[step] : rawPeaks[step]
        let gain = peak > 0.9 ? 0.9 / peak : 1  // AAC overshoots peaks a little, keep 1 dB of room

        let partial = m4a.deletingPathExtension().appendingPathExtension("partial.m4a")
        try? FileManager.default.removeItem(at: partial)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let output = try AVAudioFile(forWriting: partial, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        var finished = false
        defer {
            if !finished {
                try? FileManager.default.removeItem(at: partial)
                try? FileManager.default.removeItem(at: tracksFolder)
            }
        }
        let sink = try TrackSink(folder: tracksFolder, sampleRate: rate)
        let outBuffer = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!, frameCapacity: AVAudioFrameCount(chunk))!
        // Test aid behind --keep-raw: the cleaned mic alone, so the canceller can be scored exactly.
        let cleanMic = keepRaw ? try AVAudioFile(forWriting: m4a.deletingPathExtension().appendingPathExtension("mic-clean.caf"), settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false) : nil
        let monoBuffer = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!, frameCapacity: AVAudioFrameCount(chunk))!
        var boosted = [Float](repeating: 0, count: chunk)
        let cleaner = try pass(cancelEcho: removeEcho) { m, _, l, r, n in
            let o = outBuffer.floatChannelData!
            for i in 0..<n {
                boosted[i] = softClip(m[i] * micGain)
                o[0][i] = softClip(((l[i] + r[i]) / 2 + m[i] * micGain) * gain)  // never louder than the left or right sum the peak was taken from
            }
            outBuffer.frameLength = AVAudioFrameCount(n)
            try output.write(from: outBuffer)
            try boosted.withUnsafeBufferPointer { try sink.feed(mic: $0.baseAddress!, left: l, right: r, count: n) }
            if let cleanMic {
                monoBuffer.floatChannelData![0].update(from: m, count: n)
                monoBuffer.frameLength = AVAudioFrameCount(n)
                try cleanMic.write(from: monoBuffer)
            }
        }
        output.close()
        cleanMic?.close()
        try sink.finish()

        let written = try AVAudioFile(forReading: partial).length
        log("convert: \(caf.lastPathComponent) \(input.length) frames, gain \(gain), mic gain \(String(format: "%.1f", micGain)) (mic \(String(format: "%.3f", micRMS)), mac \(String(format: "%.3f", sysRMS))), echo reduction \(String(format: "%.1f", reduction)) dB, removal \(cleaner.map { "on, \($0.guardedFrames) frames kept raw" } ?? "off"), m4a \(written) frames")
        guard abs(written - input.length) <= 2048 else {
            throw RecorderError("The saved recording is incomplete.")
        }
        // Before the m4a appears: once the recording is in the library it is whole, so a rename or a transcript
        // made right away has both sides.
        do { try Tracks.writeSidecar(me: sink.me.url, them: sink.them.url, to: Library.sidecarURL(for: m4a)) } catch { log("sidecar failed: \(error)") }
        if FileManager.default.fileExists(atPath: m4a.path) {
            _ = try FileManager.default.replaceItemAt(m4a, withItemAt: partial)
        } else {
            try FileManager.default.moveItem(at: partial, to: m4a)
        }
        if keepRaw {
            let raw = m4a.deletingPathExtension().appendingPathExtension("raw.caf")
            try? FileManager.default.removeItem(at: raw)
            try FileManager.default.moveItem(at: caf, to: raw)
        } else {
            try FileManager.default.removeItem(at: caf)
        }
        finished = true
        return tracksFolder
    }

    /// The m4a name for a hidden in-progress CAF (".Recording <date>.caf").
    static func finalURL(for caf: URL) -> URL {
        let name = String(caf.deletingPathExtension().lastPathComponent.dropFirst())
        return caf.deletingLastPathComponent().appending(path: name).appendingPathExtension("m4a")
    }

    /// CAFs left by a crash or a forced quit. A CAF written in the last 10 s may belong to a
    /// recording that is still running in another copy of the app, so it is left alone.
    static func leftovers(in folder: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [])) ?? []
        return files.filter {
            let modified = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return $0.lastPathComponent.hasPrefix(".Recording ") && $0.pathExtension == "caf" && modified < Date(timeIntervalSinceNow: -10)
        }
    }
}
