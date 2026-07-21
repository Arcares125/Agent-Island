import Foundation
import XCTest
@testable import AgentIsland

/// A pending agent question must announce itself by expanding once, then behave
/// like any other expanded island: hover and pin govern it, and a continuing
/// question must never re-lock the panel open on every telemetry snapshot.
final class IslandQuestionExpansionTests: XCTestCase {
    @MainActor
    func testNewQuestionAutoExpandsOnce() {
        let model = IslandModel()
        model.apply(snapshot(sessionState: .thinking))
        XCTAssertFalse(model.isExpanded, "A working session should stay compact")

        model.apply(snapshot(sessionState: .question))
        XCTAssertTrue(model.isExpanded, "A newly arrived question should auto-expand")
    }

    @MainActor
    func testDismissedQuestionDoesNotRelockOnNextSnapshot() {
        let model = IslandModel()
        model.apply(snapshot(sessionState: .thinking))
        model.apply(snapshot(sessionState: .question))

        // The user (or the peek timeout) dismisses the announcement.
        model.endQuestionPeek()
        XCTAssertFalse(model.isExpanded, "Dismissed question should collapse")

        // The same question is still pending on the next poll — it must NOT re-lock.
        model.apply(snapshot(sessionState: .question))
        XCTAssertFalse(model.isExpanded, "A continuing question must not re-lock the panel")
    }

    @MainActor
    func testHoverOutCollapsesDuringQuestion() {
        let model = IslandModel()
        model.apply(snapshot(sessionState: .question))
        model.endQuestionPeek()

        model.setHovered(true)
        XCTAssertTrue(model.isExpanded, "Hovering a pending question should expand it")

        model.setHovered(false)
        XCTAssertFalse(model.isExpanded, "Moving away from a pending question should collapse it")
    }

    @MainActor
    func testGenuinelyNewQuestionReannounces() {
        let model = IslandModel()
        model.apply(snapshot(sessionState: .question))
        model.endQuestionPeek()
        XCTAssertFalse(model.isExpanded)

        // A different session raising a question is a new transition and should re-announce.
        model.apply(snapshot(sessionState: .question, sessionID: "session-2"))
        XCTAssertTrue(model.isExpanded, "A second agent's question should re-announce")
    }

    @MainActor
    func testTogglePinnedWorksDuringQuestion() {
        let model = IslandModel()
        model.apply(snapshot(sessionState: .question))
        model.endQuestionPeek()
        XCTAssertFalse(model.isExpanded)

        model.togglePinned()
        XCTAssertTrue(model.isPinnedOpen, "Pin must be toggleable while a question is pending")
        XCTAssertTrue(model.isExpanded)
    }

    @MainActor
    func testManualQuestionPreviewPeeksThenCollapsesToCompact() {
        let model = IslandModel()
        model.setPhase(.question)
        XCTAssertTrue(model.isExpanded, "Selecting the question preview should expand")
        XCTAssertEqual(model.preferredSize.height, 320, accuracy: 0.5)

        model.endQuestionPeek()
        XCTAssertFalse(model.isExpanded, "A dismissed question preview should collapse")
        XCTAssertEqual(
            model.preferredSize.height,
            56,
            accuracy: 0.5,
            "Dismissed question must collapse to the compact pill, not stay full height"
        )
    }

    // MARK: - Fixtures

    private func snapshot(
        sessionState: AgentPhase,
        sessionID: String = "session-1"
    ) -> AgentSnapshot {
        let json = """
        {
          "type": "snapshot",
          "provider": "claude",
          "state": "\(sessionState.rawValue)",
          "task": "Test task",
          "detail": "Test detail",
          "elapsedSeconds": 3,
          "sessions": [
            {
              "id": "\(sessionID)",
              "provider": "claude",
              "state": "\(sessionState.rawValue)",
              "task": "Test task",
              "detail": "Test detail",
              "updatedSecondsAgo": 3
            }
          ]
        }
        """
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(AgentSnapshot.self, from: Data(json.utf8))
    }
}
