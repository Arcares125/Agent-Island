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
}
