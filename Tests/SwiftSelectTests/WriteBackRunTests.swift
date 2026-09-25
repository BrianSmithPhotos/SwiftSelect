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

    /// Locked because `@unchecked Sendable` has to be earned once a run has more than one lane.
    private let lock = NSLock()
    private var recorded: [Call] = []
    var calls: [Call] { lock.withLock { recorded } }
    /// Paths to throw on, so a failure can be aimed at one file.
    var failing: Set<String> = []
    var failEverything = false

    func writeBack(description: String, keywords: [String],
                   timeoutSeconds: Double, to url: URL) async throws {
        lock.withLock {
            recorded.append(Call(description: description, keywords: keywords,
                                 timeoutSeconds: timeoutSeconds, url: url))
        }
        if failEverything || failing.contains(url.path) {
            throw ExifToolError.timedOut
        }
    }
}

/// Records what was fetched and in what order relative to the writes, since a fetch that happens
/// after exiftool has opened the file is no use at all.
private final class FetchSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    var order: [String] { lock.withLock { events } }
    func note(_ event: String) { lock.withLock { events.append(event) } }
}

/// Writes, and notes that it wrote, so a test can assert the fetch came first.
private final class OrderedWriter: WriteBackWriter, @unchecked Sendable {
    private let spy: FetchSpy
    init(spy: FetchSpy) { self.spy = spy }
    func writeBack(description: String, keywords: [String],
                   timeoutSeconds: Double, to url: URL) async throws {
        spy.note("write \(url.path)")
    }
}

/// Drives the closing settling wait, which is the one part of the run measured in real seconds.
private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds = 0.0
    var value: Date { lock.withLock { Date(timeIntervalSince1970: seconds) } }
    var elapsed: Double { lock.withLock { seconds } }
    func advance(_ by: Double) { lock.withLock { seconds += by } }
}

/// An actor rather than a lock because the fetch seam is async and this is awaited from inside it.
private actor LaneCounter {
    private var inFlight = 0
    private(set) var peak = 0
    func enter() { inFlight += 1; peak = max(peak, inFlight) }
    func leave() { inFlight -= 1 }
}

