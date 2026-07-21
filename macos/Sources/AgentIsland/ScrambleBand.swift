import Foundation

/// Blocky glyphs and digits, never letters: the churn has to read as noise, and
/// letters make the eye try to finish a word.
let scrambleAlphabet: [Character] = Array("0123456789▚▞▛▜▙▟◤◥◣◢▤▥▦▧▨▩#%&$*+=/\\|")

/// Which horizontal slices of a glyph the interference band covers.
///
/// The band travels a slice further than the glyph is tall at both ends, so the
/// top and bottom slices are genuinely crossed rather than clipped by the edge —
/// at `progress` 0 the band sits entirely above the glyph and at 1 entirely
/// below it, leaving the digit clean before and after the pass.
func scrambleBandRange(progress: Double, sliceCount: Int, bandSlices: Int) -> Range<Int> {
    guard sliceCount > 0, bandSlices > 0 else { return 0..<0 }

    let clamped = min(max(progress, 0), 1)
    let travel = Double(sliceCount + bandSlices)
    let top = Int((clamped * travel).rounded(.down)) - bandSlices

    let lower = max(0, top)
    let upper = min(sliceCount, top + bandSlices)
    return lower < upper ? lower..<upper : 0..<0
}

/// A junk glyph for one slice of one frame.
///
/// Deterministic rather than random so a slice does not flicker between two
/// redraws of the same frame, which reads as noise on top of noise.
func scrambleCharacter(seed: Int) -> Character {
    var hash = UInt64(bitPattern: Int64(seed))
    hash ^= hash >> 33
    hash = hash &* 0xFF51_AFD7_ED55_8CCD
    hash ^= hash >> 33
    return scrambleAlphabet[Int(hash % UInt64(scrambleAlphabet.count))]
}
