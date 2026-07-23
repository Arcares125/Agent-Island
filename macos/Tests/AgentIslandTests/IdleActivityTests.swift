import XCTest
@testable import AgentIsland

/// The resting loop is pure time-in / scene-out, so its cycling and its little
/// dance are verified here without ever standing up a view.
final class IdleActivityTests: XCTestCase {

    // MARK: - Scene cycling

    func testLoopStartsAsleep() {
        let scene = IdleChoreography.scene(at: 0)
        XCTAssertEqual(scene.activity, .sleeping)
        XCTAssertEqual(scene.progress, 0, accuracy: 0.0001)
    }

    func testActivitiesRunInOrderOncePerLoop() {
        let duration = IdleChoreography.sceneDuration
        // Sample the middle of each slot so a boundary rounding error cannot hide.
        XCTAssertEqual(IdleChoreography.scene(at: duration * 0.5).activity, .sleeping)
        XCTAssertEqual(IdleChoreography.scene(at: duration * 1.5).activity, .music)
        XCTAssertEqual(IdleChoreography.scene(at: duration * 2.5).activity, .playing)
    }

    func testProgressRunsZeroToOneWithinAScene() {
        let duration = IdleChoreography.sceneDuration
        XCTAssertEqual(IdleChoreography.scene(at: duration * 0.25).progress, 0.25, accuracy: 0.0001)
        XCTAssertEqual(IdleChoreography.scene(at: duration * 0.75).progress, 0.75, accuracy: 0.0001)
    }

    func testLoopWrapsBackToTheStart() {
        // One full loop later is the same moment as the beginning.
        let wrapped = IdleChoreography.scene(at: IdleChoreography.loopDuration)
        XCTAssertEqual(wrapped.activity, .sleeping)
        XCTAssertEqual(wrapped.progress, 0, accuracy: 0.0001)

        let intoSecondLoop = IdleChoreography.scene(at: IdleChoreography.loopDuration + IdleChoreography.sceneDuration * 1.5)
        XCTAssertEqual(intoSecondLoop.activity, .music)
    }

    /// A clock can hand back a value before the anchor; the loop must clamp rather
    /// than index into a negative, out-of-range scene.
    func testNegativeElapsedClampsToTheStart() {
        let scene = IdleChoreography.scene(at: -42)
        XCTAssertEqual(scene.activity, .sleeping)
        XCTAssertEqual(scene.progress, 0, accuracy: 0.0001)
    }

    func testEveryActivityIsReachable() {
        let duration = IdleChoreography.sceneDuration
        let seen = Set((0..<IdleActivity.allCases.count).map {
            IdleChoreography.scene(at: duration * (Double($0) + 0.5)).activity
        })
        XCTAssertEqual(seen, Set(IdleActivity.allCases))
    }

    // MARK: - Motion

    func testSleepingBarelyMoves() {
        for step in stride(from: 0.0, through: 1.0, by: 0.1) {
            let motion = IdleChoreography.motion(for: IdleScene(activity: .sleeping, progress: step), side: -1)
            XCTAssertLessThanOrEqual(abs(motion.dy), 2, "A doze should not lurch")
            XCTAssertEqual(motion.dx, 0, accuracy: 0.0001, "Sleeping mascots stay put")
        }
    }

    func testMusicHopsOnlyUpward() {
        for step in stride(from: 0.0, through: 1.0, by: 0.05) {
            for side in [CGFloat(-1), 1] {
                let motion = IdleChoreography.motion(for: IdleScene(activity: .music, progress: step), side: side)
                XCTAssertLessThanOrEqual(motion.dy, 0.0001, "A hop never sinks below the resting line")
            }
        }
    }

    /// The two music mascots trade the downbeat rather than moving as one block.
    func testMusicMascotsAreOutOfPhase() {
        // A quarter of the way in, the half-beat offset makes their hops differ.
        let scene = IdleScene(activity: .music, progress: 0.1)
        let left = IdleChoreography.motion(for: scene, side: -1)
        let right = IdleChoreography.motion(for: scene, side: 1)
        XCTAssertNotEqual(left.dy, right.dy, accuracy: 0.0001)
    }

    /// The whole point of "playing": the pair moves toward the centre together.
    func testPlayingDrawsThePairTogether() {
        // A sixth of the way in the approach is at full reach.
        let scene = IdleScene(activity: .playing, progress: 1.0 / 6.0)
        let left = IdleChoreography.motion(for: scene, side: -1)
        let right = IdleChoreography.motion(for: scene, side: 1)
        XCTAssertGreaterThan(left.dx, 0, "Left mascot moves right, toward centre")
        XCTAssertLessThan(right.dx, 0, "Right mascot moves left, toward centre")
    }
}
