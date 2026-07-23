import XCTest
@testable import AgentIsland

/// Pure mapping helpers behind the volume HUD: which mascot tugs, and how many
/// bar segments light for a given level.
final class VolumeMathTests: XCTestCase {
    func testTugDirectionFromDelta() {
        XCTAssertEqual(volumeTug(delta: 0.1), .towardCodex)   // volume up
        XCTAssertEqual(volumeTug(delta: -0.1), .towardClaude) // volume down
        XCTAssertEqual(volumeTug(delta: 0), .none)
        XCTAssertEqual(volumeTug(delta: 0.0005), .none)       // inside dead zone
        XCTAssertEqual(volumeTug(delta: -0.0005), .none)
    }

    func testLitSegments() {
        XCTAssertEqual(litSegments(level: 0, segmentCount: 12), 0)
        XCTAssertEqual(litSegments(level: 1, segmentCount: 12), 12)
        XCTAssertEqual(litSegments(level: 0.5, segmentCount: 12), 6)
        XCTAssertEqual(litSegments(level: 1.5, segmentCount: 12), 12)  // clamps high
        XCTAssertEqual(litSegments(level: -0.3, segmentCount: 12), 0)  // clamps low
        XCTAssertEqual(litSegments(level: 0.5, segmentCount: 0), 0)    // guards zero
    }

    /// The HUD's sixteen knots preserve one exact knot per macOS volume notch:
    /// each `k/16` level must light precisely `k` knots — no press ever moves
    /// two, or none.
    func testEachSixteenthNotchLightsExactlyOneBox() {
        for notch in 0...16 {
            XCTAssertEqual(
                litSegments(level: Float(notch) / 16, segmentCount: 16),
                notch,
                "level \(notch)/16 should light \(notch) of 16 knots"
            )
        }
    }

    func testTugMomentDescribesDirectionAndEdgeWins() {
        XCTAssertEqual(volumeTugMoment(level: 0.5, direction: .towardCodex), .increase)
        XCTAssertEqual(volumeTugMoment(level: 0.5, direction: .towardClaude), .decrease)
        XCTAssertEqual(volumeTugMoment(level: 0.5, direction: .none), .settled)
        XCTAssertEqual(volumeTugMoment(level: 0, direction: .towardClaude), .minimum)
        XCTAssertEqual(volumeTugMoment(level: 1, direction: .towardCodex), .maximum)
        XCTAssertEqual(volumeTugMoment(level: -2, direction: .towardCodex), .minimum)
        XCTAssertEqual(volumeTugMoment(level: 3, direction: .towardClaude), .maximum)
    }

    func testTugMomentLabelsRemainHonest() {
        XCTAssertEqual(VolumeTugMoment.minimum.label, "CLAUDE WINS · MINIMUM")
        XCTAssertEqual(VolumeTugMoment.maximum.label, "CODEX WINS · MAXIMUM")
        XCTAssertEqual(VolumeTugMoment.increase.label, "CODEX PULLS · VOLUME UP")
        XCTAssertEqual(VolumeTugMoment.decrease.label, "CLAUDE PULLS · VOLUME DOWN")
        XCTAssertEqual(VolumeTugMoment.settled.label, "VOLUME SETTLED")
    }

    func testMarkerPreservesFineGrainedVolumeAndClampsEdges() {
        XCTAssertEqual(volumeMarkerProgress(level: 0.515625), 0.515625, accuracy: 0.000001)
        XCTAssertEqual(volumeMarkerProgress(level: -1), 0)
        XCTAssertEqual(volumeMarkerProgress(level: 2), 1)
    }

    func testLivingRopeGeometryStaysPerfectlyStraight() {
        let middleY: CGFloat = 15
        let points = stride(from: CGFloat(0), through: 1, by: 0.05).map {
            straightVolumeRopePoint(
                progress: $0,
                inset: 5,
                usableWidth: 200,
                middleY: middleY
            )
        }

        XCTAssertTrue(points.allSatisfy { $0.y == middleY })
        XCTAssertEqual(points.first?.x, 5)
        XCTAssertEqual(points.last?.x, 205)
    }
}
