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

    /// The gear opens settings in place of the resting scene, which grows the
    /// panel; collapsing the island drops it again so the next open shows the scene.
    @MainActor
    func testIdleSettingsGearExpandsPanelThenResetsOnCollapse() {
        let model = IslandModel()
        model.setPhase(.idle)
        model.setHovered(true)

        XCTAssertFalse(model.isShowingIdleSettings)
        let restingHeight = model.preferredSize.height

        model.toggleIdleSettings()
        XCTAssertTrue(model.isShowingIdleSettings)
        XCTAssertGreaterThan(
            model.preferredSize.height,
            restingHeight,
            "Settings needs more room than the resting scene"
        )

        model.setHovered(false)
        XCTAssertFalse(model.isShowingIdleSettings, "Collapsing hides and resets the gear panel")
    }

    /// The gear is idle-only: while the island is collapsed there is no panel to
    /// grow, so the flag must not leak into the compact size.
    @MainActor
    func testIdleSettingsNeverShowsWhileCollapsed() {
        let model = IslandModel()
        model.setPhase(.idle)
        model.toggleIdleSettings()

        XCTAssertFalse(model.isExpanded)
        XCTAssertFalse(model.isShowingIdleSettings, "A collapsed idle island shows no settings")
    }
}
