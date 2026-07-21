import Foundation
import XCTest
@testable import AgentIsland

/// The read-only inline question is decoded from the helper snapshot and surfaced
/// from the selected session so the island can show the choices.
final class PendingQuestionTests: XCTestCase {
    @MainActor
    func testSurfacesPendingQuestionFromSelectedSession() {
        let model = IslandModel()
        model.apply(questionSnapshot(includeQuestion: true))

        let question = model.pendingQuestion
        XCTAssertEqual(question?.prompt, "Which theme?")
        XCTAssertEqual(question?.header, "Theme")
        XCTAssertEqual(question?.options.map(\.label), ["Dark", "Light"])
        XCTAssertEqual(question?.options.first?.description, "Matches the terminal")
    }

    @MainActor
    func testNoQuestionWhenHelperOmitsIt() {
        let model = IslandModel()
        model.apply(questionSnapshot(includeQuestion: false))
        XCTAssertNil(model.pendingQuestion, "A null pendingQuestion must surface as nil")
    }

    @MainActor
    func testSessionSnapshotDecodesOptions() throws {
        let snapshot = questionSnapshot(includeQuestion: true)
        let session = try XCTUnwrap(snapshot.sessions?.first)
        XCTAssertEqual(session.pendingQuestion?.options.count, 2)
    }

    private func questionSnapshot(includeQuestion: Bool) -> AgentSnapshot {
        let questionJSON = includeQuestion
            ? """
              "pendingQuestion": {
                "prompt": "Which theme?",
                "header": "Theme",
                "options": [
                  { "label": "Dark", "description": "Matches the terminal" },
                  { "label": "Light", "description": null }
                ]
              }
              """
            : "\"pendingQuestion\": null"

        let json = """
        {
          "type": "snapshot", "provider": "claude", "state": "question",
          "task": "t", "detail": "d", "elapsedSeconds": 1,
          "sessions": [
            {
              "id": "s1", "provider": "claude", "state": "question",
              "task": "t", "detail": "d", "updatedSecondsAgo": 1,
              \(questionJSON)
            }
          ]
        }
        """
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(AgentSnapshot.self, from: Data(json.utf8))
    }
}
