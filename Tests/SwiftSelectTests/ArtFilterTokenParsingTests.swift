import XCTest

@testable import SwiftSelect
@testable import SwiftSelectCore

final class ArtFilterTokenParsingTests: XCTestCase {
    // Fixtures pinned by the Python reference app's test_exif_service.py art-filter-token tests,
    // so the ported Swift output is byte-for-byte comparable.

    func testPrefersActiveArtFilterEffect() {
        let metadata: [String: Any] = ["Olympus:ArtFilterEffect": "Dramatic Tone; Yes; 0"]

        XCTAssertEqual(ArtFilterTokenParsing.token(from: metadata), "Dramatic Tone")
    }

    func testIgnoresOffArtFilterEffect() {
        let metadata: [String: Any] = ["Olympus:ArtFilterEffect": "Off"]

        XCTAssertEqual(ArtFilterTokenParsing.token(from: metadata), "")
    }

    func testFallsBackToPictureModeProfile() {
        let metadata: [String: Any] = ["Olympus:PictureMode": "Color Profile 1"]

        XCTAssertEqual(ArtFilterTokenParsing.token(from: metadata), "Color Profile 1")
    }

    /// Colour Creator is a creative-dial position like the profiles, but its name doesn't contain
    /// "profile" — it produced no filename segment at all before.
    func testFallsBackToPictureModeColorCreator() {
        let metadata: [String: Any] = ["Olympus:PictureMode": "Color Creator; 2"]

        XCTAssertEqual(ArtFilterTokenParsing.token(from: metadata), "Color Creator")
    }

    /// `PictureMode` 17 prints as "Art Mode" but is Colour Profile 4 on the OM-3 — remapped here,
    /// which is safe because a genuine art filter returns from the `ArtFilterEffect` branch first.
    func testArtModeIsRemappedToColorProfile4() {
        let metadata: [String: Any] = ["Olympus:PictureMode": "Art Mode; 2"]

        XCTAssertEqual(ArtFilterTokenParsing.token(from: metadata), "Color Profile 4")
    }

    func testActiveArtFilterStillWinsOverArtModePictureMode() {
        let metadata: [String: Any] = [
            "Olympus:ArtFilterEffect": "Grainy Film; Yes; 0",
            "Olympus:PictureMode": "Art Mode; 2",
        ]

        XCTAssertEqual(ArtFilterTokenParsing.token(from: metadata), "Grainy Film")
    }

    func testPlainPictureModeIsNotAToken() {
        let metadata: [String: Any] = ["Olympus:PictureMode": "Natural; 2"]

        XCTAssertEqual(ArtFilterTokenParsing.token(from: metadata), "")
    }

    func testFallsBackToStackedImageState() {
        let metadata: [String: Any] = ["Olympus:StackedImage": "Live Composite"]

        XCTAssertEqual(ArtFilterTokenParsing.token(from: metadata), "Live Composite")
    }

    func testFallsBackToMultipleExposureMode() {
        let metadata: [String: Any] = ["Olympus:MultipleExposureMode": "On (2 Shots)"]

        XCTAssertEqual(ArtFilterTokenParsing.token(from: metadata), "MultipleExposure")
    }

    func testNoMatchingTagsReturnsEmptyString() {
        XCTAssertEqual(ArtFilterTokenParsing.token(from: [:]), "")
    }

    func testStackedImageNoIsIgnored() {
        let metadata: [String: Any] = ["Olympus:StackedImage": "No"]

        XCTAssertEqual(ArtFilterTokenParsing.token(from: metadata), "")
    }

    // MARK: - Panasonic (values as a Lumix S9 wrote them)

    func testRealTimeLutNameIsTheToken() {
        let metadata: [String: Any] = [
            "Panasonic:PhotoStyle": "Scenery", "Panasonic:LUT1Name": "Scafell_sRGB33",
            "Panasonic:LUT1Opacity": 100, "Panasonic:LUT2Name": "",
        ]

        XCTAssertEqual(ArtFilterTokenParsing.token(from: metadata), "Scafell-sRGB33")
    }

    func testSecondLutSlotIsUsedWhenTheFirstIsEmpty() {
        let metadata: [String: Any] = ["Panasonic:LUT1Name": "", "Panasonic:LUT2Name": "Helvellyn_sRGB33"]

        XCTAssertEqual(ArtFilterTokenParsing.token(from: metadata), "Helvellyn-sRGB33")
    }

