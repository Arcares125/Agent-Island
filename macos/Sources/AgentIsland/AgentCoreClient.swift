import Foundation

/// The sidecar's stdin, owned by a single serial queue.
///
/// `@unchecked Sendable` is honest here rather than a shrug: `handle` is only
/// ever touched inside `queue`, so the box can cross threads even though a bare
/// `FileHandle` reference could not. Writing off the main thread also means a
/// full pipe can never stall a click in the island.
private final class AnswerChannel: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.agentisland.core-input")
    private var handle: FileHandle?

    func open(_ handle: FileHandle) {
        queue.async { self.handle = handle }
    }

    func close() {
        queue.async { self.handle = nil }
    }

    func send(_ line: String) {
        queue.async {
            // The sidecar can exit between the click and the write.
            guard let handle = self.handle, let data = line.data(using: .utf8) else { return }
            try? handle.write(contentsOf: data)
        }
    }
}

/// Line-buffers the sidecar's stdout and dispatches decoded messages.
///
/// Same justification as `AnswerChannel`: `buffer` is only ever touched inside
/// `queue`, so this box may cross into a `@Sendable` readability handler where a
/// reference to the client itself could not.
private final class SnapshotStream: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.agentisland.core-output")
    private var buffer = Data()

    /// Past this the sidecar is malfunctioning; drop rather than grow forever.
    private static let maxBufferedBytes = 65_536

    func ingest(_ data: Data, model: IslandModel?) {
        queue.async {
            self.buffer.append(data)

            // The sidecar is trusted, but keep malformed output from growing
            // memory without bound.
            if self.buffer.count > Self.maxBufferedBytes {
                self.buffer.removeAll(keepingCapacity: true)
                return
            }

            while let newline = self.buffer.firstIndex(of: 0x0A) {
                let line = self.buffer.prefix(upTo: newline)
                self.buffer.removeSubrange(...newline)
                guard !line.isEmpty else { continue }
                Self.route(Data(line), model: model)
            }
        }
    }

    /// The sidecar multiplexes telemetry and answer traffic over one stream, so
    /// the envelope's `type` decides which decoder to use.
    private static func route(_ line: Data, model: IslandModel?) {
        let decoder = JSONDecoder()
        switch try? decoder.decode(MessageEnvelope.self, from: line).type {
        case "ask":
            guard let ask = try? decoder.decode(AskRequestMessage.self, from: line) else { return }
            DispatchQueue.main.async { model?.presentAsk(ask) }
        case "askResolved":
            guard let resolved = try? decoder.decode(AskResolvedMessage.self, from: line) else { return }
            DispatchQueue.main.async { model?.retireAsk(requestId: resolved.requestId) }
        default:
            guard let snapshot = try? decoder.decode(AgentSnapshot.self, from: line) else { return }
            DispatchQueue.main.async { model?.apply(snapshot) }
        }
    }
}

final class AgentCoreClient {
    private var process: Process?
    private let answers = AnswerChannel()
    private let stream = SnapshotStream()

    /// Main-actor because it installs the model's answer callback; the pipes
    /// themselves are serviced off the main thread.
    @MainActor
    func start(model: IslandModel) {
        guard process == nil, let executableURL = locateExecutable() else { return }

        let process = Process()
        let output = Pipe()
        let input = Pipe()
        process.executableURL = executableURL
        process.standardOutput = output
        process.standardInput = input
        process.standardError = FileHandle.nullDevice
        answers.open(input.fileHandleForWriting)

        // The closure captures the channel, not the client: one-way dependency,
        // and nothing non-Sendable crosses into it.
        let answers = self.answers
        model.answerHandler = { requestId, optionIndex in
            answers.send(Self.answerLine(requestId: requestId, optionIndex: optionIndex))
        }

        // Captures the stream box rather than the client, so nothing non-Sendable
        // crosses into the handler.
        let stream = self.stream
        output.fileHandleForReading.readabilityHandler = { [weak model] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            stream.ingest(data, model: model)
        }

        process.terminationHandler = { [weak self, answers] _ in
            output.fileHandleForReading.readabilityHandler = nil
            self?.process = nil
            answers.close()
        }

        do {
            try process.run()
            self.process = process
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
        }
    }

    func stop() {
        process?.terminate()
        process = nil
        answers.close()
    }

    /// The user's pick, as a line for the sidecar. A nil index releases the agent
    /// back to its own terminal prompt.
    static func answerLine(requestId: String, optionIndex: Int?) -> String {
        let index = optionIndex.map { ",\"optionIndex\":\($0)" } ?? ""
        return "{\"type\":\"answer\",\"requestId\":\"\(escaped(requestId))\"\(index)}\n"
    }

    /// Request ids are generated by the sidecar, but they still cross a JSON
    /// boundary, so they get escaped like any other untrusted string.
    static func escaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .filter { !$0.isNewline }
    }

    private func locateExecutable() -> URL? { AgentCoreBinary.locate() }
}

/// Where the sidecar lives.
///
/// Shared by the client and the hook installer so a hook written into an agent's
/// config always names the same binary the island itself runs.
enum AgentCoreBinary {
    static func locate() -> URL? {
        var candidates: [URL] = []

        if let bundled = Bundle.main.url(forResource: "agent-core", withExtension: nil) {
            candidates.append(bundled)
        }

        candidates.append(
            Bundle.main.bundleURL
                .appendingPathComponent("Contents")
                .appendingPathComponent("Helpers")
                .appendingPathComponent("agent-core")
        )

        // Development fallbacks are intentionally disabled inside a packaged app so an
        // attacker-controlled working directory cannot substitute the bundled sidecar.
        if Bundle.main.bundleURL.pathExtension != "app" {
            let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            candidates.append(root.appendingPathComponent("agent-core/target/release/agent-core"))
            candidates.append(root.appendingPathComponent("agent-core/target/debug/agent-core"))
        }

        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
