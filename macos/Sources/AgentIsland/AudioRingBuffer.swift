import os

/// A fixed-size mono sample ring the audio IO thread writes into and the ~30 fps
/// consumer snapshots. A tiny unfair-lock guards the copies; the critical section
/// is only a memcpy, so real-time impact on the audio thread is negligible and,
/// unlike a lock-free racy read, the snapshot is never torn.
final class AudioRingBuffer: @unchecked Sendable {
    private let capacity: Int
    private var storage: [Float]
    private var writeIndex = 0
    private var filled = 0
    private let lock = OSAllocatedUnfairLock()

    init(capacity: Int) {
        self.capacity = capacity
        self.storage = [Float](repeating: 0, count: capacity)
    }

    /// Append `frameCount` frames of interleaved audio, downmixed to mono, WITHOUT
    /// allocating (audio thread). `channels` is the interleave stride.
    func writeDownmix(_ interleaved: UnsafePointer<Float>, frameCount: Int, channels: Int) {
        let ch = max(channels, 1)
        lock.lock()
        defer { lock.unlock() }
        for f in 0..<frameCount {
            var sum: Float = 0
            for c in 0..<ch { sum += interleaved[f * ch + c] }
            storage[writeIndex] = sum / Float(ch)
            writeIndex = (writeIndex + 1) % capacity
        }
        filled = min(filled + frameCount, capacity)
    }

    /// Copy the most recent `size` samples in chronological order (consumer).
    /// Returns fewer than `size` only before the ring has filled once.
    func latestWindow(_ size: Int) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let n = min(size, filled)
        guard n > 0 else { return [] }
        var out = [Float](repeating: 0, count: n)
        var idx = (writeIndex - n + capacity) % capacity
        for i in 0..<n {
            out[i] = storage[idx]
            idx = (idx + 1) % capacity
        }
        return out
    }
}
