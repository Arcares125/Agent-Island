import Foundation
import XCTest
@testable import AgentIsland

final class SpectrumMathTests: XCTestCase {
    func testBarsAreZeroForSilence() {
        let bars = binMagnitudesToBars([Float](repeating: 0, count: 1024), barCount: 6)
        XCTAssertEqual(bars.count, 6)
        XCTAssertTrue(bars.allSatisfy { $0 == 0 })
    }

    func testHighBinEnergyLightsAHighBand() {
        var mags = [Float](repeating: 0, count: 1024)
        mags[1000] = 1_000_000          // energy near the top
        let bars = binMagnitudesToBars(mags, barCount: 6)
        XCTAssertGreaterThan(bars[5], bars[0], "Top-frequency energy lights the top band, not the bottom")
        XCTAssertTrue(bars.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    func testSmoothingRisesFasterThanItFalls() {
        let up = smoothBars(previous: [0], target: [1], attack: 0.8, decay: 0.2)
        let down = smoothBars(previous: [1], target: [0], attack: 0.8, decay: 0.2)
        XCTAssertEqual(up[0], 0.8, accuracy: 0.001)     // fast attack
        XCTAssertEqual(down[0], 0.8, accuracy: 0.001)   // slow decay leaves 0.8
    }

    func testHuePhaseWraps() {
        XCTAssertEqual(huePhase(at: 0, speed: 0.1), 0, accuracy: 0.0001)
        XCTAssertEqual(huePhase(at: 5, speed: 0.1), 0.5, accuracy: 0.0001)
        let p = huePhase(at: 12.34, speed: 1.0)
        XCTAssertTrue(p >= 0 && p < 1)
    }

    func testFFTConcentratesASineInOneBand() {
        let size = 2048
        let analyzer = SpectrumAnalyzer(size: size)
        // A pure tone at bin 64 of `size`.
        let bin = 64
        let samples = (0..<size).map { Float(sin(2 * Double.pi * Double(bin) * Double($0) / Double(size))) }
        let mags = analyzer.magnitudes(from: samples)
        XCTAssertEqual(mags.count, size / 2)
        let peakIndex = mags.enumerated().max(by: { $0.element < $1.element })!.offset
        XCTAssertEqual(peakIndex, bin, accuracy: 2, "FFT peak lands at the tone's bin")
    }
}
