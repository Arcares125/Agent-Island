import XCTest
@testable import AgentIsland

@MainActor
final class AnswerTransportTests: XCTestCase {

    // MARK: - Fixtures

    private func makeAsk(
        requestId: String = "req-1",
        sessionId: String? = "session-abc",
        cwd: String? = "/Users/dev/project",
        optionLabels: [String] = ["Alpha", "Beta"]
    ) -> AskRequestMessage {
        let options = optionLabels.map { PendingQuestionOption(label: $0, description: nil) }
        return AskRequestMessage(
            requestId: requestId,
            provider: .claude,
            sessionId: sessionId,
            cwd: cwd,
            question: PendingQuestion(prompt: "Pick one", header: "H", options: options)
        )
    }

    /// Records what the model handed to the transport.
    private func makeModel() -> (IslandModel, () -> [(String, Int?)]) {
        let model = IslandModel()
        let box = SentBox()
        model.answerHandler = { requestId, index in box.sent.append((requestId, index)) }
        return (model, { box.sent })
    }

    private final class SentBox {
        var sent: [(String, Int?)] = []
    }

    // MARK: - Presenting

    func testPresentsAnAnswerableQuestion() {
        let (model, _) = makeModel()
        model.presentAsk(makeAsk())
        XCTAssertEqual(model.pendingAsk?.requestId, "req-1")
    }

    func testIgnoresAQuestionWithNoOptions() {
        let (model, _) = makeModel()
        model.presentAsk(makeAsk(optionLabels: []))
        XCTAssertNil(
            model.pendingAsk,
            "A card with nothing to click would strand the agent with no way to answer")
    }

    // MARK: - Answering

    func testAnsweringSendsTheChosenIndexAndClearsTheCard() {
        let (model, sent) = makeModel()
        model.presentAsk(makeAsk())

        model.answerAsk(optionIndex: 1)

        XCTAssertEqual(sent().count, 1)
        XCTAssertEqual(sent().first?.0, "req-1")
        XCTAssertEqual(sent().first?.1, 1)
        XCTAssertNil(model.pendingAsk)
    }

    /// The boundary that stops the island becoming a way to inject text into an
    /// agent: only indices the agent itself offered may travel.
    func testRejectsAnIndexOutsideTheAgentsOwnOptions() {
        let (model, sent) = makeModel()
        model.presentAsk(makeAsk(optionLabels: ["Alpha", "Beta"]))

        model.answerAsk(optionIndex: 7)
        model.answerAsk(optionIndex: -1)

        XCTAssertTrue(sent().isEmpty, "An out-of-range pick must never reach the agent")
        XCTAssertNotNil(model.pendingAsk, "The question is still unanswered")
    }

    func testAnsweringWithNoPendingQuestionIsANoOp() {
        let (model, sent) = makeModel()
        model.answerAsk(optionIndex: 0)
        XCTAssertTrue(sent().isEmpty)
    }

    func testDismissingReleasesTheAgentWithoutAnAnswer() {
        let (model, sent) = makeModel()
        model.presentAsk(makeAsk())

        model.dismissAsk()

        XCTAssertEqual(sent().count, 1)
        XCTAssertNil(sent().first?.1, "Dismissal must send a null index, not a pick")
        XCTAssertNil(model.pendingAsk)
    }

    // MARK: - Retiring

    func testResolvingRetiresTheMatchingQuestion() {
        let (model, _) = makeModel()
        model.presentAsk(makeAsk(requestId: "req-1"))

        model.retireAsk(requestId: "req-1")

        XCTAssertNil(model.pendingAsk)
    }

    func testAStaleResolveCannotDismissANewerQuestion() {
        let (model, _) = makeModel()
        model.presentAsk(makeAsk(requestId: "req-2"))

        model.retireAsk(requestId: "req-1")

        XCTAssertEqual(
            model.pendingAsk?.requestId, "req-2",
            "A late resolve for an old request must not clear the current card")
    }

    // MARK: - Live behaviour

    /// The whole point: the user should not have to hover or click to discover
    /// that something is waiting on them.
    func testABlockedAgentHoldsTheIslandOpen() {
        let (model, _) = makeModel()
        XCTAssertFalse(model.isExpanded)

        model.presentAsk(makeAsk())
        XCTAssertTrue(model.isExpanded, "A blocked agent must open the island")

        model.answerAsk(optionIndex: 0)
        XCTAssertFalse(model.isExpanded, "Answering must release it again")
    }

    func testTheIslandStaysOpenUntilAnswered() {
        let (model, _) = makeModel()
        model.presentAsk(makeAsk())

        // The question peek is a 6s timer; a blocked agent must outlast it.
        model.endQuestionPeek()

        XCTAssertTrue(
            model.isExpanded,
            "Unlike a peek, a blocked agent has no timeout — nothing happens until the user acts")
    }

    func testAnsweringSuppressesTheStaleTranscriptCard() {
        let (model, _) = makeModel()
        let ask = makeAsk()
        let sameQuestion = ask.question

        model.presentAsk(ask)
        XCTAssertFalse(model.isAlreadyAnswered(sameQuestion))

        model.answerAsk(optionIndex: 0)

        XCTAssertTrue(
            model.isAlreadyAnswered(sameQuestion),
            "The transcript lags the answer; showing the read-only card again tells the user to answer what they just answered")
    }

