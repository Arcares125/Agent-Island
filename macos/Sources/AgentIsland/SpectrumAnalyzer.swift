import Accelerate

/// Reusable real-FFT: a window of mono samples → `size/2` power magnitudes.
/// The vDSP setup and scratch buffers are allocated once and reused.
final class SpectrumAnalyzer {
    let size: Int
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private var window: [Float]

    init(size: Int = 2048) {
        precondition(size > 0 && (size & (size - 1)) == 0, "FFT size must be a power of two")
        self.size = size
        self.log2n = vDSP_Length(log2(Float(size)))
        self.fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        self.window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    /// Power magnitudes (`size/2`) for `samples` (zero-padded/truncated to `size`).
    func magnitudes(from samples: [Float]) -> [Float] {
        let half = size / 2
        var windowed = [Float](repeating: 0, count: size)
        let n = min(samples.count, size)
        samples.withUnsafeBufferPointer { s in
            window.withUnsafeBufferPointer { w in
                vDSP_vmul(s.baseAddress!, 1, w.baseAddress!, 1, &windowed, 1, vDSP_Length(n))
            }
        }
        var realp = [Float](repeating: 0, count: half)
        var imagp = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: half)
        realp.withUnsafeMutableBufferPointer { r in
            imagp.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                windowed.withUnsafeBufferPointer { wb in
                    wb.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { c in
                        vDSP_ctoz(c, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(half))
            }
        }
        return magnitudes
    }
}
