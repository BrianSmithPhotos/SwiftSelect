import XCTest

@testable import SwiftSelect

/// Covers `IPadImportService.filenameArtFilterToken`, the import's rename slot for a JPEG the iPad
/// developed itself. Wrong is silent: the file just lands on the camera JPEG's name with `_1`.
final class IPadImportFilenameTokenTests: XCTestCase {
    func testAnIPadDevelopedJPEGKeepsItsDecoderTokenInTheName() {
        XCTAssertEqual(
            IPadImportService.filenameArtFilterToken(
                keywords: ["heron", "RAW9"], makerNoteToken: ""),
            "RAW9")
    }

    func testACameraFileTakesItsMakerNoteArtFilter() {
        XCTAssertEqual(
            IPadImportService.filenameArtFilterToken(
                keywords: ["heron"], makerNoteToken: "Grainy Film"),
            "Grainy Film")
    }
}
