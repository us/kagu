import Synchronization

/// Single producer (IO thread), single consumer (writer queue) ring of interleaved Float frames.
/// The producer never locks or allocates.
final class Ring: @unchecked Sendable {
    let channels: Int
    let capacity: Int  // frames
    private let data: UnsafeMutablePointer<Float>
    private let head = Atomic<Int>(0)  // total frames written, owned by the producer
    private let tail = Atomic<Int>(0)  // total frames read, owned by the consumer

    init(channels: Int, capacity: Int) {
        self.channels = channels
        self.capacity = capacity
        data = .allocate(capacity: channels * capacity)
        data.initialize(repeating: 0, count: channels * capacity)
    }

    deinit { data.deallocate() }

    /// Producer: reserves `frames` frames and lets `fill` write them interleaved.
    /// Returns false (and writes nothing) when the ring is full.
    func write(frames: Int, _ fill: (_ frame: Int, _ dst: UnsafeMutablePointer<Float>) -> Void) -> Bool {
        let h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .acquiring)
        guard capacity - (h - t) >= frames else { return false }
        for i in 0..<frames {
            fill(i, data + ((h + i) % capacity) * channels)
        }
        head.store(h + frames, ordering: .releasing)
        return true
    }

    /// Consumer: copies up to `maxFrames` frames into `dst`, returns the frame count.
    func read(into dst: UnsafeMutablePointer<Float>, maxFrames: Int) -> Int {
        let t = tail.load(ordering: .relaxed)
        let h = head.load(ordering: .acquiring)
        let n = min(h - t, maxFrames)
        for i in 0..<n {
            (dst + i * channels).update(from: data + ((t + i) % capacity) * channels, count: channels)
        }
        tail.store(t + n, ordering: .releasing)
        return n
    }
}
