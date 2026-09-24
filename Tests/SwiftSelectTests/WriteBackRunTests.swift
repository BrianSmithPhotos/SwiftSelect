import XCTest

@testable import SwiftSelect
@testable import SwiftSelectCore

private final class SpyWriter: WriteBackWriter, @unchecked Sendable {
    struct Call {
        let description: String
        let keywords: [String]
        let timeoutSeconds: Double
        let url: URL
    }

    var calls: [Call] = []
    /// Paths to throw on, so a failure can be aimed at one file.
    var failing: Set<String> = []
    var failEverything = false

    func writeBack(description: String, keywords: [String],
                   timeoutSeconds: Double, to url: URL) async throws {
        calls.append(Call(description: description, keywords: keywords,
                          timeoutSeconds: timeoutSeconds, url: url))
        if failEverything || failing.contains(url.path) {
            throw ExifToolError.timedOut
        }
    }
}

final class WriteBackRunTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("writeback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - writing

    func testWritesEveryPhotographAndLogsEachOne() async throws {
        let writer = SpyWriter()
        let log = try WriteBackLog(directory: directory)
        let outcome = await run(writer: writer).run(
            entries: [entry("/a.raf", hash: "h1"), entry("/b.raf", hash: "h2")], log: log)
        log.close()

        XCTAssertEqual(outcome, WriteBackRun.Outcome(written: 2, failed: 0, missing: 0))
        XCTAssertEqual(writer.calls.map(\.url.path), ["/a.raf", "/b.raf"])
        XCTAssertEqual(try WriteBackLog.alreadyWritten(in: directory), ["/a.raf", "/b.raf"])
    }

    func testTheDoneLogRecordsTheHashTheFileHadBeforeTheWrite() async throws {
        // The whole point of the log: after the write the file's hash is different, and this is the
        // only record tying the new file to the row that described it.
        let log = try WriteBackLog(directory: directory)
        _ = await run(writer: SpyWriter()).run(entries: [entry("/a.raf", hash: "beforehash")], log: log)
        log.close()

        let text = try String(contentsOf: directory.appendingPathComponent(WriteBackLog.doneName),
                              encoding: .utf8)
        let row = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(text.split(separator: "\n")[0].utf8)) as? [String: Any])
        XCTAssertEqual(row["path"] as? String, "/a.raf")
        XCTAssertEqual(row["hash"] as? String, "beforehash")
        XCTAssertNotNil(row["wrote_at"] as? Int)
    }

    func testTheAllowanceGivenToTheWriterScalesWithTheFile() async throws {
        let writer = SpyWriter()
        let log = try WriteBackLog(directory: directory)
        _ = await run(writer: writer).run(
            entries: [entry("/small.jpg", bytes: 2 * 1024 * 1024),
                      entry("/big.tif", bytes: 400 * 1024 * 1024)], log: log)
        log.close()

        XCTAssertEqual(writer.calls[0].timeoutSeconds, 12, accuracy: 0.01)
        XCTAssertGreaterThan(writer.calls[1].timeoutSeconds, 100)
    }

    func testKeywordsGoThroughTheAppsOwnNormalisation() async throws {
        let writer = SpyWriter()
        let log = try WriteBackLog(directory: directory)
        _ = await run(writer: writer).run(
            entries: [entry("/a.raf", keywords: [" heron ", "heron", "", "Dawn"])], log: log)
        log.close()

        XCTAssertEqual(writer.calls[0].keywords, ["heron", "Dawn"])
    }

    func testADryRunWritesNothingAndLogsNothing() async throws {
        let writer = SpyWriter()
        let log = try WriteBackLog(directory: directory)
        let outcome = await run(writer: writer, dryRun: true)
            .run(entries: [entry("/a.raf")], log: log)
        log.close()

        XCTAssertEqual(outcome.written, 1)
        XCTAssertTrue(writer.calls.isEmpty)
        XCTAssertEqual(try WriteBackLog.alreadyWritten(in: directory), [])
    }

    func testALimitStopsAfterThatMany() async throws {
        let writer = SpyWriter()
        let log = try WriteBackLog(directory: directory)
        _ = await run(writer: writer).run(
            entries: [entry("/a.raf"), entry("/b.raf"), entry("/c.raf")], log: log, limit: 2)
        log.close()

        XCTAssertEqual(writer.calls.count, 2)
    }

    // MARK: - going wrong

    func testOneBadFileDoesNotStopTheRunAndStaysOutOfTheResumeSet() async throws {
        let writer = SpyWriter()
        writer.failing = ["/b.raf"]
        let log = try WriteBackLog(directory: directory)
        let outcome = await run(writer: writer).run(
            entries: [entry("/a.raf"), entry("/b.raf"), entry("/c.raf")], log: log)
        log.close()

        XCTAssertEqual(outcome, WriteBackRun.Outcome(written: 2, failed: 1, missing: 0))
        // Not in the done set, so the next run retries it.
        XCTAssertEqual(try WriteBackLog.alreadyWritten(in: directory), ["/a.raf", "/c.raf"])
        let failures = try String(contentsOf: directory.appendingPathComponent(WriteBackLog.failedName),
                                 encoding: .utf8)
        XCTAssertTrue(failures.contains("/b.raf"))
    }

    func testAFileThatIsNotThereIsCountedRatherThanWritten() async throws {
        let writer = SpyWriter()
        var subject = run(writer: writer)
        subject.exists = { $0 != "/gone.raf" }
        let log = try WriteBackLog(directory: directory)
        let outcome = await subject.run(entries: [entry("/a.raf"), entry("/gone.raf")], log: log)
        log.close()

        XCTAssertEqual(outcome, WriteBackRun.Outcome(written: 1, failed: 0, missing: 1))
        XCTAssertEqual(writer.calls.count, 1)
    }

    func testTenFailuresInARowStopTheRun() async throws {
        // The share has dropped mid-run before. The failure to avoid is a run that writes 40,000
        // failures to an unmounted path and then reports itself finished.
        let writer = SpyWriter()
        writer.failEverything = true
        let log = try WriteBackLog(directory: directory)
        let entries = (0..<50).map { entry("/f\($0).raf") }
        let outcome = await run(writer: writer).run(entries: entries, log: log)
        log.close()

        XCTAssertEqual(outcome.failed, WriteBackRun.givingUpAfter)
        XCTAssertNotNil(outcome.stopped)
        XCTAssertEqual(writer.calls.count, WriteBackRun.givingUpAfter)
    }

    func testAVanishedVolumeStopsTheRunToo() async throws {
        let writer = SpyWriter()
        var subject = run(writer: writer)
        subject.exists = { _ in false }
        let log = try WriteBackLog(directory: directory)
        let outcome = await subject.run(entries: (0..<50).map { entry("/f\($0).raf") }, log: log)
        log.close()

        XCTAssertEqual(outcome.missing, WriteBackRun.givingUpAfter)
        XCTAssertNotNil(outcome.stopped)
    }

    func testScatteredStaleEntriesDoNotStopTheRun() async throws {
        // A file `refile` moved since the manifest was made is not a dropped share.
        let writer = SpyWriter()
        var subject = run(writer: writer)
        subject.exists = { path in !path.hasSuffix("3.raf") }
        let log = try WriteBackLog(directory: directory)
        let outcome = await subject.run(entries: (0..<40).map { entry("/f\($0).raf") }, log: log)
        log.close()

        XCTAssertNil(outcome.stopped)
        XCTAssertEqual(outcome.written, 36)
        XCTAssertEqual(outcome.missing, 4)
    }

    // MARK: - quiet hours

    func testItWaitsOutQuietHoursBeforeTouchingTheVolume() async throws {
        let writer = SpyWriter()
        var paused: [Int] = []
        var subject = try run(writer: writer, quiet: QuietHours("17:00-21:30"))
        subject.now = { Self.at(20, 30) }
        subject.pause = { paused.append($0) }
        let log = try WriteBackLog(directory: directory)
        _ = await subject.run(entries: [entry("/a.raf")], log: log)
        log.close()

        XCTAssertEqual(paused.first, 60 * 60)
        // It still writes afterwards - the pause is a pause, not a skip.
        XCTAssertEqual(writer.calls.count, 1)
    }

    func testOutsideQuietHoursItDoesNotPause() async throws {
        var paused: [Int] = []
        var subject = try run(writer: SpyWriter(), quiet: QuietHours("17:00-21:30"))
        subject.now = { Self.at(22, 00) }
        subject.pause = { paused.append($0) }
        let log = try WriteBackLog(directory: directory)
        _ = await subject.run(entries: [entry("/a.raf")], log: log)
        log.close()

        XCTAssertTrue(paused.isEmpty)
    }

    // MARK: - the manifest and the logs on disk

    func testReadsTheManifestAndRefusesALineItCannotDecode() throws {
        let good = directory.appendingPathComponent("good.jsonl")
        try #"""
        {"path":"/a.raf","hash":"h1","bytes":10,"description":"d","keywords":["k"]}
        {"path":"/b.raf","hash":"h2","bytes":20,"description":"e","keywords":[]}
        """#.write(to: good, atomically: true, encoding: .utf8)
        XCTAssertEqual(try WriteBackManifest.read(good).map(\.path), ["/a.raf", "/b.raf"])

        let bad = directory.appendingPathComponent("bad.jsonl")
        try #"{"path":"/a.raf"}"#.write(to: bad, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try WriteBackManifest.read(bad)) { error in
            XCTAssertTrue(String(describing: error).contains("line 1"), "\(error)")
        }
    }

    func testTheResumeSetIsEmptyBeforeAnyRun() throws {
        XCTAssertEqual(try WriteBackLog.alreadyWritten(in: directory), [])
    }

    func testASecondLogAppendsRatherThanReplacing() async throws {
        let first = try WriteBackLog(directory: directory)
        _ = await run(writer: SpyWriter()).run(entries: [entry("/a.raf")], log: first)
        first.close()

        let second = try WriteBackLog(directory: directory)
        _ = await run(writer: SpyWriter()).run(entries: [entry("/b.raf")], log: second)
        second.close()

        XCTAssertEqual(try WriteBackLog.alreadyWritten(in: directory), ["/a.raf", "/b.raf"])
    }

    // MARK: - helpers

    private func run(writer: WriteBackWriter, quiet: QuietHours = .none,
                     dryRun: Bool = false) -> WriteBackRun {
        var subject = WriteBackRun(writer: writer, quiet: quiet, dryRun: dryRun)
        subject.exists = { _ in true }
        subject.say = { _ in }
        subject.pause = { _ in }
        return subject
    }

    private func entry(_ path: String, hash: String = "h", bytes: Int = 1000,
                       keywords: [String] = []) -> WriteBackEntry {
        WriteBackEntry(path: path, hash: hash, bytes: bytes,
                       description: "a heron at dawn", keywords: keywords)
    }

    private static func at(_ hour: Int, _ minute: Int) -> Date {
        var parts = DateComponents()
        parts.year = 2026; parts.month = 9; parts.day = 24
        parts.hour = hour; parts.minute = minute
        return Calendar.current.date(from: parts)!
    }
}
