import CSpeexDSP
import Foundation

/// Removes the speaker echo from the mic, using what the Mac played as the reference
/// (SpeexDSP MDF, 200 ms tail). Works frame by frame on Float samples in [-1, 1].
final class EchoCanceller {
    let frame: Int
    private let state: OpaquePointer
    private let mic16: UnsafeMutablePointer<Int16>
    private let ref16: UnsafeMutablePointer<Int16>
    private let out16: UnsafeMutablePointer<Int16>
    private var usedMic = false

    private(set) var guardedFrames = 0
    // Per frame mic reduction while something plays (reference above -50 dBFS). With no echo path
    // (headphones) the canceller cannot lower the mic there. A median, so loud talking over the
    // other side (the voice passes through unchanged) does not outweigh the echo-only frames.
    private var playingReductions: [Float] = []

    init(sampleRate: Double) {
        frame = Self.frameSize(sampleRate: sampleRate)
        let tail = Int(sampleRate) / 5
        state = speex_echo_state_init(Int32(frame), Int32(tail))
        var rate = Int32(sampleRate)
        speex_echo_ctl(state, SPEEX_ECHO_SET_SAMPLING_RATE, &rate)
        mic16 = .allocate(capacity: frame)
        ref16 = .allocate(capacity: frame)
        out16 = .allocate(capacity: frame)
    }

    deinit {
        speex_echo_state_destroy(state)
        mic16.deallocate()
        ref16.deallocate()
        out16.deallocate()
    }

    /// Median per frame drop of the mic while something played, in dB. Near 0 means no echo to remove.
    var echoReductionDB: Double {
        guard !playingReductions.isEmpty else { return 0 }
        return Double(playingReductions.sorted()[playingReductions.count / 2])
    }

    /// 10 ms, even: odd sizes lose a sample in mdf_inner_prod.
    static func frameSize(sampleRate: Double) -> Int { (Int(sampleRate) / 100) & ~1 }

    /// Cleans one frame of `mic` in place. `reference` is the mono mix of what played.
    func process(mic: UnsafeMutablePointer<Float>, reference: UnsafePointer<Float>) {
        var micEnergy = 0.0, refEnergy = 0.0
        for i in 0..<frame {
            mic16[i] = int16(mic[i])
            ref16[i] = int16(reference[i])
            out16[i] = mic16[i]  // what stays if Speex writes nothing
            micEnergy += Double(mic16[i]) * Double(mic16[i])
            refEnergy += Double(ref16[i]) * Double(ref16[i])
        }
        speex_echo_cancellation(state, mic16, ref16, out16)
        var outEnergy = 0.0
        for i in 0..<frame { outEnergy += Double(out16[i]) * Double(out16[i]) }

        // The echo path can vanish mid call (headphones, mute, volume down) while the filter still
        // subtracts what it learned, which would add the far voice to the mic. Then keep the mic.
        // A zero output with a live mic is Speex's internal reset branch.
        let useMic = outEnergy > 2 * micEnergy || (outEnergy == 0 && micEnergy > 0)
        if useMic { guardedFrames += 1 }
        let fade = useMic != usedMic  // crossfade over the frame so a switch does not click
        for i in 0..<frame {
            let cleaned = Float(out16[i]) / 32768
            let raw = mic[i]
            let target = useMic ? raw : cleaned
            if fade {
                let t = Float(i + 1) / Float(frame)
                mic[i] = (useMic ? cleaned : raw) * (1 - t) + target * t
            } else {
                mic[i] = target
            }
        }
        usedMic = useMic

        if refEnergy / Double(frame) > 32768.0 * 32768.0 * 1e-5, micEnergy > 0 {
            var finalEnergy = 0.0
            for i in 0..<frame { finalEnergy += Double(mic[i] * 32768) * Double(mic[i] * 32768) }
            playingReductions.append(Float(10 * log10(micEnergy / max(finalEnergy, 1e-3))))
        }
    }

    private func int16(_ x: Float) -> Int16 {
        Int16(max(-32768, min(32767, lrintf(x * 32768))))
    }
}
