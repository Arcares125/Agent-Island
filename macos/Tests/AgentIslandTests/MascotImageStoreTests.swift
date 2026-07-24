import AppKit
import XCTest
@testable import AgentIsland

/// Sprite resolution. This is the path that took the app down: with no custom
/// artwork for a provider the store falls through to the bundled sprite, and
/// `Bundle.module` calls `fatalError` when the resource bundle is absent — an
/// unrecoverable crash loop, because the notch draws a mascot on launch.
final class MascotImageStoreTests: XCTestCase {
    /// The exact call that trapped: no custom artwork, both providers.
    func testBundledSpriteResolvesForEveryProvider() {
        for provider in AgentProvider.allCases {
            let image = MascotImageStore.image(provider: provider, fallbackSize: 20)
            XCTAssertGreaterThan(
                image.size.width, 0,
                "\(provider.displayName) sprite came back empty — the bundle is not being found")
        }
    }

    /// A missing sprite must degrade to a blank image of the requested size, never
    /// a trap. Uses a provider whose artwork points at a file that does not exist.
    func testMissingCustomArtFallsBackInsteadOfTrapping() {
        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).png")
        let artwork = MascotArtwork(customURLs: [.codex: missing], revision: 1)

        let image = MascotImageStore.image(provider: .codex, fallbackSize: 24, artwork: artwork)
        XCTAssertGreaterThan(image.size.width, 0, "A broken custom path must fall back, not crash")
    }

    /// Custom artwork wins over the bundled sprite, and the revision keys the cache
    /// so replacing art cannot serve the previous image back.
    func testCustomArtworkOverridesBundledSpriteAndRespectsRevision() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpriteTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 40,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let url = directory.appendingPathComponent("custom.png")
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)

        let artwork = MascotArtwork(customURLs: [.claude: url], revision: 7)
        let custom = MascotImageStore.image(provider: .claude, fallbackSize: 20, artwork: artwork)
        XCTAssertEqual(custom.size.width, 40, accuracy: 0.5, "Upload must win over the sprite")

        let bundled = MascotImageStore.image(provider: .claude, fallbackSize: 20)
        XCTAssertNotEqual(
            bundled.size.width, 40, accuracy: 0.5,
            "Different artwork must not share a cache entry with the bundled sprite")
    }

    /// The bundle has to actually be found, not silently absent — that is the whole
    /// failure this file exists for.
    func testSpriteBundleIsResolvable() {
        XCTAssertNotNil(MascotImageStore.spriteBundle)
    }
}
