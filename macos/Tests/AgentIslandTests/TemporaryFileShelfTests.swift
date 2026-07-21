import AppKit
import Foundation
import XCTest
@testable import AgentIsland

final class TemporaryFileShelfTests: XCTestCase {
    @MainActor
    func testCompactIslandContainerRegistersFinderFileURLDrops() {
        let container = IslandContainerView(frame: .zero)
        container.install(bodyView: NSView(), headerView: NSView())

        XCTAssertTrue(container.registeredDraggedTypes.contains(.fileURL))
    }

    @MainActor
    func testFinderFileProviderCopiesAndRemovesOnlyTemporaryFile() async throws {
        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("AgentIslandTests-\(UUID().uuidString)", isDirectory: true)
        let sourceDirectory = testRoot.appendingPathComponent("source", isDirectory: true)
        let shelfDirectory = testRoot.appendingPathComponent("shelf", isDirectory: true)
        try fileManager.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: testRoot) }

        let sourceURL = sourceDirectory.appendingPathComponent("drop-test.txt")
        let expectedData = Data("Agent Island file shelf integration test".utf8)
        try expectedData.write(to: sourceURL)

        let store = TemporaryFileShelf(rootDirectory: shelfDirectory)
        defer { store.shutdown() }
        let provider = try XCTUnwrap(NSItemProvider(contentsOf: sourceURL))

        XCTAssertTrue(store.accept([provider]))
        try await waitUntil { store.items.count == 1 }

        let copiedItem = try XCTUnwrap(store.items.first)
        XCTAssertEqual(try Data(contentsOf: copiedItem.url), expectedData)
        XCTAssertTrue(fileManager.fileExists(atPath: sourceURL.path))

        let copiedURL = copiedItem.url
        store.remove(copiedItem)
        try await waitUntil {
            !fileManager.fileExists(atPath: copiedURL.path)
        }

        XCTAssertTrue(fileManager.fileExists(atPath: sourceURL.path))
        XCTAssertEqual(try Data(contentsOf: sourceURL), expectedData)
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 3,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for temporary file shelf operation")
    }
}
