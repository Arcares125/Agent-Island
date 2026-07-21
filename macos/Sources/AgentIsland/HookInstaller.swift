import Foundation

/// Installs and removes the `PreToolUse` hook that lets the island answer a
/// blocked agent.
///
/// This is the only place the app writes outside its own container, so the rules
/// are strict: merge rather than replace, back up before the first change, and
/// leave the file byte-for-byte reversible when the user turns the toggle off.
/// Entries are identified solely by the `--ask-hook` argument, so a hand-edited
/// or third-party hook is never touched.
enum AgentHookInstaller {

    /// Both CLIs run hook commands through a shell, and the app bundle has a
    /// space in its name, so the path is always quoted.
    static let helperArgument = "--ask-hook"
    /// Long enough for a considered answer, short enough that a forgotten
    /// question does not pin the agent for the rest of the session. The sidecar
    /// gives up slightly sooner so the fallback is ours, not a hook kill.
    static let hookTimeoutSeconds = 120

    /// Where each agent keeps its hook configuration, and how it spells the
    /// question tool. Claude uses CamelCase event names, Codex snake_case.
    enum Target: CaseIterable {
        case claude
        case codex

        /// Every config root this agent might actually read.
        ///
        /// A second profile via `CLAUDE_CONFIG_DIR` is common enough that the
        /// sidecar already tails both `~/.claude` and `~/.claude2`; installing
        /// into only the default would put the hook where that session never
        /// looks. The app cannot see a terminal's environment, so existence on
        /// disk is the signal. The primary root is always included so a first
        /// install has somewhere to go.
        var settingsURLs: [URL] {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let manager = FileManager.default

            switch self {
            case .claude:
                var roots = [home.appendingPathComponent(".claude")]
                let alternate = home.appendingPathComponent(".claude2")
                if manager.fileExists(atPath: alternate.path) { roots.append(alternate) }
                return roots.map { $0.appendingPathComponent("settings.json") }

            case .codex:
                let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
                    .map { URL(fileURLWithPath: $0) }
                    ?? home.appendingPathComponent(".codex")
                return [codexHome.appendingPathComponent("hooks/hooks.json")]
            }
        }

        var eventKey: String {
            switch self {
            case .claude: return "PreToolUse"
            case .codex: return "pre_tool_use"
            }
        }

        var matcher: String {
            switch self {
            case .claude: return "AskUserQuestion"
            case .codex: return "request_user_input"
            }
        }

        var displayName: String {
            switch self {
            case .claude: return "Claude Code"
            case .codex: return "Codex"
            }
        }
    }

    // MARK: - Pure configuration transforms

    /// Add our hook group, replacing any earlier copy of it so repeated installs
    /// cannot stack up duplicates.
    static func installing(
        command: String, into settings: [String: Any], target: Target
    ) -> [String: Any] {
        var settings = removing(from: settings, target: target)

        let entry: [String: Any] = [
            "matcher": target.matcher,
            "hooks": [[
                "type": "command",
                "command": command,
                "timeout": hookTimeoutSeconds,
            ]],
        ]

        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var events = hooks[target.eventKey] as? [[String: Any]] ?? []
        events.append(entry)
        hooks[target.eventKey] = events
        settings["hooks"] = hooks
        return settings
    }

    /// Strip our hook and every container it leaves empty, so turning the toggle
    /// off restores the file's original shape rather than leaving `{"hooks":{}}`.
    static func removing(from settings: [String: Any], target: Target) -> [String: Any] {
        var settings = settings
        guard var hooks = settings["hooks"] as? [String: Any],
              let events = hooks[target.eventKey] as? [[String: Any]] else {
            return settings
        }

        let surviving = events.compactMap { group -> [String: Any]? in
            guard let commands = group["hooks"] as? [[String: Any]] else { return group }
            let kept = commands.filter { !isOurs($0) }
            if kept.isEmpty { return nil }
            var group = group
            group["hooks"] = kept
            return group
        }

        if surviving.isEmpty {
            hooks.removeValue(forKey: target.eventKey)
        } else {
            hooks[target.eventKey] = surviving
        }

        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }
        return settings
    }

    static func isInstalled(in settings: [String: Any], target: Target) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any],
              let events = hooks[target.eventKey] as? [[String: Any]] else { return false }
        return events.contains { group in
            (group["hooks"] as? [[String: Any]])?.contains(where: isOurs) ?? false
        }
    }

    /// Ours is any command invoking the helper. Matching on the argument rather
    /// than the full path means a moved or reinstalled app still cleans up.
    private static func isOurs(_ command: [String: Any]) -> Bool {
        (command["command"] as? String)?.contains(helperArgument) ?? false
    }

    /// The shell command an agent runs to reach the island.
    static func command(forHelperAt path: String) -> String {
        "\"\(path)\" \(helperArgument)"
    }

    // MARK: - Disk

    enum InstallError: Error {
        case helperMissing
        case unreadableSettings(String)
        case writeFailed(String)
    }

    @discardableResult
    static func setInstalled(_ installed: Bool, target: Target) throws -> Bool {
        guard let helper = AgentCoreBinary.locate()?.path else {
            if installed { throw InstallError.helperMissing }
            return false
        }

        for url in target.settingsURLs {
            var settings = try readSettings(at: url)
            settings = installed
                ? installing(command: command(forHelperAt: helper), into: settings, target: target)
                : removing(from: settings, target: target)
            try writeSettings(settings, to: url)
        }
        return installed
    }

    /// Installed if *any* root has it — a profile the user answers from counts,
    /// even when a second profile does not.
    static func isInstalled(target: Target) -> Bool {
        target.settingsURLs.contains { url in
            guard let settings = try? readSettings(at: url) else { return false }
            return isInstalled(in: settings, target: target)
        }
    }

    /// A missing file is an empty config, not an error — Codex has no
    /// `hooks.json` until something creates one.
    private static func readSettings(at url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        guard let data = try? Data(contentsOf: url) else {
            throw InstallError.unreadableSettings(url.lastPathComponent)
        }
        if data.isEmpty { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let settings = object as? [String: Any] else {
            // Refuse rather than overwrite a file we cannot round-trip.
            throw InstallError.unreadableSettings(url.lastPathComponent)
        }
        return settings
    }

    private static func writeSettings(_ settings: [String: Any], to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)

        // One backup, taken before the first edit and never overwritten, so a
        // later toggle cannot clobber the user's original.
        let backup = url.appendingPathExtension("agentisland-backup")
        if FileManager.default.fileExists(atPath: url.path),
           !FileManager.default.fileExists(atPath: backup.path) {
            try? FileManager.default.copyItem(at: url, to: backup)
        }

        guard let data = try? JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else {
            throw InstallError.writeFailed(url.lastPathComponent)
        }

        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw InstallError.writeFailed(url.lastPathComponent)
        }
    }
}
