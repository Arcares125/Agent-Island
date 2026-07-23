import Foundation
import XCTest
@testable import AgentIsland

/// A volume change transiently pops the island open into the tug-of-war HUD,
/// which a real hover takes over and which auto-collapses on end.
final class VolumeHUDTests: XCTestCase {
    @MainActor
    private func makeModel() -> IslandModel {
        let suite = "VolumeHUDTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return IslandModel(defaults: defaults)
    }

    @MainActor
    func testVolumeChangeBeginsPeekAndExpands() {
        let model = makeModel()
        model.handleVolumeChange(level: 0.5, delta: 0.1)
        XCTAssertTrue(model.isVolumePeeking)
        XCTAssertTrue(model.isExpanded)
        XCTAssertTrue(model.isShowingVolumeHUD)
        XCTAssertEqual(model.outputVolumeLevel, 0.5, accuracy: 0.0001)
        XCTAssertEqual(model.volumeTugDirection, .towardCodex)
    }

    @MainActor
    func testDownChangeTugsTowardClaude() {
        let model = makeModel()
        model.handleVolumeChange(level: 0.3, delta: -0.1)
        XCTAssertEqual(model.volumeTugDirection, .towardClaude)
    }

    @MainActor
    func testDisabledPopupIgnoresVolumeChange() {
        let model = makeModel()
        model.setVolumePopupEnabled(false)
        model.handleVolumeChange(level: 0.5, delta: 0.1)
        XCTAssertFalse(model.isVolumePeeking)
        XCTAssertFalse(model.isExpanded)
    }

    @MainActor
    func testNoDirectionChangeDoesNotPeek() {
        let model = makeModel()
        model.handleVolumeChange(level: 0.5, delta: 0)
        XCTAssertFalse(model.isVolumePeeking)
    }

    @MainActor
    func testHoverDuringPeekTakesOver() {
        let model = makeModel()
        model.handleVolumeChange(level: 0.5, delta: 0.1)
        model.setHovered(true)
        XCTAssertFalse(model.isVolumePeeking)   // hover ended the transient peek
        XCTAssertFalse(model.isShowingVolumeHUD)
        XCTAssertTrue(model.isExpanded)         // still expanded, now via hover
    }

    @MainActor
    func testEndVolumePeekCollapses() {
        let model = makeModel()
        model.handleVolumeChange(level: 0.5, delta: 0.1)
        model.endVolumePeek()
        XCTAssertFalse(model.isVolumePeeking)
        XCTAssertFalse(model.isExpanded)
    }

    @MainActor
    func testVolumeChangeWhileHoveredDoesNotPeek() {
        let model = makeModel()
        model.setHovered(true)
        model.handleVolumeChange(level: 0.5, delta: 0.1)
        XCTAssertFalse(model.isVolumePeeking, "No transient peek while actively hovering")
        model.setHovered(false)
        XCTAssertFalse(model.isVolumePeeking, "And nothing leaks in after hover ends")
        XCTAssertFalse(model.isShowingVolumeHUD)
    }

    @MainActor
    func testVolumeChangeWhilePinnedDoesNotPeek() {
        let model = makeModel()
        model.togglePinned()            // pin open
        XCTAssertTrue(model.isPinnedOpen)
        model.handleVolumeChange(level: 0.5, delta: 0.1)
        XCTAssertFalse(model.isVolumePeeking)
        model.togglePinned()            // unpin
        XCTAssertFalse(model.isVolumePeeking, "No stale peek surfaces after unpin")
    }

    @MainActor
    func testFileDragStartDropsInFlightPeek() {
        let model = makeModel()
        model.handleVolumeChange(level: 0.5, delta: 0.1)
        XCTAssertTrue(model.isVolumePeeking)
        model.setFileDragTargeted(true)
        XCTAssertFalse(model.isVolumePeeking, "A starting drag drops the visible peek")
        model.setFileDragTargeted(false)
        XCTAssertFalse(model.isVolumePeeking, "And it doesn't resurface when the drag ends")
    }

    @MainActor
    func testVolumeHUDSizeFitsOverlaidHeader() {
        let model = makeModel()
        let minBodyNeeded: CGFloat = 82  // title + living rope arena + result caption + padding

        model.handleVolumeChange(level: 0.5, delta: 0.1)
        XCTAssertTrue(model.isShowingVolumeHUD)
        XCTAssertGreaterThanOrEqual(
            model.volumeHUDSize.height - model.persistentHeaderSize.height, minBodyNeeded)
        XCTAssertGreaterThanOrEqual(model.volumeHUDSize.width, model.persistentHeaderSize.width)

        // Live-dashboard header (monitoring + sessions) is the wider/taller case.
        model.apply(thinkingSessionSnapshot())
        XCTAssertGreaterThanOrEqual(
            model.volumeHUDSize.height - model.persistentHeaderSize.height, minBodyNeeded)
        XCTAssertGreaterThanOrEqual(model.volumeHUDSize.width, model.persistentHeaderSize.width)
    }

    @MainActor
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
