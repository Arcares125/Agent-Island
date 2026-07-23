import CoreGraphics
import Foundation

/// The small life the resting pair acts out while no agent session is running.
///
/// With no work to report, the island would otherwise sit as a dead pill. Cycling
/// the two mascots through a few unhurried activities — dozing, listening to
/// music, playing together — reads as "alive and waiting" rather than "switched
/// off", which is what the no-session state should feel like.
enum IdleActivity: String, CaseIterable {
    case sleeping
    case music
    case playing

    /// A short lowercase caption shown under the scene.
    var caption: String {
        switch self {
        case .sleeping: return "dozing off"
        case .music: return "listening to music"
        case .playing: return "playing around"
        }
    }
}

/// Where the pair is in the resting loop at one moment: which activity is on
/// stage, and how far through it (`progress`, 0…1) so motion can be driven from it.
struct IdleScene: Equatable {
    let activity: IdleActivity
    let progress: Double
}

/// Displacement applied to one resting mascot for the current scene.
///
/// A separate value type rather than raw tuples so the choreography stays pure —
/// clock in, motion out — and can be unit-tested without a running view.
struct MascotMotion: Equatable {
    var dx: CGFloat = 0
    var dy: CGFloat = 0
    var rotation: Double = 0
    var scaleY: CGFloat = 1
}

/// Turns a clock reading into the scene playing and each mascot's motion within it.
///
/// Deliberately free of SwiftUI: the view layer feeds it a timestamp and renders
/// the result, which keeps the timing and the little dance testable on their own.
enum IdleChoreography {
    /// How long each activity holds the stage before handing off to the next.
    static let sceneDuration: TimeInterval = 6

    /// One full trip through every activity.
    static var loopDuration: TimeInterval {
        sceneDuration * Double(IdleActivity.allCases.count)
    }

    /// The scene at `elapsed` seconds into the loop.
    static func scene(at elapsed: TimeInterval) -> IdleScene {
        let activities = IdleActivity.allCases
        // A clock can hand back a value before the anchor (or an absolute time we
        // do not control the sign of); clamp so the loop never indexes backwards.
        let bounded = max(0, elapsed).truncatingRemainder(dividingBy: loopDuration)
        let index = min(Int(bounded / sceneDuration), activities.count - 1)
        let progress = (bounded - Double(index) * sceneDuration) / sceneDuration
        return IdleScene(activity: activities[index], progress: min(max(progress, 0), 1))
    }

    /// Motion for one of the two mascots in the given scene.
    ///
    /// `side` is `-1` for the left mascot and `+1` for the right, so the pair can
    /// be moved in mirror image — apart, together, or a half-beat out of phase.
    static func motion(for scene: IdleScene, side: CGFloat) -> MascotMotion {
        let progress = scene.progress
        switch scene.activity {
        case .sleeping:
            // One slow breath across the whole scene: a gentle rise and squash,
            // nothing that would ask the compositor to work hard.
            let breath = sin(progress * 2 * .pi)
            return MascotMotion(dy: CGFloat(breath) * 1.5, scaleY: 1 + CGFloat(breath) * 0.02)
        case .music:
            // A four-beat bounce, the right mascot a quarter-beat behind the left
            // so they trade the downbeat instead of hopping as one block. `-abs`
            // folds the sine into pure up-hops — a mascot never sinks below its
            // resting line — which is why the offset is a quarter, not a half: a
            // half would fold back onto the same hop and move them in lockstep.
            let beatPhase = side > 0 ? 0.25 : 0.0
            let bounce = sin((progress * 4 + beatPhase) * 2 * .pi)
            let sway = sin((progress * 2 + beatPhase) * 2 * .pi)
            return MascotMotion(
                dx: CGFloat(sway) * 1.5,
                dy: -abs(CGFloat(bounce)) * 5,
                rotation: Double(sway) * 5
            )
        case .playing:
            // They scoot toward each other, meet in the middle, and spring apart —
            // three little chases per scene. `meet` is 0 at the edges, 1 when they
            // touch; `dx` moves each toward centre so they close the gap together.
            let meet = abs(sin(progress * 3 * .pi))
            let hop = abs(sin(progress * 6 * .pi))
            return MascotMotion(
                dx: -side * CGFloat(meet) * 10,
                dy: -CGFloat(hop) * 4,
                rotation: -Double(side) * Double(meet) * 8
            )
        }
    }
}
