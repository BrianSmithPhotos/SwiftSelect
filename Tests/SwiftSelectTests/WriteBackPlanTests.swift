import XCTest

@testable import SwiftSelectCore

final class WriteBackPlanTests: XCTestCase {

    // MARK: - the manifest

    func testDecodesOneManifestLine() throws {
        let line = """
        {"path": "/Volumes/Photos/2019/2019-06-01/DSCF1141.RAF", "hash": "abc123", \
        "bytes": 52428800, "description": "A heron at dawn.", "keywords": ["heron", "dawn"]}
        """
        let entry = try XCTUnwrap(WriteBackPlan.entry(from: line))
        XCTAssertEqual(entry.path, "/Volumes/Photos/2019/2019-06-01/DSCF1141.RAF")
        XCTAssertEqual(entry.hash, "abc123")
        XCTAssertEqual(entry.bytes, 52_428_800)
        XCTAssertEqual(entry.description, "A heron at dawn.")
        XCTAssertEqual(entry.keywords, ["heron", "dawn"])
    }

    func testABlankLineIsNotAnEntryAndNotAnError() throws {
        // The manifest ends with a newline, so the last read line is empty.
        XCTAssertNil(try WriteBackPlan.entry(from: ""))
        XCTAssertNil(try WriteBackPlan.entry(from: "   \n"))
    }

    func testAMalformedLineThrowsRatherThanBeingSkipped() {
        // Silently skipping would mean a photograph never written and nothing said about it.
        XCTAssertThrowsError(try WriteBackPlan.entry(from: "{\"path\": \"/x.RAF\"}"))
    }

    func testKeywordsMayBeEmpty() throws {
        let line = """
        {"path": "/x.RAF", "hash": "h", "bytes": 1, "description": "d", "keywords": []}
        """
        let entry = try XCTUnwrap(WriteBackPlan.entry(from: line))
        XCTAssertEqual(entry.keywords, [])
    }

    // MARK: - the timeout

    func testSmallFilesKeepTheExistingTwelveSecondAllowance() {
        // A 2 MB JPEG is well under the floor: the cost there is exiftool starting up, not bytes.
        XCTAssertEqual(WriteBackPlan.timeoutSeconds(bytes: 2 * 1024 * 1024), 12, accuracy: 0.01)
    }

    func testALargeFileGetsLongerThanTheFloor() {
        // The largest DNG in the index, 112 MiB: exiftool reads and rewrites it, so 224 MiB
        // crosses the link, which at 19 MB/s is 11.8 s of pure transfer. Twelve seconds would
        // fail on a link doing exactly what it should.
        let seconds = WriteBackPlan.timeoutSeconds(bytes: 117_500_000)
        XCTAssertGreaterThan(seconds, 30)
        XCTAssertEqual(seconds, 35.4, accuracy: 0.5)
    }

    func testTheAllowanceScalesWithSize() {
        let small = WriteBackPlan.timeoutSeconds(bytes: 200 * 1024 * 1024)
        let large = WriteBackPlan.timeoutSeconds(bytes: 400 * 1024 * 1024)
        XCTAssertEqual(large, small * 2, accuracy: 0.01)
    }

    func testTheRateIsInjectableSoASlowerLinkCanBeMeasuredNotGuessed() {
        let fast = WriteBackPlan.timeoutSeconds(bytes: 400 * 1024 * 1024, megabytesPerSecond: 19)
        let slow = WriteBackPlan.timeoutSeconds(bytes: 400 * 1024 * 1024, megabytesPerSecond: 9.5)
        XCTAssertEqual(slow, fast * 2, accuracy: 0.01)
    }

    // MARK: - fetching an evicted file