    func testDismissingAlsoSuppressesTheStaleCard() {
        let (model, _) = makeModel()
        let ask = makeAsk()
        model.presentAsk(ask)
        model.dismissAsk()
        XCTAssertTrue(model.isAlreadyAnswered(ask.question))
    }

    func testADifferentQuestionIsNotSuppressed() {
        let (model, _) = makeModel()
        model.presentAsk(makeAsk())
        model.answerAsk(optionIndex: 0)

        let other = PendingQuestion(
            prompt: "A completely different question", header: nil,
            options: [PendingQuestionOption(label: "X", description: nil)])

        XCTAssertFalse(model.isAlreadyAnswered(other))
    }

    func testTheAgentsTabIsPulledForward() {
        let (model, _) = makeModel()
        model.selectedTab = .settings

        model.presentAsk(makeAsk())

        XCTAssertEqual(model.selectedTab, .agents, "The card lives in the Agents tab")
    }

    // MARK: - Routing to a session row

    func testMatchesItsSessionById() {
        let ask = makeAsk(sessionId: "session-abc", cwd: nil)
        XCTAssertTrue(ask.matches(session(id: "session-abc", workspace: "/elsewhere")))
        XCTAssertFalse(ask.matches(session(id: "other", workspace: "/elsewhere")))
    }

    func testFallsBackToWorkspaceWhenTheSessionIsNotKnownYet() {
        let ask = makeAsk(sessionId: nil, cwd: "/Users/dev/project")
        XCTAssertTrue(ask.matches(session(id: "anything", workspace: "/Users/dev/project")))
    }

    func testDoesNotMatchOnEmptyIdentifiers() {
        let ask = makeAsk(sessionId: "", cwd: "")
        XCTAssertFalse(
            ask.matches(session(id: "", workspace: "")),
            "Blank identifiers must not collide into a false match")
    }

    func testWorkspaceNameIsTheFolderNotThePath() {
        XCTAssertEqual(makeAsk(cwd: "/Users/dev/project").workspaceName, "project")
        XCTAssertNil(makeAsk(cwd: "").workspaceName)
        XCTAssertNil(makeAsk(cwd: nil).workspaceName)
    }

    // MARK: - Wire format

    func testAnswerLineCarriesThePick() {
        let line = AgentCoreClient.answerLine(requestId: "req-1", optionIndex: 2)
        XCTAssertEqual(line, "{\"type\":\"answer\",\"requestId\":\"req-1\",\"optionIndex\":2}\n")
    }

    func testAnswerLineOmitsTheIndexOnDismissal() {
        let line = AgentCoreClient.answerLine(requestId: "req-1", optionIndex: nil)
        XCTAssertEqual(line, "{\"type\":\"answer\",\"requestId\":\"req-1\"}\n")
    }

    func testAnswerLineEscapesTheRequestId() {
        let line = AgentCoreClient.answerLine(requestId: "a\"b\\c", optionIndex: 0)
        XCTAssertTrue(line.contains("a\\\"b\\\\c"), "Unescaped ids would break the sidecar's parse")
        XCTAssertEqual(line.filter { $0 == "\n" }.count, 1, "Only the terminating newline may appear")
    }

    // MARK: - Decoding

    func testDecodesAnAskFromTheSidecar() throws {
        let json = """
        {"type":"ask","requestId":"r-9","provider":"claude","sessionId":"s","cwd":"/tmp/w",\
        "question":{"prompt":"Pick","header":"H","options":[{"label":"A","description":"d"}]}}
        """
        let ask = try JSONDecoder().decode(AskRequestMessage.self, from: Data(json.utf8))

        XCTAssertEqual(ask.requestId, "r-9")
        XCTAssertEqual(ask.question.options.count, 1)
        XCTAssertEqual(ask.workspaceName, "w")
    }

    func testEnvelopeDistinguishesTrafficKinds() throws {
        let decoder = JSONDecoder()
        let ask = try decoder.decode(MessageEnvelope.self, from: Data("{\"type\":\"ask\"}".utf8))
        let snapshot = try decoder.decode(MessageEnvelope.self, from: Data("{\"type\":\"snapshot\"}".utf8))

        XCTAssertEqual(ask.type, "ask")
        XCTAssertEqual(snapshot.type, "snapshot")
    }

    // MARK: - Helpers

    private func session(id: String, workspace: String) -> AgentSessionSnapshot {
        AgentSessionSnapshot(
            id: id, provider: .claude, state: .question, task: "t", detail: "d",
            updatedSecondsAgo: 0, contextUsedTokens: nil, contextWindowTokens: nil,
            sessionTotalTokens: nil, rateLimitUsedPercent: nil, rateLimitResetsAt: nil,
            rateLimitWindowMinutes: nil, usageSource: nil, usageExact: nil,
            activityLog: nil, changedFiles: nil, workspacePath: workspace,
            modelName: nil, reasoningEffort: nil, latestPrompt: nil, pendingQuestion: nil)
    }
}
