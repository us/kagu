import AVFoundation
import Foundation

/// Plays one recording at a time for the detail pane.
@MainActor @Observable
final class Player {
    private(set) var isPlaying = false
    private(set) var time = 0.0
    private(set) var duration = 0.0

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var url: URL?
    var isLoaded: Bool { player != nil }
    /// The file could not be opened for playing (damaged, or a format that will not decode).
    private(set) var failed = false

    /// The speeds offered, as Podcasts offers them.
    static let rates: [Float] = [1, 1.25, 1.5, 2]
    static func name(_ rate: Float) -> String { "\(rate.formatted())\u{00D7}" }  // "1.25×"

    /// The playback speed, the same for every recording and kept across launches.
    var rate: Float = {
        let saved = UserDefaults.standard.float(forKey: "playbackRate")
        return Player.rates.contains(saved) ? saved : 1
    }() {
        didSet {
            player?.rate = rate
            UserDefaults.standard.set(rate, forKey: "playbackRate")
        }
    }

    func load(_ url: URL) {
        stop()
        self.url = url
        player = try? AVAudioPlayer(contentsOf: url)
        failed = player == nil
        player?.enableRate = true  // before prepareToPlay, or the rate is ignored
        player?.rate = rate
        player?.prepareToPlay()
        duration = player?.duration ?? 0
        time = 0
    }

    func toggle() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
            timer?.invalidate()
        } else {
            if player.currentTime >= player.duration - 0.05 { player.currentTime = 0 }
            player.play()
            isPlaying = true
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    func seek(to seconds: Double) {
        guard let player else { return }
        player.currentTime = min(max(0, seconds), player.duration)
        time = player.currentTime
    }

    func skip(_ seconds: Double) { seek(to: (player?.currentTime ?? 0) + seconds) }

    func stop() {
        player?.stop()
        player?.currentTime = 0
        timer?.invalidate()
        isPlaying = false
        time = 0
    }

    /// Lets go of `url` when it is the loaded file, so Play or Pause cannot start a recording that left the screen.
    /// Only that file: the pane that shows next may already have loaded its own.
    func unload(_ url: URL) {
        guard url == self.url else { return }
        stop()
        player = nil
        self.url = nil
        duration = 0
    }

    private func tick() {
        guard let player else { return }
        time = player.currentTime
        if !player.isPlaying {
            isPlaying = false
            timer?.invalidate()
        }
    }
}