    func testTheFetchAllowanceIsFarLongerThanTheWriteAllowance() {
        // The proven defect this exists for: a 2 MB placeholder gets 12 s to be written, and
        // fetching one measured 12.8 s at best and 26.8 s at worst. Every small evicted file in
        // iCloud would have failed before exiftool saw a byte.
        let small = 2 * 1024 * 1024
        XCTAssertEqual(WriteBackPlan.timeoutSeconds(bytes: small), 12, accuracy: 0.01)
        XCTAssertGreaterThan(WriteBackPlan.fetchTimeoutSeconds(bytes: small), 26.8 * 2)
    }

    func testTheFetchAllowanceBarelyScalesBecauseTheCostIsNotBytes() {
        // Measured: 2.1 MB took 26.8 s and 48.2 MB took 12.5. Size does not predict the wait, so
        // the floor does nearly all the work and both of these land on it.
        let small = WriteBackPlan.fetchTimeoutSeconds(bytes: 2 * 1024 * 1024)
        let large = WriteBackPlan.fetchTimeoutSeconds(bytes: 48 * 1024 * 1024)
        XCTAssertEqual(small, large, accuracy: 0.01)
        XCTAssertEqual(small, 90, accuracy: 0.01)
    }

    func testAVeryLargeFileStillGetsMoreThanTheFloor() {
        // 400 MB is past where the floor is credible even for a round-trip-bound fetch, so the
        // size term takes over rather than holding a huge file to a figure measured on small ones.
        XCTAssertGreaterThan(WriteBackPlan.fetchTimeoutSeconds(bytes: 400 * 1024 * 1024), 90)
    }

    // MARK: - resume

    func testResumeSkipsWhatAPreviousRunFinished() {
        let entries = [entry("/a.RAF"), entry("/b.RAF"), entry("/c.RAF")]
        let left = WriteBackPlan.remaining(entries: entries, done: ["/b.RAF"])
        XCTAssertEqual(left.map(\.path), ["/a.RAF", "/c.RAF"])
    }

    func testResumeKeepsManifestOrder() {
        // The manifest is ordered by path so the run reads the volume sequentially rather
        // than seeking across it. Filtering must not disturb that.
        let entries = [entry("/a.RAF"), entry("/b.RAF"), entry("/c.RAF"), entry("/d.RAF")]
        let left = WriteBackPlan.remaining(entries: entries, done: ["/a.RAF", "/c.RAF"])
        XCTAssertEqual(left.map(\.path), ["/b.RAF", "/d.RAF"])
    }

    func testNothingDoneMeansEverythingRemains() {
        let entries = [entry("/a.RAF"), entry("/b.RAF")]
        XCTAssertEqual(WriteBackPlan.remaining(entries: entries, done: []).count, 2)
    }

    // MARK: - quiet hours

    func testNoSpecMeansNoRestriction() throws {
        XCTAssertEqual(try QuietHours(nil).windows.count, 0)
        XCTAssertEqual(try QuietHours("").windows.count, 0)
        XCTAssertEqual(try QuietHours("   ").windows.count, 0)
        XCTAssertEqual(try QuietHours(nil).resumeInSeconds(at: at(18, 00)), 0)
    }

    func testParsesTheBackendsOwnSpec() throws {
        let quiet = try QuietHours("07:00-08:30,11:30-13:00,17:00-21:30")
        XCTAssertEqual(quiet.windows.count, 3)
        XCTAssertEqual(quiet.windows[0], QuietHours.Window(start: 420, end: 510))
        XCTAssertEqual(quiet.windows[2], QuietHours.Window(start: 1020, end: 1290))
    }

    func testOutsideEveryWindowTheRunGoes() throws {
        let quiet = try QuietHours("07:00-08:30,17:00-21:30")
        XCTAssertEqual(quiet.resumeInSeconds(at: at(22, 00)), 0)
        XCTAssertEqual(quiet.resumeInSeconds(at: at(9, 00)), 0)
    }

    func testInsideAWindowItWaitsUntilTheEnd() throws {
        let quiet = try QuietHours("17:00-21:30")
        XCTAssertEqual(quiet.resumeInSeconds(at: at(20, 30)), 60 * 60)
        XCTAssertEqual(quiet.resumeInSeconds(at: at(17, 00)), 4 * 60 * 60 + 30 * 60)
    }

