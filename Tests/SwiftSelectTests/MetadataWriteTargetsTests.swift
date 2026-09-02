import XCTest

@testable import SwiftSelectCore

/// A clip must never reach a metadata write. Proven rather than assumed because both write paths
/// fail quietly rather than loudly: exiftool reports "1 image files updated" for a `.MOV` it only
/// half-wrote, and a stray `.xmp` beside a clip is invisible until it is left behind at import.
final class MetadataWriteTargetsTests: XCTestCase {
    func testClipsAreDroppedAndStillsKeepTheirOrder() {
        let assets = [asset("P1010001.ORF"), asset("DSCF0277.MOV"), asset("P1010002.JPG")]

        let writable = MetadataWriteFieldRules.writableTargets(assets)

        XCTAssertEqual(writable.map { $0.url.lastPathComponent }, ["P1010001.ORF", "P1010002.JPG"])
    }

    /// The mixed multi-selection the user actually hits: one clip sorted in among the stills. Driven
    /// off `videoExtensions` rather than a list written out here, so adding a format to the loader
    /// can't quietly leave that format writable.
    func testEveryVideoExtensionIsDropped() {
        for pathExtension in PhotoAssetLoader.videoExtensions.flatMap({ [$0, $0.uppercased()] }) {
            let assets = [asset("P1010001.ORF"), asset("clip.\(pathExtension)")]

            XCTAssertEqual(
                MetadataWriteFieldRules.writableTargets(assets).map { $0.url.lastPathComponent },
                ["P1010001.ORF"], "clip.\(pathExtension) survived the filter")
        }
    }

    /// A video-only capture set yields nothing, which every caller already reads as "no write".
    func testAVideoOnlySetLeavesNothingToWrite() {
        XCTAssertTrue(MetadataWriteFieldRules.writableTargets([asset("DSCF0277.MOV")]).isEmpty)
    }

    func testAnAllStillsSelectionIsUntouched() {
        let assets = [asset("P1010001.ORF"), asset("P1010001.JPG")]

        XCTAssertEqual(MetadataWriteFieldRules.writableTargets(assets).count, assets.count)
    }

    private func asset(_ fileName: String) -> PhotoAsset {
        PhotoAsset(id: URL(fileURLWithPath: "/card/\(fileName)"))
    }
}
