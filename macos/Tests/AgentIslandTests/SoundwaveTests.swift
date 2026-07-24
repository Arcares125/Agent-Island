import Combine
import Foundation
import XCTest
@testable import AgentIsland

/// Detection tier: the model reflects whether system audio is currently playing.
final class SoundwaveTests: XCTestCase {
    @MainActor
    private func makeModel() -> IslandModel {
        let suite = "SoundwaveTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return IslandModel(defaults: defaults)
    }

    @MainActor
    func testAudioPlayingStateTracksDelegate() {
        let model = makeModel()
        XCTAssertFalse(model.isAudioPlaying)
        model.audioPlayingDidChange(true)
        XCTAssertTrue(model.isAudioPlaying)
        model.audioPlayingDidChange(false)
        XCTAssertFalse(model.isAudioPlaying)
    }

    @MainActor
    func testSpectrumPublishUpdatesStore() {
        let model = makeModel()
        XCTAssertEqual(model.spectrumStore.bars, [])
        model.spectrumDidUpdate([0.1, 0.5, 0.9, 0.4, 0.2, 0.0])
        XCTAssertEqual(model.spectrumStore.bars.count, 6)
        XCTAssertEqual(model.spectrumStore.bars[2], 0.9, accuracy: 0.0001)
    }

    /// Repeat frames (a steady tone, or silence) must not re-publish — every
    /// publish is a SwiftUI invalidation.
    @MainActor
    func testIdenticalSpectrumDoesNotRepublish() {
        let store = SpectrumStore()
        var publishes = 0
        let token = store.objectWillChange.sink { _ in publishes += 1 }
        store.update([0.2, 0.4])
        store.update([0.2, 0.4])
        store.update([0.2, 0.5])
        XCTAssertEqual(publishes, 2)
        token.cancel()
    }

    @MainActor
    func testSoundwaveGate() {
        let model = makeModel()
        XCTAssertFalse(model.isShowingSoundwave)
        model.setMusicVisualizerEnabled(true)
        model.audioPlayingDidChange(true)
        XCTAssertTrue(model.isShowingSoundwave)
        model.audioPlayingDidChange(false)
        XCTAssertFalse(model.isShowingSoundwave, "Nothing to show when nothing is playing")
    }

    /// The notch hosts the equalizer; the dashboard strip is the no-notch
    /// fallback. Exactly one of them draws.
    @MainActor
    func testNotchHostsTheEqualizerAndStripIsTheFallback() {
        let model = makeModel()
        model.setMusicVisualizerEnabled(true)
        model.audioPlayingDidChange(true)
        XCTAssertTrue(model.isShowingSoundwaveStrip, "No notch: the strip hosts it")
        XCTAssertFalse(model.isShowingSoundwaveWing, "No notch means no wing to draw into")

        model.setNotchPresentation(
            NotchPresentation(cameraWidth: 180, barHeight: 32, compactWidth: 420))
        XCTAssertTrue(model.isShowingSoundwaveWing, "With a notch it lives in the notch")
        XCTAssertFalse(model.isShowingSoundwaveStrip, "…and the dashboard does not stack a second")
    }

    /// Regression: the wing used to hide the equalizer whenever a session was
    /// running, and the notch is exactly where it should keep reacting.
    @MainActor
    func testNotchEqualizerSurvivesRunningSessionsAndExpansion() {
        let model = makeModel()
        model.setMusicVisualizerEnabled(true)
        model.audioPlayingDidChange(true)
        model.setNotchPresentation(
            NotchPresentation(cameraWidth: 180, barHeight: 32, compactWidth: 420))

        model.isHovered = true
        XCTAssertTrue(model.isExpanded)
        XCTAssertTrue(model.isShowingSoundwaveWing, "Opening the island must not hide it")

        model.isHovered = false
        XCTAssertTrue(model.isShowingSoundwaveWing, "Collapsed is its normal home")
    }

    /// Silence puts the notch back to its date/session face.
    @MainActor
    func testNotchEqualizerYieldsWhenAudioStops() {
        let model = makeModel()
        model.setMusicVisualizerEnabled(true)
        model.setNotchPresentation(
            NotchPresentation(cameraWidth: 180, barHeight: 32, compactWidth: 420))
        model.audioPlayingDidChange(true)
        XCTAssertTrue(model.isShowingSoundwaveWing)

        model.audioPlayingDidChange(false)
        XCTAssertFalse(model.isShowingSoundwaveWing)
    }
}
