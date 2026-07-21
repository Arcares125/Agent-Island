import Foundation

enum ClaudeMetricsBridgeError: LocalizedError {
    case helperMissing
    case invalidSettings
    case existingStatusLine

    var errorDescription: String? {
        switch self {
        case .helperMissing:
            return "The signed Agent Island helper is missing from the app bundle."
        case .invalidSettings:
            return "Claude's settings.json is not valid JSON, so Agent Island left it unchanged."
        case .existingStatusLine:
            return "Claude already has a custom status line. Agent Island will not overwrite it."
        }
    }
}

enum ClaudeMetricsBridge {
    private static let bridgeArgument = "--ingest-claude-status"

    static var isInstalled: Bool {
        guard let settings = try? readSettings(),
              let statusLine = settings["statusLine"] as? [String: Any],
              let command = statusLine["command"] as? String else { return false }
        return command.contains(bridgeArgument)
    }

    static func install() throws {
        var settings = try readSettings()
        if let statusLine = settings["statusLine"] as? [String: Any],
           let command = statusLine["command"] as? String,
           !command.contains(bridgeArgument) {
            throw ClaudeMetricsBridgeError.existingStatusLine
        }

        let fileManager = FileManager.default
        let source = Bundle.main.bundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("Helpers")
            .appendingPathComponent("agent-core")
        guard fileManager.isExecutableFile(atPath: source.path) else {
            throw ClaudeMetricsBridgeError.helperMissing
        }

        let destination = installedHelperURL
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent("agent-core-install-\(UUID().uuidString)")
        try fileManager.copyItem(at: source, to: temporary)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }

        settings["statusLine"] = [
            "type": "command",
            "command": "\(shellQuoted(destination.path)) \(bridgeArgument)",
            "padding": 2
        ]
        try writeSettings(settings)
    }

    static func disable() throws {
        var settings = try readSettings()
        guard let statusLine = settings["statusLine"] as? [String: Any],
              let command = statusLine["command"] as? String,
              command.contains(bridgeArgument) else { return }
        settings.removeValue(forKey: "statusLine")
        try writeSettings(settings)
    }

    private static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .appendingPathComponent("settings.json")
    }

    private static var installedHelperURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("Agent Island")
            .appendingPathComponent("agent-core")
    }

    private static func readSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        let data = try Data(contentsOf: settingsURL)
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let settings = object as? [String: Any] else {
            throw ClaudeMetricsBridgeError.invalidSettings
        }
        return settings
    }

    private static func writeSettings(_ settings: [String: Any]) throws {
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: settingsURL, options: [.atomic])
    }

    private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
