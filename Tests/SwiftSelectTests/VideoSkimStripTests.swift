import XCTest

@testable import SwiftSelect
@testable import SwiftSelectCore

/// The strip's frame times. Which times get sampled decides whether the strip is any use for
/// judging a clip, and it is the one part of the strip that can be checked without a real movie.
final class VideoSkimStripTests: XCTestCase {
    func testTimesAreSliceMidpointsAcrossTheWholeClip() {
        let times = VideoSkimStrip.sampleTimes(duration: 10, count: 5)

        XCTAssertEqual(times, [1, 3, 5, 7, 9])
    }

    func testNoTimeLandsOnTheFirstOrLastFrame() {
        let duration: TimeInterval = 91.1
        let times = VideoSkimStrip.sampleTimes(duration: duration, count: 10)

        XCTAssertEqual(times.count, 10)
        XCTAssertGreaterThan(times.first ?? 0, 0)
        XCTAssertLessThan(times.last ?? duration, duration)
    }

    func testTimesComeBackInClipOrder() {
        let times = VideoSkimStrip.sampleTimes(duration: 7, count: 6)

        XCTAssertEqual(times, times.sorted())
    }

    /// A clip whose length AVFoundation reports as unknown reaches this as zero (see
    /// `VideoAssetReader.duration`), and a strip of nothing is what the view treats as "no strip".
    func testAClipOfUnknownLengthHasNoStrip() {
        XCTAssertTrue(VideoSkimStrip.sampleTimes(duration: 0, count: 10).isEmpty)
        XCTAssertTrue(VideoSkimStrip.sampleTimes(duration: .nan, count: 10).isEmpty)
        XCTAssertTrue(VideoSkimStrip.sampleTimes(duration: .infinity, count: 10).isEmpty)
    }

    func testAskingForNoFramesGivesNone() {
        XCTAssertTrue(VideoSkimStrip.sampleTimes(duration: 10, count: 0).isEmpty)
    }
}
