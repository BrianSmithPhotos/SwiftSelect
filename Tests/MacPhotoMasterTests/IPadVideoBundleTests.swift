import XCTest

@testable import MacPhotoMaster
@testable import MacPhotoMasterCore

/// The iPad writes the batch label into a folder name and the Mac reads it back out; these two
/// halves are only ever exercised together on a real device, so the round trip is pinned here.
final class IPadVideoBundleTests: XCTestCase {
    private let libraryRoot = URL(fileURLWithPath: "/Documents/ProcessedLibrary")

    func testStagingDirectoryCarriesTheBatchUnderTheVideosFolder() {
        let directory = IPadVideoBundle.stagingDirectory(libraryRoot: libraryRoot, batch: "Skomer")

        XCTAssertEqual(directory.path, "/Documents/ProcessedLibrary/Videos/Skomer")
    }

    func testNoBatchStagesStraightUnderTheVideosFolder() {
        let directory = IPadVideoBundle.stagingDirectory(libraryRoot: libraryRoot, batch: "")

        XCTAssertEqual(directory.path, "/Documents/ProcessedLibrary/Videos")
    }

    func testTheLabelSurvivesTheRoundTripThroughTheFolderName() {
        let directory = IPadVideoBundle.stagingDirectory(libraryRoot: libraryRoot, batch: "Skomer")
        let staged = directory.appendingPathComponent("H1076833.MOV")

        XCTAssertEqual(
            IPadVideoBundle.batchLabel(for: staged, exportRoot: libraryRoot), "Skomer")
    }

    func testAClipStagedWithNoBatchReadsBackAsNoBatch() {
        let staged = IPadVideoBundle.stagingDirectory(libraryRoot: libraryRoot, batch: "")
            .appendingPathComponent("H1076833.MOV")

        XCTAssertEqual(IPadVideoBundle.batchLabel(for: staged, exportRoot: libraryRoot), "")
    }

    /// The user may copy just the one batch folder across rather than the whole package, in which
    /// case the export root is the batch folder itself and must not become the label twice over.
    func testAClipSittingDirectlyInTheExportRootHasNoBatch() {
        let exportRoot = URL(fileURLWithPath: "/Pulled/Skomer")

        XCTAssertEqual(
            IPadVideoBundle.batchLabel(
                for: exportRoot.appendingPathComponent("H1076833.MOV"), exportRoot: exportRoot),
            "")
    }

    func testABatchFolderCopiedOnItsOwnStillYieldsItsLabel() {
        let exportRoot = URL(fileURLWithPath: "/Pulled")
        let staged = exportRoot.appendingPathComponent("Skomer/H1076833.MOV")

        XCTAssertEqual(IPadVideoBundle.batchLabel(for: staged, exportRoot: exportRoot), "Skomer")
    }
}
