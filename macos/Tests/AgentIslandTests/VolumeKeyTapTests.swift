import XCTest
@testable import AgentIsland

final class VolumeKeyTapTests: XCTestCase {

    // MARK: - Decoding media keys

    /// `data1` packs the key code into the high half and the state into the
    /// second byte. `0x0A` is down, `0x0B` is up, bit 0 marks auto-repeat.
    private func data1(keyCode: Int, down: Bool, repeated: Bool = false) -> Int {
        (keyCode << 16) | ((down ? 0x0A : 0x0B) << 8) | (repeated ? 1 : 0)
    }

    func testDecodesTheThreeVolumeKeys() {
        XCTAssertEqual(
            decodeMediaKey(data1: data1(keyCode: 0, down: true))?.action, .volumeUp)
        XCTAssertEqual(
            decodeMediaKey(data1: data1(keyCode: 1, down: true))?.action, .volumeDown)
        XCTAssertEqual(
            decodeMediaKey(data1: data1(keyCode: 7, down: true))?.action, .mute)
    }

    /// Anything else must fall through untouched — swallowing brightness or
    /// playback keys would break them for the whole system.
    func testIgnoresKeysThatAreNotVolume() {
        for keyCode in [2, 3, 4, 16, 19, 20, 21] {
            XCTAssertNil(
                decodeMediaKey(data1: data1(keyCode: keyCode, down: true)),
                "key code \(keyCode) must pass through")
        }
    }

    func testDistinguishesPressFromRelease() {
        XCTAssertEqual(decodeMediaKey(data1: data1(keyCode: 0, down: true))?.isDown, true)
        XCTAssertEqual(decodeMediaKey(data1: data1(keyCode: 0, down: false))?.isDown, false)
    }

    func testDetectsAutoRepeat() {
        XCTAssertEqual(
            decodeMediaKey(data1: data1(keyCode: 1, down: true, repeated: true))?.isRepeat, true)
        XCTAssertEqual(
            decodeMediaKey(data1: data1(keyCode: 1, down: true))?.isRepeat, false)
    }

    // MARK: - Volume arithmetic

    func testMovesOneSixteenthPerPress() {
        XCTAssertEqual(steppedVolume(current: 0.5, up: true), 0.5625, accuracy: 0.0001)
        XCTAssertEqual(steppedVolume(current: 0.5, up: false), 0.4375, accuracy: 0.0001)
    }

    func testShiftOptionGivesQuarterSteps() {
        XCTAssertEqual(
            steppedVolume(current: 0.5, up: true, fineGrained: true), 0.515625, accuracy: 0.0001)
    }

    /// Snapping to the grid rather than adding a delta is what keeps a swallowed
    /// key landing on the same notches the system HUD would have shown.
    func testSnapsAnOffGridLevelOntoTheGrid() {
        let next = steppedVolume(current: 0.53, up: true)
        XCTAssertEqual(next, 0.5625, accuracy: 0.0001,
                       "0.53 rounds to 8/16, so one press up is 9/16")
    }

    func testDoesNotDriftOverManyPresses() {
        var level: Float = 0
        for _ in 0..<16 { level = steppedVolume(current: level, up: true) }
        XCTAssertEqual(level, 1.0, accuracy: 0.0001, "16 presses from silence must reach full")

        for _ in 0..<16 { level = steppedVolume(current: level, up: false) }
        XCTAssertEqual(level, 0.0, accuracy: 0.0001, "and 16 back must reach silence exactly")
    }

    func testClampsAtBothEnds() {
        XCTAssertEqual(steppedVolume(current: 1, up: true), 1)
        XCTAssertEqual(steppedVolume(current: 0, up: false), 0)
    }

    func testHandlesOutOfRangeInput() {
        XCTAssertEqual(steppedVolume(current: 5, up: true), 1)
        XCTAssertEqual(steppedVolume(current: -3, up: false), 0)
        XCTAssertGreaterThanOrEqual(steppedVolume(current: -3, up: true), 0)
    }

    // MARK: - Permission gate

    /// The tap can only suppress with Accessibility, so it must refuse to start
    /// without it rather than sitting there consuming events it cannot handle.
    @MainActor
    func testDoesNotStartWithoutAccessibility() throws {
        guard !VolumeKeyTap.hasAccessibilityPermission() else {
            throw XCTSkip("Accessibility is granted on this machine")
        }
        let tap = VolumeKeyTap()
        XCTAssertFalse(tap.start())
        XCTAssertFalse(tap.isRunning)
    }

    @MainActor
    func testStoppingAnIdleTapIsHarmless() {
        let tap = VolumeKeyTap()
        tap.stop()
        XCTAssertFalse(tap.isRunning)
    }
}
