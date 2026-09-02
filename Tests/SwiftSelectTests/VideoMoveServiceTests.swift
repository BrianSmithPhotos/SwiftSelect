import XCTest

@testable import SwiftSelect
@testable import SwiftSelectCore

final class VideoMoveServiceTests: XCTestCase {
    private let service = VideoMoveService()

    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    /// Arbitrary bytes with a `.MOV` name: this service copies and hashes a file, and never opens it
    /// as a movie, so a real clip would only make the test slower.
    @discardableResult
    private func makeSourceClip(named name: String = "H1076833.MOV", in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("clip-bytes".utf8).write(to: url)
        return url
    }

    func testCopiesIntoTheBatchFolderKeepingTheCameraFilename() async throws {
        let source = try makeTempDirectory()
        let root = try makeTempDirectory()
        let sourceURL = try makeSourceClip(in: source)

        let result = try await service.processAndCopy(
            asset: PhotoAsset(id: sourceURL), batch: "Skomer", destinationRoot: root)

        XCTAssertEqual(
            result.destinationURL,
            root.appendingPathComponent("Skomer").appendingPathComponent("H1076833.MOV"))
        XCTAssertEqual(
            try Data(contentsOf: result.destinationURL), try Data(contentsOf: sourceURL))
    }

    /// Copy, never move: the card is the only copy until the user says otherwise.
    func testLeavesTheSourceInPlace() async throws {
        let source = try makeTempDirectory()
        let root = try makeTempDirectory()
        let sourceURL = try makeSourceClip(in: source)

        _ = try await service.processAndCopy(
            asset: PhotoAsset(id: sourceURL), batch: "Skomer", destinationRoot: root)

        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
    }

    func testNoBatchLabelLandsStraightInTheRoot() async throws {
        let source = try makeTempDirectory()
        let root = try makeTempDirectory()
        let sourceURL = try makeSourceClip(in: source)

        let result = try await service.processAndCopy(
            asset: PhotoAsset(id: sourceURL), batch: "   ", destinationRoot: root)

        XCTAssertEqual(result.destinationURL, root.appendingPathComponent("H1076833.MOV"))
    }

    func testBatchLabelIsSanitizedIntoAFolderName() async throws {
        let source = try makeTempDirectory()
        let root = try makeTempDirectory()
        let sourceURL = try makeSourceClip(in: source)

        let result = try await service.processAndCopy(
            asset: PhotoAsset(id: sourceURL), batch: "Skomer Island/2026", destinationRoot: root)

        XCTAssertEqual(
            result.destinationURL.deletingLastPathComponent().lastPathComponent, "Skomer-Island-2026")
    }

    /// The camera restarts its numbering, so two cards can carry the same filename into one batch.
    func testASecondClipOfTheSameNameIsKeptRatherThanOverwritten() async throws {
        let source = try makeTempDirectory()
        let otherSource = try makeTempDirectory()
        let root = try makeTempDirectory()
        let first = try makeSourceClip(in: source)
        let second = try makeSourceClip(in: otherSource)

        _ = try await service.processAndCopy(
            asset: PhotoAsset(id: first), batch: "Skomer", destinationRoot: root)
        let result = try await service.processAndCopy(
            asset: PhotoAsset(id: second), batch: "Skomer", destinationRoot: root)

        XCTAssertEqual(result.destinationURL.lastPathComponent, "H1076833_1.MOV")
    }

    func testMissingSourceThrowsRatherThanCreatingAnEmptyBatchFolder() async throws {
        let root = try makeTempDirectory()
        let missing = try makeTempDirectory().appendingPathComponent("gone.MOV")

        do {
            _ = try await service.processAndCopy(
                asset: PhotoAsset(id: missing), batch: "Skomer", destinationRoot: root)
            XCTFail("Expected sourceNotFound")
        } catch ProcessMoveError.sourceNotFound {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: root.appendingPathComponent("Skomer").path))
        }
    }

    /// Nothing half-copied may be left where a watching app (or the next run's uniqueness check)
    /// could see it.
    func testLeavesNoStagingFileBehind() async throws {
        let source = try makeTempDirectory()
        let root = try makeTempDirectory()
        let sourceURL = try makeSourceClip(in: source)

        _ = try await service.processAndCopy(
            asset: PhotoAsset(id: sourceURL), batch: "Skomer", destinationRoot: root)

        let contents = try FileManager.default.contentsOfDirectory(
            atPath: root.appendingPathComponent("Skomer").path)
        XCTAssertEqual(contents, ["H1076833.MOV"])
    }
}
