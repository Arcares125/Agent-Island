import Foundation
import CoreGraphics

/// Which mascot is "tugging" the volume bar, derived from the direction of the
/// most recent volume change. Codex sits on the left, Claude on the right.
enum TugDirection: Equatable {
    case towardCodex   // volume went up
    case towardClaude  // volume went down
    case none          // no meaningful change
}

/// The story beat shown below the rope. Minimum and maximum take precedence
/// over direction because they are the more useful result of the last pull.
enum VolumeTugMoment: Equatable {
    case minimum
    case maximum
    case increase
    case decrease
    case settled

    var label: String {
        switch self {
        case .minimum: return "CLAUDE WINS · MINIMUM"
        case .maximum: return "CODEX WINS · MAXIMUM"
        case .increase: return "CODEX PULLS · VOLUME UP"
        case .decrease: return "CLAUDE PULLS · VOLUME DOWN"
        case .settled: return "VOLUME SETTLED"
        }
    }
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

/// Exact marker progress for the rope's pale diamond. Unlike the sixteen lit
/// knots, this preserves Shift–Option quarter-step volume changes.
func volumeMarkerProgress(level: Float) -> Float {
    min(max(level, 0), 1)
}

/// Point on the volume rope. Its y-coordinate deliberately never depends on the
/// pull animation; life comes from tension styling and mascot movement, not a
/// wavy line that makes the control harder to read.
func straightVolumeRopePoint(
    progress: CGFloat,
    inset: CGFloat,
    usableWidth: CGFloat,
    middleY: CGFloat
) -> CGPoint {
    CGPoint(
        x: inset + max(usableWidth, 0) * min(max(progress, 0), 1),
        y: middleY
    )
}

/// Converts the real scalar level plus the last meaningful delta into an honest
/// HUD reaction. There is deliberately no mute case: the current audio monitor
/// observes volume scalar changes, not CoreAudio's separate mute property.
func volumeTugMoment(level: Float, direction: TugDirection) -> VolumeTugMoment {
    let clamped = min(max(level, 0), 1)
    if clamped <= 0.0001 { return .minimum }
    if clamped >= 0.9999 { return .maximum }

    switch direction {
    case .towardCodex: return .increase
    case .towardClaude: return .decrease
    case .none: return .settled
    }
}
