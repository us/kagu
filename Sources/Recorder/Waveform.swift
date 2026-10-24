import AVFoundation
import Foundation
import Synchronization

/// The loudness outline of a recording, `count` values from 0 to 1, for the player.
enum Waveform {
    private static let cache = Mutex<[URL: [Float]]>([:])

    static func peaks(url: URL, count: Int = 96) async -> [Float] {
        if let hit = cache.withLock({ $0[url] }) { return hit }
        let peaks = await Task.detached(priority: .utility) { compute(url, count) }.value
        if !peaks.isEmpty { cache.withLock { $0[url] = peaks } }
        return peaks
    }

    private static func compute(_ url: URL, _ count: Int) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false) else { return [] }
        return peaks(in: file, count: count)
    }

    /// Reads the whole file once; `count` loudness values, the loudest scaled to 1.
    static func peaks(in file: AVAudioFile, count: Int) -> [Float] {
        guard file.length > 0 else { return [] }
        let chunk: AVAudioFrameCount = 1 << 16
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk)!
        let channels = Int(file.processingFormat.channelCount)
        let total = Double(file.length)
        var peaks = [Float](repeating: 0, count: count)
        let step = 512
        while file.framePosition < file.length {
            let start = Double(file.framePosition)
            guard (try? file.read(into: buffer, frameCount: chunk)) != nil, buffer.frameLength > 0 else { break }
            let data = buffer.floatChannelData!
            let n = Int(buffer.frameLength)
            for i in stride(from: 0, to: n, by: step) {
                var peak: Float = 0
                for ch in 0..<channels { for j in i..<min(n, i + step) { peak = max(peak, abs(data[ch][j])) } }
                let bucket = min(count - 1, Int((start + Double(i)) / total * Double(count)))
                peaks[bucket] = max(peaks[bucket], peak)
            }
        }
        let top = peaks.max() ?? 0
        return top > 0 ? peaks.map { pow($0 / top, 0.6) } : peaks
    }
}
