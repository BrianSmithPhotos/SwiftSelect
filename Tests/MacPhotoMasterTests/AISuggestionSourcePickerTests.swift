import XCTest

@testable import MacPhotoMaster
@testable import MacPhotoMasterCore

final class AISuggestionSourcePickerTests: XCTestCase {
    func testPrefersRAWOverJPEG() {
        let raw = PhotoAsset(id: URL(fileURLWithPath: "/card/P1010042.ORF"))
        let jpeg = PhotoAsset(id: URL(fileURLWithPath: "/card/P1010042.JPG"))

        let picked = AISuggestionSourcePicker.pickSourceAsset(from: [jpeg, raw])

        XCTAssertEqual(picked?.url, raw.url)
    }

    func testFallsBackToFirstJPEGByFilenameWhenNoRAWPresent() {
        let jpegB = PhotoAsset(id: URL(fileURLWithPath: "/card/B.jpg"))
        let jpegA = PhotoAsset(id: URL(fileURLWithPath: "/card/A.jpg"))

        let picked = AISuggestionSourcePicker.pickSourceAsset(from: [jpegB, jpegA])

        XCTAssertEqual(picked?.url, jpegA.url)
    }

    func testEmptyMembersReturnsNil() {
        XCTAssertNil(AISuggestionSourcePicker.pickSourceAsset(from: []))
    }

    /// A clip is a non-JPEG, so the RAW-first rule above would otherwise hand it to a vision model.
    func testNeverPicksAVideoOverTheStillBesideIt() {
        let clip = PhotoAsset(id: URL(fileURLWithPath: "/card/A1076833.MOV"))
        let jpeg = PhotoAsset(id: URL(fileURLWithPath: "/card/P1010042.JPG"))

        XCTAssertEqual(AISuggestionSourcePicker.pickSourceAsset(from: [clip, jpeg])?.url, jpeg.url)
    }

    func testASetOfOnlyVideoHasNothingToSend() {
        let clip = PhotoAsset(id: URL(fileURLWithPath: "/card/H1076833.MOV"))

        XCTAssertNil(AISuggestionSourcePicker.pickSourceAsset(from: [clip]))
    }
}
