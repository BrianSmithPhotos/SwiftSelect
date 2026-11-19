import XCTest

@testable import SwiftSelectCore

final class MetadataSaveOutcomeTests: XCTestCase {
    func testFullSaveIsWritten() {
        XCTAssertNoThrow(try MetadataSaveOutcome.saved(fileCount: 10, failureCount: 0).requireWritten())
    }

    /// The 2026-11-18 loss: a save already running made every batch write return early.
    func testBusyIsNotWritten() {
        XCTAssertThrowsError(try MetadataSaveOutcome.busy.requireWritten()) { error in
            XCTAssertEqual(error as? MetadataSaveError, .busy)
        }
    }

    func testNothingToSaveIsNotWritten() {
        XCTAssertThrowsError(try MetadataSaveOutcome.nothingToSave.requireWritten()) { error in
            XCTAssertEqual(error as? MetadataSaveError, .nothingWritten)
        }
    }

    func testPartialSaveIsNotWritten() {
        XCTAssertThrowsError(
            try MetadataSaveOutcome.saved(fileCount: 10, failureCount: 3).requireWritten()
        ) { error in
            XCTAssertEqual(error as? MetadataSaveError, .partial(failed: 3, of: 10))
        }
    }

    func testBusyMessageNamesTheCause() {
        XCTAssertEqual(
            MetadataSaveError.busy.localizedDescription, "not saved - another save was still running")
    }
}
