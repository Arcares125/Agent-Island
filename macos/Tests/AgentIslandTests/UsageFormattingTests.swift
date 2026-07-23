import Foundation
import XCTest
@testable import AgentIsland

/// The rate-limit reset readout under the usage meter. The formatter behind it
/// is shared across renders, so these also guard against a cached formatter
/// drifting from the per-call behaviour it replaced.
final class UsageFormattingTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "UsageFormattingTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @MainActor
    func testResetTextIsNilWithoutTimestamp() {
        let model = IslandModel(defaults: makeDefaults())
        model.rateLimitResetsAt = nil
        XCTAssertNil(model.resetText)
    }

    @MainActor
    func testResetTextReportsNowForPastTimestamps() {
        let model = IslandModel(defaults: makeDefaults())
        model.rateLimitResetsAt = Int64(Date().addingTimeInterval(-60).timeIntervalSince1970)
        XCTAssertEqual(model.resetText, "now")
    }

    @MainActor
    func testResetTextDescribesFutureTimestamps() {
        let model = IslandModel(defaults: makeDefaults())
        model.rateLimitResetsAt = Int64(
            Date().addingTimeInterval(2 * 60 * 60).timeIntervalSince1970
        )
        let text = model.resetText
        XCTAssertNotNil(text)
        XCTAssertNotEqual(text, "now")
    }

    /// Repeated evaluation must stay stable: the shared formatter is a cache,
    /// not a state machine.
    @MainActor
    func testResetTextIsStableAcrossRepeatedReads() {
        let model = IslandModel(defaults: makeDefaults())
        model.rateLimitResetsAt = Int64(
            Date().addingTimeInterval(3 * 60 * 60).timeIntervalSince1970
        )
        XCTAssertEqual(model.resetText, model.resetText)
    }
}
