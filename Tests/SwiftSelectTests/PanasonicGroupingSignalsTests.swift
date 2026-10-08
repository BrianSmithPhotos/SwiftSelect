import XCTest

@testable import SwiftSelect
@testable import SwiftSelectCore

/// The folder scan's reading of Panasonic bracket frames, with values as a Lumix S9 wrote them
/// (exiftool `-n` output: numbers, not prose).
final class PanasonicGroupingSignalsTests: XCTestCase {
    private func signals(sequence: Int, exposureCompensation: Double = 0) -> CaptureSignals {
        ExifToolClient.groupingSignals(from: [
            "SequenceNumber": sequence, "ExposureCompensation": exposureCompensation,
        ])
    }

    private func asset(_ url: URL, capturedAt: Date) -> PhotoAsset {
        var asset = PhotoAsset(id: url)
        asset.capturedAt = capturedAt
        return asset
    }

    func testSequenceNumberBecomesTheShotNumber() {
        XCTAssertEqual(signals(sequence: 3).shotNumber, 3)
    }

    func testASingleShotHasNoShotNumber() {
        XCTAssertNil(signals(sequence: 0).shotNumber)
    }

    func testOlympusDriveModeIsNotOverridden() {
        let olympus = ExifToolClient.groupingSignals(from: ["DriveMode": "5 2 0 0 0 0", "SequenceNumber": 9])
        XCTAssertEqual(olympus.shotNumber, 2)
    }

    /// Eleven focus-bracket frames a quarter of a second apart all render the same, which without
    /// a shot number reads as eleven separate presses.
    func testAFocusBracketIsOneCaptureSet() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var assets: [PhotoAsset] = []
        var scanned: [URL: CaptureSignals] = [:]
        for index in 1...11 {
            let url = URL(fileURLWithPath: "/card/P10000\(index + 9).JPG")
            assets.append(asset(url, capturedAt: start.addingTimeInterval(Double(index) * 0.24)))
            scanned[url] = signals(sequence: index)
        }
        let single = URL(fileURLWithPath: "/card/P1000021.JPG")
        assets.append(asset(single, capturedAt: start.addingTimeInterval(3)))
        scanned[single] = signals(sequence: 0)

        let sets = CaptureGroupingService().group(assets, signals: scanned)

        XCTAssertEqual(sets.map(\.members.count), [11, 1])
    }

    /// P1000059-61 then a later single: one instant, no sequence number, shift 0, -4, +4.
    func testAWhiteBalanceBracketIsOneCaptureSet() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var assets: [PhotoAsset] = []
        var signals: [URL: CaptureSignals] = [:]
        for (index, shift) in [0, -4, 4, 0].enumerated() {
            let url = URL(fileURLWithPath: "/card/P10000\(59 + index).JPG")
            var asset = PhotoAsset(id: url)
            asset.capturedAt = index < 3 ? start : start.addingTimeInterval(60)
            assets.append(asset)
            signals[url] = ExifToolClient.groupingSignals(from: [
                "SequenceNumber": 0, "ExposureCompensation": 0, "WBShiftAB": shift, "WBShiftGM": 0,
            ])
        }

        let sets = CaptureGroupingService().group(assets, signals: signals)

        XCTAssertEqual(sets.map(\.members.count), [3, 1])
    }

    /// P1010018/19 then a later single: "simultaneous record without filter" saves an Expressive
    /// JPEG and a plain one from one exposure, same instant, no sequence number.
    func testAFilteredJpegAndItsPlainCopyAreOneCaptureSet() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var assets: [PhotoAsset] = []
        var signals: [URL: CaptureSignals] = [:]
        for (index, filter) in ["0 1", "0 0", "0 1"].enumerated() {
            let url = URL(fileURLWithPath: "/card/P10100\(18 + index).JPG")
            assets.append(asset(url, capturedAt: index < 2 ? start : start.addingTimeInterval(48)))
            signals[url] = ExifToolClient.groupingSignals(from: [
                "SequenceNumber": 0, "ExposureCompensation": 0, "WBShiftAB": 0, "WBShiftGM": 0,
                "FilterEffect": filter,
            ])
        }

        let sets = CaptureGroupingService().group(assets, signals: signals)

        XCTAssertEqual(sets.map(\.members.count), [2, 1])
    }
}
