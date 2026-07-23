import XCTest
@testable import AgentIsland

final class PixelGlyphTests: XCTestCase {

    private let allGlyphs: [(String, [String])] = [
        ("question", PixelGlyphs.question),
        ("check", PixelGlyphs.check),
        ("sleep", PixelGlyphs.sleep),
        ("ellipsis", PixelGlyphs.ellipsis),
        ("note", PixelGlyphs.note),
        ("spark", PixelGlyphs.spark),
    ]

    /// A ragged bitmap silently draws a torn glyph rather than failing, so the
    /// shape is checked instead of the rendering.
    func testEveryGlyphIsRectangular() {
        for (name, rows) in allGlyphs {
            XCTAssertTrue(
                PixelGlyphs.isWellFormed(rows),
                "\(name) is ragged or uses symbols the renderer ignores")
        }
    }

    func testEveryGlyphHasLitCells() {
        for (name, rows) in allGlyphs {
            XCTAssertTrue(
                rows.contains { $0.contains("#") },
                "\(name) would draw nothing at all")
        }
    }

    func testMalformedBitmapsAreRejected() {
        XCTAssertFalse(PixelGlyphs.isWellFormed([]), "An empty bitmap is not drawable")
        XCTAssertFalse(PixelGlyphs.isWellFormed(["###", "##"]), "Rows must be equal width")
        XCTAssertFalse(PixelGlyphs.isWellFormed(["#x#"]), "Only # and . are understood")
        XCTAssertFalse(PixelGlyphs.isWellFormed([""]), "A zero-width bitmap is not drawable")
    }

    func testQuestionMarkReadsAsAQuestionMark() {
        let rows = PixelGlyphs.question
        XCTAssertEqual(rows.count, 7)
        XCTAssertTrue(
            rows[5].allSatisfy { $0 == "." },
            "The gap above the dot is what separates a ? from a hook shape")
        XCTAssertTrue(rows[6].contains("#"), "A ? needs its dot")
    }

    // MARK: - Cell sizing

    /// Fractional cells are exactly what turns pixel art back into a smudge.
    func testCellSizeIsAWholeNumberOfPoints() {
        for mascot in stride(from: 12.0, through: 48.0, by: 1.0) {
            let cell = pixelCellSize(mascotSize: mascot, rowCount: 7)
            XCTAssertEqual(cell, cell.rounded(), accuracy: 0.0001,
                           "cell \(cell) at mascot size \(mascot) is not whole")
        }
    }

    func testCellSizeNeverCollapsesToNothing() {
        XCTAssertGreaterThanOrEqual(pixelCellSize(mascotSize: 1, rowCount: 7), 1)
        XCTAssertGreaterThanOrEqual(pixelCellSize(mascotSize: 0, rowCount: 7), 1)
    }

    func testCellSizeSurvivesADegenerateBitmap() {
        XCTAssertGreaterThanOrEqual(pixelCellSize(mascotSize: 24, rowCount: 0), 1)
    }

    func testBadgeGrowsWithTheMascot() {
        let small = pixelCellSize(mascotSize: 16, rowCount: 7)
        let large = pixelCellSize(mascotSize: 40, rowCount: 7)
        XCTAssertGreaterThan(large, small, "The badge must scale with the sprite it sits on")
    }

    // MARK: - Sprite grids

    func testEachProviderDeclaresAPixelGrid() {
        for provider in AgentProvider.allCases {
            XCTAssertGreaterThan(provider.pixelCells, 0)
        }
    }

    /// Claude's artwork is a 16-cell sprite; resampling off a multiple keeps its
    /// cells aligned instead of introducing half-pixel seams.
    func testClaudeGridIsAMultipleOfItsNativeSpriteGrid() {
        XCTAssertEqual(AgentProvider.claude.pixelCells % 16, 0)
    }
}
