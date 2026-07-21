import Foundation
import XCTest
@testable import AgentIsland

/// When attached to the notch and idle, the compact island must stay at its full
/// wing width so it remains a visible pill instead of vanishing into the notch.
final class IdlePresentationTests: XCTestCase {
    @MainActor
    func testIdleNotchKeepsCompactWidth() {
        let model = IslandModel()
        model.setNotchPresentation(
            NotchPresentation(cameraWidth: 180, barHeight: 32, compactWidth: 330)
        )
        model.setPhase(.idle)

        XCTAssertEqual(model.aggregatePhase, .idle)
        XCTAssertFalse(model.isExpanded)
        XCTAssertEqual(
            model.preferredSize.width,
            330,
            accuracy: 0.5,
            "Idle notch must stay at compact width, not shrink to the camera width"
        )
        XCTAssertEqual(model.persistentHeaderSize.width, 330, accuracy: 0.5)
    }

    @MainActor
    func testActiveNotchAlsoUsesCompactWidth() {
        let model = IslandModel()
        model.setNotchPresentation(
            NotchPresentation(cameraWidth: 180, barHeight: 32, compactWidth: 330)
        )
        model.setPhase(.thinking)

        XCTAssertEqual(model.preferredSize.width, 330, accuracy: 0.5)
    }
}
