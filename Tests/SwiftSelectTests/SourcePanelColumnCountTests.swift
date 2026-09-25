import XCTest

@testable import SwiftSelect

final class SourcePanelColumnCountTests: XCTestCase {
    func testMatchesAdaptiveGridArithmetic() {
        // 96 pt tiles, 8 pt spacing: n columns need n*96 + (n-1)*8 points.
        XCTAssertEqual(SourcePanelView.columnCount(forWidth: 199), 1)
        XCTAssertEqual(SourcePanelView.columnCount(forWidth: 200), 2)
        XCTAssertEqual(SourcePanelView.columnCount(forWidth: 304), 3)
    }

    func testNeverFewerThanOneColumn() {
        XCTAssertEqual(SourcePanelView.columnCount(forWidth: 0), 1)
        XCTAssertEqual(SourcePanelView.columnCount(forWidth: 40), 1)
    }

    func testTileSideFillsTheWidth() {
        XCTAssertEqual(SourcePanelView.tileSide(forWidth: 304, columns: 3), 96)
        XCTAssertEqual(SourcePanelView.tileSide(forWidth: 250, columns: 2), 121)
    }

    func testTileSideNeverBelowMinimum() {
        XCTAssertEqual(SourcePanelView.tileSide(forWidth: 0, columns: 1), 96)
    }
}
