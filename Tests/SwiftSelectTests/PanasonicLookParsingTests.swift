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

    func testAnOlympusFileIsUntouched() {
        XCTAssertEqual(summary(["Olympus:PictureMode": "Vivid"]), "Vivid")
    }
}
