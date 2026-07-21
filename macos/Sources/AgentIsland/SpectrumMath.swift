import Foundation

/// Reduce FFT power magnitudes into `barCount` log-spaced bands, each normalized
/// to 0...1. Music energy is roughly log-distributed across frequency, so linear
/// bins look dead; log spacing + a log amplitude curve keeps quiet detail visible.
func binMagnitudesToBars(_ magnitudes: [Float], barCount: Int) -> [Float] {
    guard barCount > 0 else { return [] }
    let binCount = magnitudes.count
    guard binCount >= barCount else { return [Float](repeating: 0, count: barCount) }

    var bars = [Float](repeating: 0, count: barCount)
    let minBin = 1.0
    let maxBin = Double(binCount)
    for b in 0..<barCount {
        let lo = minBin * pow(maxBin / minBin, Double(b) / Double(barCount))
        let hi = minBin * pow(maxBin / minBin, Double(b + 1) / Double(barCount))
        let loIdx = min(max(Int(lo), 1), binCount - 1)
        let hiIdx = min(max(Int(hi), loIdx + 1), binCount)
        var peak: Float = 0
        for i in loIdx..<hiIdx { peak = max(peak, magnitudes[i]) }
        // `peak` is power (squared magnitude); a log curve maps a wide range to 0...1.
        bars[b] = min(max(log10(1 + peak) / 6.0, 0), 1)
    }
    return bars
}

/// Attack/decay smoothing: bars rise fast on transients, fall slowly, so the
/// equalizer punches on the beat and settles smoothly.
func smoothBars(previous: [Float], target: [Float], attack: Float, decay: Float) -> [Float] {
    guard previous.count == target.count else { return target }
    var out = previous
    for i in 0..<target.count {
        let rate = target[i] > previous[i] ? attack : decay
        out[i] = previous[i] + (target[i] - previous[i]) * min(max(rate, 0), 1)
    }
    return out
}

/// Continuously-advancing hue phase (0...1, wrapping) for the rotating color.
func huePhase(at time: Double, speed: Double) -> Double {
    let p = (time * speed).truncatingRemainder(dividingBy: 1.0)
    return p < 0 ? p + 1 : p
}
