import XCTest
@testable import AgentIsland

final class HookInstallerTests: XCTestCase {

    private let helper = "/Applications/Agent Island.app/Contents/Helpers/agent-core"
    private var command: String { AgentHookInstaller.command(forHelperAt: helper) }

    // MARK: - Command shape

    func testCommandQuotesThePathBecauseTheBundleNameHasASpace() {
        XCTAssertEqual(command, "\"\(helper)\" --ask-hook")
        XCTAssertTrue(command.hasPrefix("\""), "An unquoted path would split at 'Agent Island'")
    }

    // MARK: - Installing

    func testInstallsIntoAnEmptyConfig() {
        let result = AgentHookInstaller.installing(command: command, into: [:], target: .claude)
        XCTAssertTrue(AgentHookInstaller.isInstalled(in: result, target: .claude))
    }

    func testUsesEachAgentsOwnEventAndToolNames() {
        let claude = AgentHookInstaller.installing(command: command, into: [:], target: .claude)
        let codex = AgentHookInstaller.installing(command: command, into: [:], target: .codex)

        XCTAssertNotNil((claude["hooks"] as? [String: Any])?["PreToolUse"])
        XCTAssertNotNil((codex["hooks"] as? [String: Any])?["pre_tool_use"])
        XCTAssertEqual(firstMatcher(claude, event: "PreToolUse"), "AskUserQuestion")
        XCTAssertEqual(firstMatcher(codex, event: "pre_tool_use"), "request_user_input")
    }

    /// The user's own settings must survive; this file is theirs, not ours.
    func testPreservesUnrelatedSettings() {
        let existing: [String: Any] = [
            "model": "opus",
            "effortLevel": "xhigh",
            "enabledPlugins": ["superpowers": true],
        ]

        let result = AgentHookInstaller.installing(command: command, into: existing, target: .claude)

        XCTAssertEqual(result["model"] as? String, "opus")
        XCTAssertEqual(result["effortLevel"] as? String, "xhigh")
        XCTAssertNotNil(result["enabledPlugins"])
    }

    func testPreservesSomebodyElsesHooks() {
        let existing: [String: Any] = ["hooks": [
            "PreToolUse": [[
                "matcher": "Bash",
                "hooks": [["type": "command", "command": "/usr/local/bin/audit-bash"]],
            ]],
            "SessionStart": [[
                "hooks": [["type": "command", "command": "/usr/local/bin/greet"]],
            ]],
        ]]

        let result = AgentHookInstaller.installing(command: command, into: existing, target: .claude)
        let hooks = result["hooks"] as? [String: Any]

        XCTAssertNotNil(hooks?["SessionStart"], "An unrelated event must be untouched")
        XCTAssertEqual((hooks?["PreToolUse"] as? [[String: Any]])?.count, 2,
                       "Our hook must be added alongside theirs, not replace it")
    }

