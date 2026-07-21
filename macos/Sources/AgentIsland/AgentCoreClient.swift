import Foundation

final class AgentCoreClient {
    private var process: Process?
    private var outputBuffer = Data()
    private let readQueue = DispatchQueue(label: "com.agentisland.core-output")

    func start(model: IslandModel) {
        guard process == nil, let executableURL = locateExecutable() else { return }

        let process = Process()
        let output = Pipe()
        process.executableURL = executableURL
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        output.fileHandleForReading.readabilityHandler = { [weak self, weak model] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.readQueue.async {
                self?.consume(data, model: model)
            }
        }

        process.terminationHandler = { [weak self] _ in
            output.fileHandleForReading.readabilityHandler = nil
            self?.process = nil
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
    }

    private func consume(_ data: Data, model: IslandModel?) {
        outputBuffer.append(data)

        // The sidecar is trusted, but keep malformed output from growing memory forever.
        if outputBuffer.count > 65_536 {
            outputBuffer.removeAll(keepingCapacity: true)
            return
        }

        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer.prefix(upTo: newline)
            outputBuffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let snapshot = try? JSONDecoder().decode(AgentSnapshot.self, from: Data(line)) else {
                continue
            }

            DispatchQueue.main.async {
                model?.apply(snapshot)
            }
        }
    }

    private func locateExecutable() -> URL? {
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
