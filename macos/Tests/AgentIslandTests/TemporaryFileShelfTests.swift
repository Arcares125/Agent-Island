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

    // MARK: Retention

    @MainActor
    func testRetentionDefaultsToOneHourAndDrivesLifetime() {
        let store = TemporaryFileShelf(rootDirectory: makeShelfDirectory())
        defer { store.shutdown() }

        XCTAssertEqual(store.retentionHours, 1)
        XCTAssertEqual(store.lifetime, 3600, accuracy: 0.001)
        XCTAssertTrue(store.statusMessage.contains("1 HOUR"))
    }

    @MainActor
    func testRetentionExtendsToTwentyFourHours() {
        let store = TemporaryFileShelf(rootDirectory: makeShelfDirectory(), retentionHours: 24)
        defer { store.shutdown() }

        XCTAssertEqual(store.retentionHours, 24)
        XCTAssertEqual(store.lifetime, 24 * 3600, accuracy: 0.001)
        XCTAssertTrue(store.statusMessage.contains("24 HOURS"))
    }

    /// The value round-trips through UserDefaults, where a user can hand-edit it.
    @MainActor
    func testUnknownRetentionFallsBackToDefault() {
        XCTAssertEqual(TemporaryFileShelf.clampRetentionHours(7), 1)
        XCTAssertEqual(TemporaryFileShelf.clampRetentionHours(-3), 1)
        XCTAssertEqual(TemporaryFileShelf.clampRetentionHours(100_000), 1)
        XCTAssertEqual(TemporaryFileShelf.clampRetentionHours(24), 24)
    }

    /// A longer window must keep a copy that the previous window would have swept.
    @MainActor
    func testLengtheningRetentionKeepsAnAgingCopy() async throws {
        let fileManager = FileManager.default
        let shelfDirectory = makeShelfDirectory()
        let store = TemporaryFileShelf(rootDirectory: shelfDirectory, retentionHours: 24)
        defer { store.shutdown() }

        let containerURL = shelfDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: containerURL, withIntermediateDirectories: true)
        try Data("aged".utf8).write(to: containerURL.appendingPathComponent("aged.txt"))
        // Three hours old: past a 1-hour window, well inside a 24-hour one.
        try fileManager.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3 * 3600)],
            ofItemAtPath: containerURL.path
        )

        store.setRetentionHours(12)
        XCTAssertEqual(store.items.count, 1, "A 3-hour-old copy survives a 12-hour window")

        store.setRetentionHours(1)
        XCTAssertTrue(store.items.isEmpty, "…and is swept once the window drops below its age")
        XCTAssertFalse(fileManager.fileExists(atPath: containerURL.path))
    }

    @MainActor
    private func makeShelfDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentIslandTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("shelf", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
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
