import Foundation
import XCTest
@testable import AgentIsland

/// The in-island gear panel edits two hover delays that persist across launches
/// and keep the island expanded while open.
final class HoverSettingsTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "HoverSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @MainActor
    func testDefaultsWhenNothingPersisted() {
        let model = IslandModel(defaults: makeDefaults())
        XCTAssertEqual(model.hoverOpenDelay, 0, accuracy: 0.0001)
        XCTAssertEqual(model.hoverCloseDelay, 0.6, accuracy: 0.0001)
    }

    @MainActor
    func testChangingDelaysPersistsAndReloads() {
        let defaults = makeDefaults()
        let model = IslandModel(defaults: defaults)
        model.setHoverOpenDelay(0.4)
        model.setHoverCloseDelay(1.0)

        // A fresh model reading the same store should recover the chosen values.
        let reloaded = IslandModel(defaults: defaults)
        XCTAssertEqual(reloaded.hoverOpenDelay, 0.4, accuracy: 0.0001)
        XCTAssertEqual(reloaded.hoverCloseDelay, 1.0, accuracy: 0.0001)
    }

    @MainActor
    func testVolumePopupDefaultsOnAndPersists() {
        let defaults = makeDefaults()
        let model = IslandModel(defaults: defaults)
        XCTAssertTrue(model.volumePopupEnabled, "Volume pop-up ships ON")

        model.setVolumePopupEnabled(false)
        let reloaded = IslandModel(defaults: defaults)
        XCTAssertFalse(reloaded.volumePopupEnabled)
    }

    @MainActor
    func testMusicVisualizerDefaultsOffAndPersists() {
        let defaults = makeDefaults()
        let model = IslandModel(defaults: defaults)
        XCTAssertFalse(model.musicVisualizerEnabled, "Visualizer ships OFF (needs permission)")
        model.setMusicVisualizerEnabled(true)
        let reloaded = IslandModel(defaults: defaults)
        XCTAssertTrue(reloaded.musicVisualizerEnabled)
    }

    @MainActor
    func testTabDefaultsToAgentsAndSwitches() {
        let model = IslandModel(defaults: makeDefaults())
        XCTAssertEqual(model.selectedTab, .agents, "Fresh model opens on Agents")

        model.selectTab(.settings)
        XCTAssertEqual(model.selectedTab, .settings)

        model.selectTab(.shelf)
        XCTAssertEqual(model.selectedTab, .shelf)
    }

    @MainActor
    func testDashboardHeightMatchesSelectedTab() {
        let model = IslandModel(defaults: makeDefaults())
        model.apply(thinkingSessionSnapshot())
        model.setHovered(true)

        // Non-notch monitoring header is 56pt; +80 chrome + the tab's content.
        let base: CGFloat = 56 + 80
        model.selectTab(.settings)
        XCTAssertEqual(
            model.preferredSize.height,
            base + IslandModel.settingsTabContentHeight,
            accuracy: 0.5
        )
        model.selectTab(.shelf)
        XCTAssertEqual(
            model.preferredSize.height,
            base + IslandModel.shelfTabContentHeight,
            accuracy: 0.5
        )
    }

    @MainActor
    func testPresetsAreDistinctAndOrdered() {
        XCTAssertEqual(IslandModel.openDelayPresets, [0, 0.2, 0.4, 0.6, 1.0])
        XCTAssertEqual(IslandModel.closeDelayPresets, [0.2, 0.4, 0.6, 1.0, 1.5])
    }

    private func thinkingSessionSnapshot() -> AgentSnapshot {
        let json = """
        {
          "type": "snapshot", "provider": "claude", "state": "thinking",
          "task": "t", "detail": "d", "elapsedSeconds": 1,
          "sessions": [
            { "id": "s1", "provider": "claude", "state": "thinking",
              "task": "t", "detail": "d", "updatedSecondsAgo": 1 }
          ]
        }
        """
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(AgentSnapshot.self, from: Data(json.utf8))
    }
}
