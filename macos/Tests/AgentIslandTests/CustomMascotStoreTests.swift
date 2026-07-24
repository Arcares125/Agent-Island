import AppKit
import Foundation
import XCTest
@testable import AgentIsland

/// Uploaded mascot art: one image per provider, bundled sprites otherwise.
final class CustomMascotStoreTests: XCTestCase {
    @MainActor
    private func makeStore() -> CustomMascotStore {
        CustomMascotStore(rootDirectory: makeScratchDirectory())
    }

    private func makeScratchDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MascotTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// A real, decodable PNG on disk.
    private func writePNG(
        named name: String = "art.png",
        size: NSSize = NSSize(width: 24, height: 24)
    ) throws -> URL {
        let directory = makeScratchDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    @MainActor
    func testStartsWithNoCustomArt() {
        let store = makeStore()
        for provider in AgentProvider.allCases {
            XCTAssertFalse(store.hasCustomImage(for: provider))
            XCTAssertNil(store.customImageURL(for: provider))
        }
    }

    @MainActor
    func testImportingArtAppliesToOnlyThatProvider() throws {
        let store = makeStore()
        let source = try writePNG()

        XCTAssertTrue(store.importImage(from: source, for: .claude))
        XCTAssertTrue(store.hasCustomImage(for: .claude))
        XCTAssertFalse(
            store.hasCustomImage(for: .codex),
            "Each agent keeps its own art — one upload must not cover both")
    }

    /// Replacing art has to invalidate the sprite cache, or the old image keeps
    /// being served.
    @MainActor
    func testImportBumpsRevision() throws {
        let store = makeStore()
        let before = store.revision
        XCTAssertTrue(store.importImage(from: try writePNG(), for: .codex))
        XCTAssertNotEqual(store.revision, before)
    }

    @MainActor
    func testResetRestoresTheBundledSprite() throws {
        let store = makeStore()
        XCTAssertTrue(store.importImage(from: try writePNG(), for: .codex))

        store.reset(.codex)
        XCTAssertFalse(store.hasCustomImage(for: .codex))
        XCTAssertNil(store.customImageURL(for: .codex))
    }

    @MainActor
    func testUploadSurvivesRelaunch() throws {
        let directory = makeScratchDirectory()
        let store = CustomMascotStore(rootDirectory: directory)
        XCTAssertTrue(store.importImage(from: try writePNG(), for: .claude))

        let relaunched = CustomMascotStore(rootDirectory: directory)
        XCTAssertTrue(relaunched.hasCustomImage(for: .claude))
        XCTAssertFalse(relaunched.hasCustomImage(for: .codex))
    }

    /// Regression: the notch kept drawing bundled sprites after an upload because
    /// the header's view tree never received the artwork. The model-side snapshot
    /// every tree reads from must reflect the store.
    @MainActor
    func testModelArtworkSnapshotReflectsUploads() throws {
        let suite = "MascotArtworkTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        // A scratch store, so this never reads or writes the real uploads.
        let model = IslandModel(defaults: defaults, customMascots: makeStore())

        XCTAssertTrue(model.mascotArtwork.customURLs.isEmpty)
        let baseline = model.mascotArtwork.revision

        XCTAssertTrue(model.customMascots.importImage(from: try writePNG(), for: .claude))
        XCTAssertNotNil(
            model.mascotArtwork.customURL(for: .claude),
            "Every mascot view reads this snapshot — an upload must land in it")
        XCTAssertNil(model.mascotArtwork.customURL(for: .codex))
        XCTAssertNotEqual(
            model.mascotArtwork.revision, baseline,
            "The revision keys the sprite cache; without a bump the old art is served")
    }

    // MARK: Storage size

    /// Regression: uploads were stored at source resolution, so a 4800×3600 photo
    /// cost ~66 MB of decoded bitmap to draw a 20pt icon (measured 19.3 → 88.1 MB).
    @MainActor
    func testOversizedUploadIsDownscaledOnImport() throws {
        let store = makeStore()
        let source = try writePNG(named: "huge.png", size: NSSize(width: 4800, height: 3600))

        XCTAssertTrue(store.importImage(from: source, for: .codex))
        let stored = try XCTUnwrap(store.customImageURL(for: .codex))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: stored)))

        XCTAssertLessThanOrEqual(
            max(rep.pixelsWide, rep.pixelsHigh),
            CustomMascotStore.maximumStoredEdge,
            "A megapixel upload must not reach the sprite cache at source size")
        XCTAssertEqual(
            Double(rep.pixelsWide) / Double(rep.pixelsHigh),
            4800.0 / 3600.0,
            accuracy: 0.02,
            "Downscaling must preserve aspect ratio")
    }

    /// Artwork saved before the limit existed must be brought down on next launch,
    /// otherwise the fix only helps people who upload again.
    @MainActor
    func testExistingOversizedArtIsShrunkOnLaunch() throws {
        let directory = makeScratchDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Write an oversized file straight into place, as the old build would have.
        let legacy = try writePNG(named: "legacy.png", size: NSSize(width: 2400, height: 1800))
        try FileManager.default.copyItem(
            at: legacy, to: directory.appendingPathComponent("codex.png"))

        let store = CustomMascotStore(rootDirectory: directory)
        let stored = try XCTUnwrap(store.customImageURL(for: .codex))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: stored)))

        XCTAssertLessThanOrEqual(
            max(rep.pixelsWide, rep.pixelsHigh),
            CustomMascotStore.maximumStoredEdge,
            "Art already on disk must be migrated, not left at source size")
    }

    /// Art that already fits is left exactly as drawn — no resampling, no blur.
    @MainActor
    func testSmallSpriteIsNotResampled() throws {
        let store = makeStore()
        let source = try writePNG(named: "sprite.png", size: NSSize(width: 32, height: 48))

        XCTAssertTrue(store.importImage(from: source, for: .claude))
        let stored = try XCTUnwrap(store.customImageURL(for: .claude))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: stored)))

        XCTAssertEqual(rep.pixelsWide, 32)
        XCTAssertEqual(rep.pixelsHigh, 48)
    }

    /// Downscaling must not flatten the alpha channel — that would reintroduce the
    /// solid-backdrop problem for every large transparent PNG.
    @MainActor
    func testDownscalingPreservesTransparency() throws {
        let store = makeStore()
        // writePNG leaves the bitmap fully transparent.
        let source = try writePNG(named: "big-clear.png", size: NSSize(width: 2000, height: 2000))

        XCTAssertTrue(store.importImage(from: source, for: .codex))
        let message = try XCTUnwrap(store.statusMessage)
        XCTAssertFalse(
            message.contains("NO TRANSPARENCY"),
            "Alpha survived at source size but not after resampling — got \(message)")
    }

    // MARK: Rejected input

    /// A `.png` extension proves nothing — the bytes have to decode.
    @MainActor
    func testRejectsNonImageDisguisedAsPNG() throws {
        let store = makeStore()
        let directory = makeScratchDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fake = directory.appendingPathComponent("not-really.png")
        try Data("this is not an image".utf8).write(to: fake)

        XCTAssertFalse(store.importImage(from: fake, for: .codex))
        XCTAssertFalse(store.hasCustomImage(for: .codex))
        XCTAssertNotNil(store.statusMessage)
    }

    /// JPEG and BMP cannot carry alpha at all, so a mascot in either would always
    /// arrive as a solid rectangle. They must not even be offered.
    @MainActor
    func testAlphaIncapableFormatsAreNotAllowed() {
        XCTAssertFalse(CustomMascotStore.allowedContentTypes.contains(.jpeg))
        XCTAssertFalse(CustomMascotStore.allowedContentTypes.contains(.bmp))
        XCTAssertTrue(CustomMascotStore.allowedContentTypes.contains(.png))
    }

    @MainActor
    func testRejectsJPEGEvenWhenHandedDirectlyToTheStore() throws {
        let store = makeStore()
        let directory = makeScratchDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let data = try XCTUnwrap(rep.representation(using: .jpeg, properties: [:]))
        let url = directory.appendingPathComponent("photo.jpg")
        try data.write(to: url)

        XCTAssertFalse(
            store.importImage(from: url, for: .codex),
            "The panel filters JPEG out, and the store must refuse it too")
        XCTAssertFalse(store.hasCustomImage(for: .codex))
    }

    /// A PNG can still be flattened. That is allowed — but the user is told, since
    /// it is the difference between a mascot and a mascot in a box.
    @MainActor
    func testFlattenedPNGIsAcceptedWithAWarning() throws {
        let store = makeStore()
        let directory = makeScratchDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        // Paint every pixel fully opaque.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.red.setFill()
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: 16, height: 16))
        NSGraphicsContext.restoreGraphicsState()

        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let url = directory.appendingPathComponent("flat.png")
        try data.write(to: url)

        XCTAssertTrue(store.importImage(from: url, for: .claude))
        XCTAssertTrue(store.hasCustomImage(for: .claude))
        let message = try XCTUnwrap(store.statusMessage)
        XCTAssertTrue(
            message.contains("NO TRANSPARENCY"),
            "An opaque upload must say so — got \(message)")
    }

    @MainActor
    func testRejectsDisallowedFileType() throws {
        let store = makeStore()
        let directory = makeScratchDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let text = directory.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: text)

        XCTAssertFalse(store.importImage(from: text, for: .codex))
        XCTAssertFalse(store.hasCustomImage(for: .codex))
    }

    @MainActor
    func testRejectsMissingFile() {
        let store = makeStore()
        let missing = makeScratchDirectory().appendingPathComponent("gone.png")

        XCTAssertFalse(store.importImage(from: missing, for: .claude))
        XCTAssertFalse(store.hasCustomImage(for: .claude))
    }

    @MainActor
    func testResettingUntouchedProviderIsHarmless() {
        let store = makeStore()
        store.reset(.codex)
        XCTAssertFalse(store.hasCustomImage(for: .codex))
    }
}
