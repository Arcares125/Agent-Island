import Foundation
import XCTest
@testable import AgentIsland

final class ShelfFormattingTests: XCTestCase {
    func testSizeLabelUsesBytesBelowOneKilobyte() {
        XCTAssertEqual(shelfSizeLabel(0), "0 B")
        XCTAssertEqual(shelfSizeLabel(946), "946 B")
        XCTAssertEqual(shelfSizeLabel(1023), "1023 B")
    }

    func testSizeLabelStepsThroughUnits() {
        XCTAssertEqual(shelfSizeLabel(1024), "1.0 KB")
        XCTAssertEqual(shelfSizeLabel(12_697), "12.4 KB")
        XCTAssertEqual(shelfSizeLabel(2_306_867), "2.2 MB")
        XCTAssertEqual(shelfSizeLabel(2_255_053_390), "2.1 GB")
    }

    func testSizeLabelDropsFractionOnceItStopsInforming() {
        XCTAssertEqual(shelfSizeLabel(851_443), "831 KB")
    }

    func testSizeLabelTreatsNegativeAsEmpty() {
        XCTAssertEqual(shelfSizeLabel(-42), "0 B")
    }

    func testTypeLabelUppercasesExtension() {
        XCTAssertEqual(shelfTypeLabel(for: URL(fileURLWithPath: "/tmp/report.pdf")), "PDF")
        XCTAssertEqual(shelfTypeLabel(for: URL(fileURLWithPath: "/tmp/Shot.PNG")), "PNG")
    }

    func testTypeLabelFallsBackWhenThereIsNoExtension() {
        XCTAssertEqual(shelfTypeLabel(for: URL(fileURLWithPath: "/tmp/Makefile")), "FILE")
    }

    func testTypeLabelTruncatesLongExtensions() {
        XCTAssertEqual(shelfTypeLabel(for: URL(fileURLWithPath: "/tmp/a.sketchfile")), "SKETC")
    }
}
