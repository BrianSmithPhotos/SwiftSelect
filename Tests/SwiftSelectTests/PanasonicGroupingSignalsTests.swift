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
}
