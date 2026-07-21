import Foundation

/// Which mascot is "tugging" the volume bar, derived from the direction of the
/// most recent volume change. Codex sits on the left, Claude on the right.
enum TugDirection: Equatable {
    case towardCodex   // volume went up
    case towardClaude  // volume went down
    case none          // no meaningful change
}

/// Maps a volume delta to the tugging mascot. A small dead zone absorbs the
/// floating-point jitter CoreAudio can report for a nominally unchanged level.
func volumeTug(delta: Float, deadZone: Float = 0.001) -> TugDirection {
    if delta > deadZone { return .towardCodex }
    if delta < -deadZone { return .towardClaude }
    return .none
}

/// Number of lit segments for a 0...1 level across `segmentCount` segments,
/// rounded to the nearest segment and clamped into range.
func litSegments(level: Float, segmentCount: Int) -> Int {
    guard segmentCount > 0 else { return 0 }
    let clamped = min(max(level, 0), 1)
    return Int((clamped * Float(segmentCount)).rounded())
}
