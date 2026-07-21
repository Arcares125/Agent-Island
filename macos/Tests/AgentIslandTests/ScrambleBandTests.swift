import XCTest
@testable import AgentIsland

final class ScrambleBandTests: XCTestCase {

    func testBandIsClearOfTheGlyphBeforeAndAfterThePass() {
        XCTAssertTrue(
            scrambleBandRange(progress: 0, sliceCount: 8, bandSlices: 2).isEmpty,
            "The digit must be clean before the band arrives")
        XCTAssertTrue(
            scrambleBandRange(progress: 1, sliceCount: 8, bandSlices: 2).isEmpty,
            "The digit must be clean once the band has passed")
    }

    func testBandTravelsDownwardAsProgressAdvances() {
        let early = scrambleBandRange(progress: 0.3, sliceCount: 8, bandSlices: 2)
        let late = scrambleBandRange(progress: 0.7, sliceCount: 8, bandSlices: 2)

        XCTAssertFalse(early.isEmpty)
        XCTAssertFalse(late.isEmpty)
        XCTAssertLessThan(early.lowerBound, late.lowerBound, "The band must move top to bottom")
    }

    func testBandNeverExceedsItsConfiguredWidth() {
        for step in 0...40 {
            let range = scrambleBandRange(
                progress: Double(step) / 40, sliceCount: 8, bandSlices: 2)
            XCTAssertLessThanOrEqual(range.count, 2)
        }
    }

    func testBandStaysInsideTheGlyphBounds() {
        for step in 0...40 {
            let range = scrambleBandRange(
                progress: Double(step) / 40, sliceCount: 8, bandSlices: 3)
            XCTAssertGreaterThanOrEqual(range.lowerBound, 0)
            XCTAssertLessThanOrEqual(range.upperBound, 8)
        }
    }

    func testEverySliceGetsCrossedAtSomePoint() {
        var covered = Set<Int>()
        for step in 0...200 {
            covered.formUnion(
                scrambleBandRange(progress: Double(step) / 200, sliceCount: 8, bandSlices: 2))
        }
        XCTAssertEqual(covered, Set(0..<8), "A slice the band skips would never animate")
    }

    func testProgressOutsideZeroToOneIsClamped() {
        XCTAssertTrue(scrambleBandRange(progress: -5, sliceCount: 8, bandSlices: 2).isEmpty)
        XCTAssertTrue(scrambleBandRange(progress: 12, sliceCount: 8, bandSlices: 2).isEmpty)
    }

    func testDegenerateGeometryProducesNoBand() {
        XCTAssertTrue(scrambleBandRange(progress: 0.5, sliceCount: 0, bandSlices: 2).isEmpty)
        XCTAssertTrue(scrambleBandRange(progress: 0.5, sliceCount: 8, bandSlices: 0).isEmpty)
        XCTAssertTrue(scrambleBandRange(progress: 0.5, sliceCount: -3, bandSlices: 2).isEmpty)
    }

    func testScrambleCharacterIsStableForTheSameSeed() {
        XCTAssertEqual(scrambleCharacter(seed: 4321), scrambleCharacter(seed: 4321))
    }

    func testScrambleCharacterVariesAcrossSeeds() {
        let sampled = Set((0..<64).map { scrambleCharacter(seed: $0) })
        XCTAssertGreaterThan(sampled.count, 6, "Junk that barely varies reads as a static glyph")
    }

    func testScrambleCharacterAlwaysComesFromTheAlphabet() {
        let allowed = Set(scrambleAlphabet)
        for seed in stride(from: -5000, through: 5000, by: 97) {
            XCTAssertTrue(allowed.contains(scrambleCharacter(seed: seed)))
        }
    }

    func testAlphabetContainsNoLetters() {
        XCTAssertFalse(
            scrambleAlphabet.contains { $0.isLetter },
            "Letters make the eye try to complete a word instead of reading noise")
    }
}
