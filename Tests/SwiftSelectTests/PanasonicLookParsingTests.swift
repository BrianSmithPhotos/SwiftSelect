import XCTest

@testable import SwiftSelectCore

/// Values as a Lumix S9 wrote them and as the app's full exiftool read returns them.
final class PanasonicLookParsingTests: XCTestCase {
    private func summary(_ metadata: [String: Any]) -> String {
        CameraLookParsing.look(from: metadata)
    }

    func testStandardWithNothingDialledHasNoLook() {
        XCTAssertNil(CameraLookParsing.parse(from: [
            "Panasonic:PhotoStyle": "Standard or Custom", "Panasonic:LUT1Name": "",
            "Panasonic:Panasonic_0x00d5": "[...]", "Panasonic:Panasonic_0x00d7": 0,
            "Panasonic:Panasonic_0x00db": "0 0", "Panasonic:MonochromeGrainEffect": "Off",
        ]))
    }

    func testAPlainStyleIsNamedTheWayTheCameraNamesIt() {
        XCTAssertEqual(summary(["Panasonic:PhotoStyle": "Scenery"]), "Landscape")
        XCTAssertEqual(summary(["Panasonic:PhotoStyle": "Unknown (22)"]), "LEICA Monochrome")
    }

    /// P1000021: a LUT over a Monochrome base.
    func testALutReportsTheStyleItSitsOn() {
        let metadata: [String: Any] = [
            "Panasonic:PhotoStyle": "Monochrome", "Panasonic:LUT1Name": "HardKnott_sRGB33",
            "Panasonic:LUT1Opacity": 100, "Panasonic:Panasonic_0x00d5": "[...]",
        ]

        XCTAssertEqual(summary(metadata), "HardKnott-sRGB33 | base Monochrome")
    }

    /// P1000054: two LUTs stacked on a saved custom style.
    func testTwoStackedLutsOnACustomStyleAreAllReported() {
        let metadata: [String: Any] = [
            "Panasonic:PhotoStyle": "Standard or Custom",
            "Panasonic:LUT1Name": "Catbells_sRGB33", "Panasonic:LUT1Opacity": 60,
            "Panasonic:LUT2Name": "HardKnott_sRGB33", "Panasonic:LUT2Opacity": 70,
            "Panasonic:Panasonic_0x00d5": "MY PHOTO STYLE 3[...]",
        ]

        XCTAssertEqual(
            summary(metadata),
            "DualLUT | base Standard | style MY PHOTO STYLE 3 | lut 1 Catbells-sRGB33 60% | "
                + "lut 2 HardKnott-sRGB33 70%")
        XCTAssertEqual(ArtFilterTokenParsing.token(from: metadata), "DualLUT")
    }

    func testAPartLutOpacityIsReported() {
        let metadata: [String: Any] = [
            "Panasonic:PhotoStyle": "Scenery", "Panasonic:LUT1Name": "Scafell_sRGB33",
            "Panasonic:LUT1Opacity": 50,
        ]

        XCTAssertEqual(summary(metadata), "Scafell-sRGB33 | base Landscape | opacity 50%")
    }

    /// P1000049: every setting dialled to a different value.
    func testEveryDialledSettingIsReported() {
        let metadata: [String: Any] = [
            "Panasonic:PhotoStyle": "Standard or Custom", "Panasonic:LUT1Name": "",
            "Panasonic:Panasonic_0x00d5": "MY PHOTO STYLE 2[...]",
            "Panasonic:Panasonic_0x00d7": 2, "Panasonic:Panasonic_0x00d8": 2.5,
            "Panasonic:Panasonic_0x00d9": -0.5, "Panasonic:Panasonic_0x00da": 3,
            "Panasonic:Panasonic_0x00db": "-1 1.5", "Panasonic:NoiseReductionStrength": -1.5,
            "Panasonic:MonochromeGrainEffect": "Unknown (5)",
        ]

        XCTAssertEqual(
            summary(metadata),
            "MY PHOTO STYLE 2 | base Standard | contrast +2 | highlights -1 | shadows +1.5 | "
                + "saturation +2.5 | hue +3 | sharpness -0.5 | noise reduction -1.5 | grain standard, colour noise")
    }

    /// P1000050 (Low, Colour Noise On) and P1000051 (Standard, Colour Noise Off).
    func testGrainReportsStrengthAndColourNoise() {
        let low: [String: Any] = [
            "Panasonic:PhotoStyle": "Vivid", "Panasonic:MonochromeGrainEffect": "Unknown (4)",
        ]
        let standard: [String: Any] = [
            "Panasonic:PhotoStyle": "Vivid", "Panasonic:MonochromeGrainEffect": "Standard",
        ]

        XCTAssertEqual(summary(low), "Vivid | grain low, colour noise")
        XCTAssertEqual(summary(standard), "Vivid | grain standard")
    }

