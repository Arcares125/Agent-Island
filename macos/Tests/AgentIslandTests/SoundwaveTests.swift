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

    /// With a notch the equalizer lives in the notch wing, so the expanded
    /// dashboard must not also stack a strip.
    @MainActor
    func testNotchHostsSoundwaveInsteadOfStrip() {
        let model = makeModel()
        model.setMusicVisualizerEnabled(true)
        model.audioPlayingDidChange(true)
        XCTAssertTrue(model.isShowingSoundwaveStrip, "No notch: falls back to the strip")

        model.setNotchPresentation(
            NotchPresentation(cameraWidth: 180, barHeight: 32, compactWidth: 420))
        XCTAssertTrue(model.isShowingSoundwave, "Still shown — in the notch wing")
        XCTAssertFalse(
            model.isShowingSoundwaveStrip,
            "Notch wing hosts it, so the dashboard neither draws nor reserves a strip")
    }
}
