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

    /// Regression: while resting, the island used to show a scene with only a
    /// settings gear, so the shelf could not be opened without starting an agent.
    /// The resting state now routes through the same tab bar as a live session.
    @MainActor
    func testRestingIslandReachesEveryTab() {
        let model = IslandModel()
        model.setPhase(.idle)
        model.setHovered(true)

        XCTAssertTrue(model.isNoSessionIdle)
        XCTAssertTrue(model.showsTabDashboard, "Resting must reach the tab bar")

        for tab in IslandTab.allCases {
            model.selectTab(tab)
            XCTAssertEqual(model.selectedTab, tab)
            XCTAssertTrue(model.showsTabDashboard, "\(tab.label) stays reachable while resting")
        }
    }

    /// Each tab sizes the resting panel to its own content, the same as it does
    /// with a live session — the shelf and settings are much taller than the scene.
    @MainActor
    func testRestingPanelSizesToTheSelectedTab() {
        let model = IslandModel()
        model.setPhase(.idle)
        model.setHovered(true)

        model.selectTab(.agents)
        let restingHeight = model.preferredSize.height

        model.selectTab(.settings)
        XCTAssertGreaterThan(
            model.preferredSize.height,
            restingHeight,
            "Settings needs more room than the resting scene"
        )
    }

    /// The resting scene needs a box of its own; an empty session list would
    /// otherwise collapse the Agents tab to nothing.
    @MainActor
    func testRestingAgentsTabReservesSceneHeight() {
        let model = IslandModel()
        model.setPhase(.idle)
        XCTAssertEqual(model.liveSessionListHeight, IslandModel.restingSceneHeight)
    }
}