    func testInstallingTwiceDoesNotStackDuplicates() {
        var result = AgentHookInstaller.installing(command: command, into: [:], target: .claude)
        result = AgentHookInstaller.installing(command: command, into: result, target: .claude)

        let events = (result["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]]
        XCTAssertEqual(events?.count, 1, "A second install would double-fire the hook")
    }

    // MARK: - Removing

    func testRemovingRestoresTheOriginalShape() {
        let original: [String: Any] = ["model": "opus"]
        let installed = AgentHookInstaller.installing(command: command, into: original, target: .claude)
        let removed = AgentHookInstaller.removing(from: installed, target: .claude)

        XCTAssertNil(removed["hooks"], "An empty hooks container must not be left behind")
        XCTAssertEqual(removed["model"] as? String, "opus")
        XCTAssertFalse(AgentHookInstaller.isInstalled(in: removed, target: .claude))
    }

    func testRemovingLeavesOtherPeoplesHooksAlone() {
        let existing: [String: Any] = ["hooks": [
            "PreToolUse": [[
                "matcher": "Bash",
                "hooks": [["type": "command", "command": "/usr/local/bin/audit-bash"]],
            ]],
        ]]

        let installed = AgentHookInstaller.installing(command: command, into: existing, target: .claude)
        let removed = AgentHookInstaller.removing(from: installed, target: .claude)

        let events = (removed["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]]
        XCTAssertEqual(events?.count, 1)
        XCTAssertEqual(events?.first?["matcher"] as? String, "Bash")
    }

    /// A group that also carries a third-party command must keep that command
    /// rather than being dropped wholesale.
    func testRemovingPrunesOnlyOurCommandFromASharedGroup() {
        let shared: [String: Any] = ["hooks": [
            "PreToolUse": [[
                "matcher": "AskUserQuestion",
                "hooks": [
                    ["type": "command", "command": "/usr/local/bin/log-questions"],
                    ["type": "command", "command": "\"\(helper)\" --ask-hook"],
                ],
            ]],
        ]]

        let removed = AgentHookInstaller.removing(from: shared, target: .claude)
        let commands = ((removed["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]])?
            .first?["hooks"] as? [[String: Any]]

        XCTAssertEqual(commands?.count, 1)
        XCTAssertEqual(commands?.first?["command"] as? String, "/usr/local/bin/log-questions")
    }

    func testRemovingFromAConfigThatNeverHadItIsHarmless() {
        let existing: [String: Any] = ["model": "opus"]
        let removed = AgentHookInstaller.removing(from: existing, target: .claude)
        XCTAssertEqual(removed["model"] as? String, "opus")
        XCTAssertNil(removed["hooks"])
    }

    /// Matching on the argument, not the path, so a moved or reinstalled app
    /// still cleans up after itself.
    func testRemovesAnEntryWrittenByADifferentInstallLocation() {
        let stale: [String: Any] = ["hooks": [
            "PreToolUse": [[
                "matcher": "AskUserQuestion",
                "hooks": [["type": "command", "command": "\"/Users/someone/Desktop/Agent Island.app/Contents/Helpers/agent-core\" --ask-hook"]],
            ]],
        ]]

        XCTAssertTrue(AgentHookInstaller.isInstalled(in: stale, target: .claude))
        XCTAssertNil(AgentHookInstaller.removing(from: stale, target: .claude)["hooks"])
    }

    // MARK: - Detection

    func testDoesNotMistakeAnUnrelatedHookForOurs() {
        let other: [String: Any] = ["hooks": [
            "PreToolUse": [[
                "matcher": "AskUserQuestion",
                "hooks": [["type": "command", "command": "/usr/local/bin/something-else"]],
            ]],
        ]]
        XCTAssertFalse(AgentHookInstaller.isInstalled(in: other, target: .claude))
    }

    func testEachAgentIsDetectedIndependently() {
        let claudeOnly = AgentHookInstaller.installing(command: command, into: [:], target: .claude)
        XCTAssertTrue(AgentHookInstaller.isInstalled(in: claudeOnly, target: .claude))
        XCTAssertFalse(AgentHookInstaller.isInstalled(in: claudeOnly, target: .codex))
    }

    // MARK: - Round trip through JSON

    /// The real file goes through JSONSerialization, so the transforms have to
    /// survive that trip rather than only working on in-memory dictionaries.
    func testSurvivesASerializationRoundTrip() throws {
        let installed = AgentHookInstaller.installing(
            command: command, into: ["model": "opus"], target: .claude)

        let data = try JSONSerialization.data(withJSONObject: installed)
        let decoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertTrue(AgentHookInstaller.isInstalled(in: decoded, target: .claude))
        XCTAssertNil(AgentHookInstaller.removing(from: decoded, target: .claude)["hooks"])
    }

    func testConfigPathsPointAtEachAgentsOwnHome() {
        let claude = AgentHookInstaller.Target.claude.settingsURLs
        let codex = AgentHookInstaller.Target.codex.settingsURLs

        XCTAssertTrue(claude.allSatisfy { $0.lastPathComponent == "settings.json" })
        XCTAssertTrue(claude.contains { $0.path.hasSuffix(".claude/settings.json") },
                      "The default profile must always be a target")
        XCTAssertEqual(codex.count, 1)
        XCTAssertTrue(codex[0].path.hasSuffix("hooks/hooks.json"))
    }

    /// A session started with CLAUDE_CONFIG_DIR reads a different settings file,
    /// so installing only into the default root would silently do nothing there.
    func testCoversASecondClaudeProfileWhenOneExists() throws {
        let alternate = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude2")
        guard FileManager.default.fileExists(atPath: alternate.path) else {
            throw XCTSkip("No second Claude profile on this machine")
        }

        XCTAssertTrue(
            AgentHookInstaller.Target.claude.settingsURLs
                .contains { $0.path.hasSuffix(".claude2/settings.json") })
    }

    // MARK: - Helpers

    private func firstMatcher(_ settings: [String: Any], event: String) -> String? {
        ((settings["hooks"] as? [String: Any])?[event] as? [[String: Any]])?
            .first?["matcher"] as? String
    }
}