    func testVLogWithoutALutIsTheToken() {
        let metadata: [String: Any] = ["Panasonic:PhotoStyle": "V-Log", "Panasonic:LUT1Name": ""]

        XCTAssertEqual(ArtFilterTokenParsing.token(from: metadata), "V-Log")
    }

    func testEveryPhotoStyleButStandardIsNamed() {
        let expected = [
            "Standard or Custom": "", "Vivid": "Vivid", "Natural": "Natural", "Scenery": "Landscape",
            "Portrait": "Portrait",
        ]
        for (style, token) in expected {
            let metadata: [String: Any] = ["Panasonic:PhotoStyle": style, "Panasonic:LUT1Name": ""]

            XCTAssertEqual(ArtFilterTokenParsing.token(from: metadata), token, style)
        }
    }

    func testAChosenPhotoStyleIsTheToken() {
        let metadata: [String: Any] = ["Panasonic:PhotoStyle": "L. Monochrome D", "Panasonic:LUT1Name": ""]

        XCTAssertEqual(ArtFilterTokenParsing.token(from: metadata), "L.Monochrome D")
    }

    /// exiftool 13.55 has no name for these five; the numbers are what an S9 wrote.
    func testStylesExifToolCannotNameGetTheCameraName() {
        let expected = [
            "Unknown (16)": "Flat", "Unknown (19)": "Cinelike V2", "Unknown (20)": "L.Monochrome S",
            "Unknown (21)": "L.ClassicNeo", "Unknown (22)": "LEICA Monochrome",
        ]
        for (printed, name) in expected {
            XCTAssertEqual(ArtFilterTokenParsing.token(from: ["Panasonic:PhotoStyle": printed]), name)
        }
        XCTAssertEqual(ArtFilterTokenParsing.token(from: ["Panasonic:PhotoStyle": "Unknown (99)"]), "")
    }

    /// A saved custom style reads as its base style; its name is in an unnamed tag.
    func testCustomStyleNameIsTheToken() {
        let metadata: [String: Any] = [
            "Panasonic:PhotoStyle": "Standard or Custom", "Panasonic:LUT1Name": "",
            "Panasonic:Panasonic_0x00d5": "MY PHOTO STYLE 1[...]",
        ]

        XCTAssertEqual(ArtFilterTokenParsing.token(from: metadata), "MY PHOTO STYLE 1")
    }

    /// With no custom style the name tag still arrives, holding only exiftool's cut marker.
    func testAnEmptyCustomStyleNameFallsThroughToThePhotoStyle() {
        let chosen: [String: Any] = [
            "Panasonic:PhotoStyle": "Unknown (21)", "Panasonic:Panasonic_0x00d5": "[...]",
        ]
        let plain: [String: Any] = [
            "Panasonic:PhotoStyle": "Standard or Custom", "Panasonic:Panasonic_0x00d5": "[...]",
        ]

        XCTAssertEqual(ArtFilterTokenParsing.token(from: chosen), "L.ClassicNeo")
        XCTAssertEqual(ArtFilterTokenParsing.token(from: plain), "")
    }

    func testALutOutranksTheCustomStyleName() {
        let metadata: [String: Any] = [
            "Panasonic:LUT1Name": "HardKnott_sRGB33", "Panasonic:Panasonic_0x00d5": "MY PHOTO STYLE 1",
        ]

        XCTAssertEqual(ArtFilterTokenParsing.token(from: metadata), "HardKnott-sRGB33")
    }

    /// The RAW records the LUT's name but has none of it applied.
    func testARawGetsNoPanasonicToken() {
        let lut: [String: Any] = ["File:FileType": "RW2", "Panasonic:LUT1Name": "Scafell_sRGB33"]
        let vLog: [String: Any] = ["File:FileType": "RW2", "Panasonic:PhotoStyle": "V-Log"]

        XCTAssertEqual(ArtFilterTokenParsing.token(from: lut), "")
        XCTAssertEqual(ArtFilterTokenParsing.token(from: vLog), "")
    }

    /// The token is one `_`-separated segment of the renamed file.
    func testLutTokenStaysOneFilenameSegment() {
        let context = RenameContext(
            sourceURL: URL(fileURLWithPath: "/card/P1000006.JPG"), capturedAt: nil,
            cameraModel: "DC-S9", lensModel: "LUMIX S 18-40/F4.5-6.3", batch: "",
            artFilterToken: ArtFilterTokenParsing.token(from: ["Panasonic:LUT1Name": "Scafell_sRGB33"]))

        let name = RenameService().buildFilename(for: context)

        XCTAssertTrue(name.contains("_Scafell-sRGB33_DC-S9_"), name)
    }
}