    func testTheWindowIsHalfOpen() throws {
        // 21:30 is the moment work may resume, not the last minute of the pause.
        let quiet = try QuietHours("17:00-21:30")
        XCTAssertEqual(quiet.resumeInSeconds(at: at(21, 30)), 0)
        XCTAssertEqual(quiet.resumeInSeconds(at: at(21, 29)), 60)
    }

    func testTheSecondsHandIsSubtractedSoTheWaitEndsOnTheMinute() throws {
        let quiet = try QuietHours("17:00-21:30")
        XCTAssertEqual(quiet.resumeInSeconds(at: at(21, 29, 20)), 40)
    }

    func testAWindowWhoseEndPrecedesItsStartWrapsMidnight() throws {
        let quiet = try QuietHours("23:00-06:00")
        XCTAssertEqual(quiet.resumeInSeconds(at: at(23, 30)), 6 * 60 * 60 + 30 * 60)
        XCTAssertEqual(quiet.resumeInSeconds(at: at(2, 00)), 4 * 60 * 60)
        XCTAssertEqual(quiet.resumeInSeconds(at: at(6, 00)), 0)
        XCTAssertEqual(quiet.resumeInSeconds(at: at(22, 59)), 0)
    }

    func testRejectsSomethingThatIsNotAWindow() {
        XCTAssertThrowsError(try QuietHours("17:00"))
        XCTAssertThrowsError(try QuietHours("17:00-"))
        XCTAssertThrowsError(try QuietHours("25:00-26:00"))
        XCTAssertThrowsError(try QuietHours("evening-night"))
    }

    func testRejectsAMinuteOverSixtyThoughTheBackendWouldAcceptIt() {
        // pacing._minutes reads this as 22:39 rather than refusing it.
        XCTAssertThrowsError(try QuietHours("17:00-21:99"))
        XCTAssertThrowsError(try QuietHours("24:00-25:00"))
    }

    // MARK: - the real manifest

    /// The hand-written lines above prove the shape I believe the backend emits. This proves the
    /// shape it actually emits, over all 52,374 of them: every key present, every type right, and
    /// no line the decoder refuses. Env-gated because the path is Brian's and this repo is public.
    func testDecodesTheRealManifest() throws {
        let path = ProcessInfo.processInfo.environment["MPM_WRITEBACK_MANIFEST"] ?? ""
        try XCTSkipIf(path.isEmpty, "set MPM_WRITEBACK_MANIFEST to a `swiftphotolog writeback` file")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path))

        var entries = 0
        var largest = 0
        for line in try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n") {
            guard let entry = try WriteBackPlan.entry(from: String(line)) else { continue }
            XCTAssertFalse(entry.path.isEmpty)
            XCTAssertFalse(entry.description.isEmpty, "at \(entry.path)")
            XCTAssertGreaterThan(entry.bytes, 0, "at \(entry.path)")
            largest = max(largest, entry.bytes)
            entries += 1
        }
        print("manifest: \(entries) photographs, largest \(largest) bytes, "
            + "longest allowance \(Int(WriteBackPlan.timeoutSeconds(bytes: largest))) s")
        XCTAssertGreaterThan(entries, 0)
    }

    // MARK: - helpers

    private func entry(_ path: String) -> WriteBackEntry {
        WriteBackEntry(path: path, hash: "h", bytes: 1, description: "d", keywords: [])
    }

    /// A local-time instant, built through the same calendar `resumeInSeconds` reads back with,
    /// so the test says nothing about which zone the machine is in.
    private func at(_ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        var parts = DateComponents()
        parts.year = 2026
        parts.month = 9
        parts.day = 23
        parts.hour = hour
        parts.minute = minute
        parts.second = second
        return Calendar.current.date(from: parts)!
    }
}