    /// P1000069: warm Auto with A5 G3 dialled in. P1000060: the amber frame of a bracket on Auto.
    func testWhiteBalanceModeAndShiftReadAsTheCameraShowsThem() {
        let warm: [String: Any] = [
            "Panasonic:PhotoStyle": "Standard or Custom", "Panasonic:WhiteBalance": "Unknown (20)",
            "Panasonic:WBShiftAB": -5, "Panasonic:WBShiftGM": 3,
        ]
        let bracket: [String: Any] = [
            "Panasonic:PhotoStyle": "Vivid", "Panasonic:WhiteBalance": "Auto",
            "Panasonic:WBShiftAB": 4, "Panasonic:WBShiftGM": 0,
        ]

        XCTAssertEqual(summary(warm), "Standard | white balance AWBw A5 G3")
        XCTAssertEqual(summary(bracket), "Vivid | white balance B4")
    }

    /// P1000071-79: one frame per white balance mode.
    func testEachWhiteBalanceModeIsNamedAsTheCameraNamesIt() {
        let expected: [(mode: String, kelvin: Int, shift: (Int, Int), row: String)] = [
            ("Auto (cool)", 4100, (0, 0), "AWBc"), ("Daylight", 5500, (0, 0), "Daylight"),
            ("Shade", 7300, (0, 0), "Shade"), ("Manual", 5500, (0, 0), "White set 1"),
            ("Kelvin", 5500, (0, 0), "5500K"), ("Unknown (17)", 4900, (4, -3), "4900K B4 M3"),
            // P1010098-102: the other three white sets and a later colour temperature set.
            ("Manual 2", 5500, (0, 0), "White set 2"), ("Manual 3", 5500, (0, 0), "White set 3"),
            ("Manual 4", 5500, (0, 0), "White set 4"), ("Unknown (18)", 3200, (-3, 2), "3200K A3 G2"),
        ]
        for (mode, kelvin, shift, row) in expected {
            let metadata: [String: Any] = [
                "Panasonic:PhotoStyle": "Standard or Custom", "Panasonic:WhiteBalance": mode,
                "Panasonic:ColorTempKelvin": kelvin, "Panasonic:WBShiftAB": shift.0,
                "Panasonic:WBShiftGM": shift.1,
            ]

            XCTAssertEqual(summary(metadata), "Standard | white balance \(row)", mode)
        }
    }

    func testPlainAutoWhiteBalanceAddsNothing() {
        XCTAssertNil(CameraLookParsing.parse(from: [
            "Panasonic:PhotoStyle": "Standard or Custom", "Panasonic:WhiteBalance": "Auto",
            "Panasonic:ColorTempKelvin": 4400, "Panasonic:WBShiftAB": 0, "Panasonic:WBShiftGM": 0,
        ]))
    }

    func testAnOlympusFileIsUntouched() {
        XCTAssertEqual(summary(["Olympus:PictureMode": "Vivid"]), "Vivid")
    }

    /// P1010011: a filter clears the LUT and reads Standard; the filter is the look.
    func testAFilterIsTheLookAndTheToken() {
        let metadata: [String: Any] = [
            "Panasonic:PhotoStyle": "Standard or Custom", "Panasonic:FilterEffect": "Retro",
            "Panasonic:LUT1Name": "", "Panasonic:Panasonic_0x00d5": "[...]",
        ]

        XCTAssertEqual(summary(metadata), "Retro")
        XCTAssertEqual(ArtFilterTokenParsing.token(from: metadata), "Retro")
    }

    /// P1010019: the plain copy saved beside a filtered JPEG.
    func testNoFilterAddsNothing() {
        let metadata: [String: Any] = [
            "Panasonic:PhotoStyle": "Standard or Custom", "Panasonic:FilterEffect": "Off",
        ]

        XCTAssertNil(CameraLookParsing.parse(from: metadata))
        XCTAssertEqual(ArtFilterTokenParsing.token(from: metadata), "")
    }

    /// P1010008: a style titled on the camera, holding a LUT and a contrast tweak.
    func testATitledStyleWinsOverItsLut() {
        let metadata: [String: Any] = [
            "Panasonic:PhotoStyle": "Standard or Custom",
            "Panasonic:LUT1Name": "HardKnott_sRGB33", "Panasonic:LUT1Opacity": 100,
            "Panasonic:Panasonic_0x00d5": "Hard Knott[...]", "Panasonic:Panasonic_0x00d7": 2,
        ]

        XCTAssertEqual(summary(metadata), "Hard Knott | base Standard | lut HardKnott-sRGB33 | contrast +2")
        XCTAssertEqual(ArtFilterTokenParsing.token(from: metadata), "Hard Knott")
    }

    func testATitledStyleListsItsLutOpacityAndBothOfTwoLuts() {
        var metadata: [String: Any] = [
            "Panasonic:PhotoStyle": "Standard or Custom",
            "Panasonic:LUT1Name": "Catbells_sRGB33", "Panasonic:LUT1Opacity": 60,
            "Panasonic:Panasonic_0x00d5": "Fells[...]",
        ]
        XCTAssertEqual(summary(metadata), "Fells | base Standard | lut Catbells-sRGB33 60%")

        metadata["Panasonic:LUT2Name"] = "HardKnott_sRGB33"
        metadata["Panasonic:LUT2Opacity"] = 70
        XCTAssertEqual(
            summary(metadata),
            "Fells | base Standard | lut 1 Catbells-sRGB33 60% | lut 2 HardKnott-sRGB33 70%")
        XCTAssertEqual(ArtFilterTokenParsing.token(from: metadata), "Fells")
    }
}