/// Counts how many writes overlap, which is the only thing that distinguishes lanes from a loop.
private final class LaneSpy: WriteBackWriter, @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight = 0
    private var peak = 0
    private var seen: [String] = []

    var highWaterMark: Int { lock.withLock { peak } }
    var paths: [String] { lock.withLock { seen } }

    func writeBack(description: String, keywords: [String],
                   timeoutSeconds: Double, to url: URL) async throws {
        lock.withLock {
            inFlight += 1
            peak = max(peak, inFlight)
            seen.append(url.path)
        }
        // Long enough that a second lane will have started before this one finishes, and short
        // enough not to slow the suite. Without it every write would complete before the next
        // began and the peak would read 1 whatever the lane count.
        try? await Task.sleep(nanoseconds: 20_000_000)
        lock.withLock { inFlight -= 1 }
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

    // MARK: - lanes

    func testByDefaultOnlyOnePhotographIsInFlight() async throws {
        // The wireless run, and every existing caller: one file at a time, as it always was.
        let writer = LaneSpy()
        let log = try WriteBackLog(directory: directory)
        _ = await run(writer: writer).run(entries: (0..<6).map { entry("/f\($0).raf") }, log: log)
        log.close()

        XCTAssertEqual(writer.highWaterMark, 1)
    }

    func testLanesActuallyOverlap() async throws {
        let writer = LaneSpy()
        var subject = run(writer: writer)
        subject.workers = 4
        let log = try WriteBackLog(directory: directory)
        _ = await subject.run(entries: (0..<20).map { entry("/f\($0).raf") }, log: log)
        log.close()

        XCTAssertEqual(writer.highWaterMark, 4)
    }

    func testLanesNeverExceedTheirNumber() async throws {
        // A pool that refilled without waiting would climb to the length of the list, which on the
        // real run is 142,566 exiftool processes at once.
        let writer = LaneSpy()
        var subject = run(writer: writer)
        subject.workers = 3
        let log = try WriteBackLog(directory: directory)
        _ = await subject.run(entries: (0..<30).map { entry("/f\($0).raf") }, log: log)
        log.close()

        XCTAssertLessThanOrEqual(writer.highWaterMark, 3)
    }

    func testWithLanesEveryPhotographIsStillWrittenExactlyOnce() async throws {
        let writer = LaneSpy()
        var subject = run(writer: writer)
        subject.workers = 5
        let log = try WriteBackLog(directory: directory)
        let entries = (0..<40).map { entry("/f\($0).raf", hash: "h\($0)") }

        let outcome = await subject.run(entries: entries, log: log)
        log.close()

        XCTAssertEqual(outcome.written, 40)
        XCTAssertEqual(Set(writer.paths).count, 40)
        XCTAssertEqual(writer.paths.count, 40, "a photograph written twice is a photograph whose "
                       + "hash moved twice, and the second mapping would be wrong")
        // The resume set is a set of paths, so lanes finishing out of order costs it nothing.
        XCTAssertEqual(try WriteBackLog.alreadyWritten(in: directory).count, 40)
    }

    func testALimitStillAppliesWithLanes() async throws {
        let writer = LaneSpy()
        var subject = run(writer: writer)
        subject.workers = 4
        let log = try WriteBackLog(directory: directory)

        let outcome = await subject.run(
            entries: (0..<20).map { entry("/f\($0).raf") }, log: log, limit: 2)
        log.close()

        XCTAssertEqual(outcome.written, 2)
        XCTAssertEqual(writer.paths.count, 2)
    }

    func testAVanishedVolumeStillStopsTheRunWithLanes() async throws {
        let writer = LaneSpy()
        var subject = run(writer: writer)
        subject.workers = 4
        subject.exists = { _ in false }
        let log = try WriteBackLog(directory: directory)

        let outcome = await subject.run(entries: (0..<200).map { entry("/f\($0).raf") }, log: log)
        log.close()

        XCTAssertNotNil(outcome.stopped)
        // At least the threshold, because that is what trips it, and fewer than the lanes could
        // have added afterwards: once it stops dispatching it drains what is in flight rather than
        // cutting an exiftool write short, so the count can overshoot by up to a lane's worth.
        XCTAssertGreaterThanOrEqual(outcome.missing, WriteBackRun.givingUpAfter)
        XCTAssertLessThan(outcome.missing, WriteBackRun.givingUpAfter + subject.workers)
    }

    func testScatteredStaleEntriesDoNotStopTheRunWithLanesEither() async throws {
        let writer = LaneSpy()
        var subject = run(writer: writer)
        subject.workers = 4
        subject.exists = { !$0.hasSuffix("7.raf") }
        let log = try WriteBackLog(directory: directory)

        let outcome = await subject.run(entries: (0..<40).map { entry("/f\($0).raf") }, log: log)
        log.close()

        XCTAssertNil(outcome.stopped)
        XCTAssertEqual(outcome.written, 36)
        XCTAssertEqual(outcome.missing, 4)
    }

    // MARK: - evicted cloud files

    func testAFileOnTheNasIsNeverFetched() async throws {
        // The property that matters most in this whole change. A fetch on a NAS original means
        // reading it twice, and there are 4,645 GB of them - days of link time for nothing.
        let writer = SpyWriter()
        var subject = run(writer: writer)
        subject.presence = { _ in .notCloud }
        var asked = false
        subject.fetch = { _, _ in asked = true; return 0 }
        let outcome = await subject.run(entries: [entry("/Volumes/Photos/a.raf")], log: try WriteBackLog(directory: directory))
        XCTAssertFalse(asked)
        XCTAssertEqual(outcome.written, 1)
        XCTAssertEqual(outcome.fetched, 0)
    }

    func testACloudFileWhoseBytesAreHereIsNotFetchedEither() async throws {
        let writer = SpyWriter()
        var subject = run(writer: writer)
        subject.presence = { _ in .present }
        var asked = false
        subject.fetch = { _, _ in asked = true; return 0 }
        let outcome = await subject.run(entries: [entry("/icloud/a.jpg")], log: try WriteBackLog(directory: directory))
        XCTAssertFalse(asked)
        XCTAssertEqual(outcome.written, 1)
    }

    func testAnEvictedFileIsFetchedBeforeItIsWritten() async throws {
        let spy = FetchSpy()
        let writer = OrderedWriter(spy: spy)
        var subject = run(writer: writer)
        subject.presence = { _ in .evicted }
        subject.fetch = { path, _ in spy.note("fetch \(path)"); return 3 }
        let outcome = await subject.run(entries: [entry("/icloud/a.jpg")], log: try WriteBackLog(directory: directory))
        XCTAssertEqual(outcome.written, 1)
        XCTAssertEqual(spy.order, ["fetch /icloud/a.jpg", "write /icloud/a.jpg"])
    }

    func testTheAllowanceHandedToTheFetchIsTheFetchAllowance() async throws {
        // Not `timeoutSeconds`. Passing that would reproduce exactly the defect this fixes.
        let writer = SpyWriter()
        var subject = run(writer: writer)
        subject.presence = { _ in .evicted }
        var given: Double?
        subject.fetch = { _, timeout in given = timeout; return 1 }
        _ = await subject.run(entries: [entry("/icloud/a.jpg", bytes: 2 * 1024 * 1024)],
                              log: try WriteBackLog(directory: directory))
        XCTAssertEqual(given, WriteBackPlan.fetchTimeoutSeconds(bytes: 2 * 1024 * 1024))
        XCTAssertGreaterThan(try XCTUnwrap(given), 26.8)
    }

    func testAFetchThatNeverArrivesIsAFailureAndExifToolIsNotStarted() async throws {
        let writer = SpyWriter()
        var subject = run(writer: writer)
        subject.presence = { _ in .evicted }
        subject.fetch = { path, _ in
            throw CloudFile.Failure.notFetched(path: path, afterSeconds: 90)
        }
        let outcome = await subject.run(entries: [entry("/icloud/a.jpg")], log: try WriteBackLog(directory: directory))
        XCTAssertEqual(outcome.failed, 1)
        XCTAssertEqual(outcome.written, 0)
        // Never written, so never logged as done: the resume set must offer it again.
        XCTAssertTrue(writer.calls.isEmpty)
        XCTAssertEqual(try WriteBackLog.alreadyWritten(in: directory), [])
    }

    func testWhatTheProvidersCostIsReported() async throws {
        // A fetch is tens of seconds against exiftool's half a second, so a run that looks slow is
        // usually a run waiting on a provider. Invisible unless it is counted.
        let writer = SpyWriter()
        var subject = run(writer: writer)
        var evicted = true
        subject.presence = { _ in evicted ? .evicted : .notCloud }
        subject.fetch = { _, _ in 20 }
        let outcome = await subject.run(entries: [entry("/icloud/a.jpg"), entry("/icloud/b.jpg")],
                                        log: try WriteBackLog(directory: directory))
        XCTAssertEqual(outcome.written, 2)
        XCTAssertEqual(outcome.fetched, 2)
        XCTAssertEqual(outcome.fetchSeconds, 40, accuracy: 0.01)
        evicted = false
    }

    func testEvictedFilesFetchInParallelWhenThereAreLanes() async throws {
        // The measured reason lanes exist for iCloud: the wait is a round trip, so eight waits
        // overlap into one. Serially this list would be 8 x 20 s.
        let writer = SpyWriter()
        var subject = run(writer: writer)
        subject.workers = 8
        subject.presence = { _ in .evicted }
        let counter = LaneCounter()
        subject.fetch = { _, _ in
            await counter.enter()
            try? await Task.sleep(nanoseconds: 20_000_000)
            await counter.leave()
            return 20
        }
        let entries = (0..<8).map { entry("/icloud/\($0).jpg") }
        let outcome = await subject.run(entries: entries, log: try WriteBackLog(directory: directory))
        XCTAssertEqual(outcome.written, 8)
        // Hoisted: XCTAssert's arguments are autoclosures and cannot await.
        let peak = await counter.peak
        XCTAssertEqual(peak, 8)
    }

    // MARK: - giving the bytes back

    func testAWokenFileGivesItsBytesBackOnceTheProviderHasTheRewrite() async throws {
        // The whole point: 62,675 woken placeholders held locally would be about 926 GB against
        // 1.1 TiB free, so the run has to leave the disk as it found it.
        let writer = SpyWriter()
        var subject = run(writer: writer)
        subject.presence = { _ in .evicted }
        subject.fetch = { _, _ in 20 }
        var given: [String] = []
        subject.evict = { given.append($0) }
        let outcome = await subject.run(entries: [entry("/icloud/a.jpg"), entry("/icloud/b.jpg")],
                                       log: try WriteBackLog(directory: directory))
        XCTAssertEqual(outcome.evicted, 2)
        XCTAssertEqual(outcome.stillLocal, 0)
        XCTAssertEqual(given.sorted(), ["/icloud/a.jpg", "/icloud/b.jpg"])
    }

    func testAFileWhoseBytesWereAlreadyHereIsLeftAlone() async throws {
        // Somebody chose to have that file locally. The run woke it, so the run does not unmake
        // that choice - and measurement found all 1,616 of the OneDrive photographs in this state.
        let writer = SpyWriter()
        var subject = run(writer: writer)
        subject.presence = { _ in .present }
        subject.evict = { XCTFail("gave back \($0), which this run did not wake") }
        let outcome = await subject.run(entries: [entry("/onedrive/a.jpg")],
                                       log: try WriteBackLog(directory: directory))
        XCTAssertEqual(outcome.written, 1)
        XCTAssertEqual(outcome.fetched, 0)
        XCTAssertEqual(outcome.evicted, 0)
    }

    func testANasFileIsNeverEvicted() async throws {
        // It has no provider to give bytes back to, and evicting one would be a delete.
        let writer = SpyWriter()
        var subject = run(writer: writer)
        subject.evict = { XCTFail("gave back \($0), which is not in a cloud provider") }
        let outcome = await subject.run(entries: [entry("/Volumes/Photos/a.RAF")],
                                       log: try WriteBackLog(directory: directory))
        XCTAssertEqual(outcome.written, 1)
        XCTAssertEqual(outcome.evicted, 0)
    }

    func testBytesAreKeptUntilTheProviderHasTakenTheRewrite() async throws {
        // The one thing eviction must never do: drop the only copy of a rewrite. Nothing goes back
        // before `isUploaded` says the provider has it.
        let writer = SpyWriter()
        var subject = run(writer: writer)
        subject.presence = { _ in .evicted }
        subject.fetch = { _, _ in 20 }
        subject.uploaded = { _ in false }
        subject.evict = { XCTFail("gave back \($0) before the provider had the rewrite") }
        let outcome = await subject.run(entries: [entry("/icloud/a.jpg")],
                                       log: try WriteBackLog(directory: directory))
        XCTAssertEqual(outcome.written, 1)
        XCTAssertEqual(outcome.evicted, 0)
        // Reported, not hidden: a run that gave nothing back is a run that fills the disk.
        XCTAssertEqual(outcome.stillLocal, 1)
    }

    func testAFileWaitsItsTurnAndThenGivesItsBytesBack() async throws {
        // Proof that the queue is a queue and not a single missed chance: the provider is not ready
        // when the file is written, and the bytes still go back.
        let writer = SpyWriter()
        var subject = run(writer: writer)
        subject.presence = { _ in .evicted }
        subject.fetch = { _, _ in 20 }
        var asked = 0
        subject.uploaded = { _ in asked += 1; return asked > 3 }
        var given: [String] = []
        subject.evict = { given.append($0) }
        let outcome = await subject.run(entries: [entry("/icloud/a.jpg")],
                                       log: try WriteBackLog(directory: directory))
        XCTAssertEqual(given, ["/icloud/a.jpg"])
        XCTAssertEqual(outcome.evicted, 1)
        XCTAssertEqual(outcome.stillLocal, 0)
    }

    func testOneStuckUploadDoesNotHoldUpTheRest() async throws {
        // Why the eviction is deferred instead of done in the lane that wrote the file: waiting
        // there would make one slow upload everybody's problem, and the run takes days already.
        let writer = SpyWriter()
        var subject = run(writer: writer)
        subject.presence = { _ in .evicted }
        subject.fetch = { _, _ in 20 }
        subject.uploaded = { $0 != "/icloud/stuck.jpg" }
        subject.evict = { _ in }
        let entries = [entry("/icloud/stuck.jpg"), entry("/icloud/b.jpg"), entry("/icloud/c.jpg")]
        let outcome = await subject.run(entries: entries,
                                       log: try WriteBackLog(directory: directory))
        XCTAssertEqual(outcome.written, 3)
        XCTAssertEqual(outcome.evicted, 2)
        XCTAssertEqual(outcome.stillLocal, 1)
    }

    func testARefusedEvictionIsNotAFailedPhotograph() async throws {
        // The photograph has its words and the provider has them too. What is left is room on a
        // disk, which is not worth failing a run over and must not count towards giving up.
        let writer = SpyWriter()
        var subject = run(writer: writer)
        subject.presence = { _ in .evicted }
        subject.fetch = { _, _ in 20 }
        subject.evict = { _ in throw CocoaError(.fileWriteNoPermission) }
        let outcome = await subject.run(entries: [entry("/icloud/a.jpg")],
                                       log: try WriteBackLog(directory: directory))
        XCTAssertEqual(outcome.written, 1)
        XCTAssertEqual(outcome.failed, 0)
        XCTAssertEqual(outcome.evicted, 0)
        XCTAssertEqual(outcome.stillLocal, 1)
        // Logged as done, so a resume does not rewrite it for the sake of some local bytes.
        XCTAssertEqual(try WriteBackLog.alreadyWritten(in: directory), ["/icloud/a.jpg"])
    }

    func testNothingIsAskedForInTheMomentAfterTheWrite() async throws {
        // The measured root cause of an eviction step that gave nothing back: `isUploaded` still
        // describes the file as it was before the write for about 0.4 s afterwards, so an eviction
        // asked for immediately is asked for on a stale answer, and the provider refuses it.
        let writer = SpyWriter()
        var subject = run(writer: writer)
        subject.presence = { _ in .evicted }
        subject.fetch = { _, _ in 20 }
        let clock = Clock()
        subject.now = { clock.value }
        subject.pause = { clock.advance(Double($0)) }
        var askedAt: [Double] = []
        subject.uploaded = { _ in askedAt.append(clock.elapsed); return true }
        let outcome = await subject.run(entries: [entry("/icloud/a.jpg")],
                                       log: try WriteBackLog(directory: directory))
        XCTAssertEqual(outcome.evicted, 1)
        XCTAssertFalse(askedAt.isEmpty)
        XCTAssertGreaterThanOrEqual(askedAt.first ?? 0, WriteBackRun.graceSeconds)
    }

    func testARefusalMeansNotYetAndTheFileIsAskedAgain() async throws {
        // The other half of the same defect: a refused eviction used to drop the file from the queue,
        // so the one attempt made inside the stale window was the only attempt ever made.
        let writer = SpyWriter()
        var subject = run(writer: writer)
        subject.presence = { _ in .evicted }
        subject.fetch = { _, _ in 20 }
        var attempts = 0
        subject.evict = { _ in
            attempts += 1
            if attempts < 3 { throw CocoaError(.fileWriteNoPermission) }
        }
        let outcome = await subject.run(entries: [entry("/icloud/a.jpg")],
                                       log: try WriteBackLog(directory: directory))
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(outcome.evicted, 1)
        XCTAssertEqual(outcome.stillLocal, 0)
    }

    func testARefusalToTheLastIsReportedAndNotSwallowed() async throws {
        // A silent refusal is what let a completely broken step look like a working one.
        let writer = SpyWriter()
        var subject = run(writer: writer)
        subject.presence = { _ in .evicted }
        subject.fetch = { _, _ in 20 }
        subject.evict = { _ in throw CocoaError(.fileWriteNoPermission) }
        let outcome = await subject.run(entries: [entry("/icloud/a.jpg")],
                                       log: try WriteBackLog(directory: directory))
        XCTAssertEqual(outcome.evicted, 0)
        XCTAssertEqual(outcome.stillLocal, 1)
        XCTAssertNotNil(outcome.refusal)
    }

    func testKeepLocalHandsNothingBackAtAll() async throws {
        // The batched workflow: the index chain has to read these files, and `hash` skips an evicted
        // one as dataless. Measured - 24 files cost 0.65 s to hash while local and 51.9 s after.
        let writer = SpyWriter()
        var subject = run(writer: writer)
        subject.keepLocal = true
        subject.presence = { _ in .evicted }
        subject.fetch = { _, _ in 20 }
        subject.uploaded = { _ in XCTFail("asked about an upload on a keep-local run"); return false }
        subject.evict = { XCTFail("gave back \($0) on a keep-local run") }
        let outcome = await subject.run(entries: [entry("/icloud/a.jpg"), entry("/icloud/b.jpg")],
                                       log: try WriteBackLog(directory: directory))
        XCTAssertEqual(outcome.written, 2)
        XCTAssertEqual(outcome.fetched, 2)
        XCTAssertEqual(outcome.evicted, 0)
        // Not counted as left behind either: nothing was promised and nothing went wrong.
        XCTAssertEqual(outcome.stillLocal, 0)
    }

    // MARK: - helpers

    private func run(writer: WriteBackWriter, quiet: QuietHours = .none,
                     dryRun: Bool = false) -> WriteBackRun {
        var subject = WriteBackRun(writer: writer, quiet: quiet, dryRun: dryRun)
        subject.exists = { _ in true }
        // Every test path is the NAS unless a test says otherwise, which is what the real run sees
        // for 142,566 of its 207,713 photographs.
        subject.presence = { _ in .notCloud }
        subject.fetch = { path, _ in
            XCTFail("fetched \(path), which is not in a cloud provider")
            return 0
        }
        // A provider that has already taken everything, so a test that is not about eviction
        // drains its queue at once instead of sitting out the settling wait.
        subject.uploaded = { _ in true }
        subject.evict = { _ in }
        subject.say = { _ in }
        // The grace after a write and the settling wait at the end are both measured in real
        // seconds, so the clock is driven by the pauses rather than by the wall.
        let clock = Clock()
        subject.now = { clock.value }
        subject.pause = { clock.advance(Double($0)) }
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
