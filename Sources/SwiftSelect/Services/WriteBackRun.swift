import Foundation
import SwiftSelectCore

/// What the write-back run needs of a writer, which is less than `MetadataWriter` offers and one
/// thing more: an allowance that scales with the file. Narrower on purpose - the run writes no
/// title and no GPS, and `NativeMetadataWriter` has no process to time out, so a timeout has no
/// place in the shared protocol.
protocol WriteBackWriter {
    func writeBack(description: String, keywords: [String],
                   timeoutSeconds: Double, to url: URL) async throws
}

extension ExifToolClient: WriteBackWriter {
    func writeBack(description: String, keywords: [String],
                   timeoutSeconds: Double, to url: URL) async throws {
        // Deliberately not the batched overload. A batch shares one exiftool invocation and one
        // set of values, and here every photograph has its own description.
        try await write(title: nil, description: description, keywords: keywords, gps: nil,
                        timeoutSeconds: timeoutSeconds, to: url)
    }
}

/// Writes the captions the photo index holds back into the photographs themselves.
///
/// The work list comes from `swiftphotolog writeback` and every value in it was read long ago, so
/// this run reads nothing from the index and talks to nothing but the files. Two things make it
/// survivable across the days it takes: the done log is appended to after each photograph, so a
/// killed run resumes having lost only the files in flight, and it stops itself rather than pressing
/// on when the volume stops answering.
struct WriteBackRun {
    struct Outcome: Equatable {
        var written = 0
        var failed = 0
        var missing = 0
        /// Why the run stopped early, or nil if it reached the end of the list.
        var stopped: String?
    }

    /// Completions in a row that mean the volume has gone rather than the file being bad. The share
    /// has dropped mid-run before, and the failure mode to avoid is a run that logs 40,000 failures
    /// to an unmounted path and reports itself finished. A handful of scattered stale entries - a
    /// file `refile` moved since the manifest was made - will not reach this.
    static let givingUpAfter = 10

    let writer: WriteBackWriter
    let quiet: QuietHours
    let dryRun: Bool

    /// How many photographs to have in flight at once.
    ///
    /// One is the default because one is all a wireless run can use. Measured against the NAS over
    /// Wi-Fi: four parallel reads of 58 MB RAFs aggregated 16.11 MB/s where a single stream managed
    /// 14.25, a 13% gain, because the link is the wall and not the waiting. The same measurement
    /// found a fixed cost of about 0.45 s per photograph - exiftool spawning, and the SMB open,
    /// stat, write and rename round-trips - which is noise against the 7 s a 58 MB RAF spends in
    /// transit at 16 MB/s.
    ///
    /// On a wired link that reverses. At gigabit the same RAF is about half a second of transfer
    /// against the same 0.45 s of stalling, so half the run is waiting and lanes are what reclaim
    /// it. This exists for the wired run, and turning it up on Wi-Fi buys almost nothing.
    var workers = 1

    var now: () -> Date = Date.init
    var pause: (Int) async -> Void = { seconds in
        try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
    }
    var exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    /// Flushed on every line: block buffering makes a four-hour quiet-hours pause look exactly
    /// like a stalled run, which has cost a session before.
    var say: (String) -> Void = { line in
        print(line)
        fflush(stdout)
    }

    /// What one lane hands back. The workers do nothing but call exiftool: every count and every
    /// log line is written by the consuming loop in `run`, which is one task, so the two logs stay
    /// append-ordered and `WriteBackLog` needs no lock of its own.
    private enum Attempt {
        case wrote(WriteBackEntry)
        case failed(WriteBackEntry, String)
        case notThere(WriteBackEntry)
    }

    func run(entries: [WriteBackEntry], log: WriteBackLog, limit: Int? = nil) async -> Outcome {
        var outcome = Outcome()
        var consecutiveTrouble = 0
        var lastTroubleWasMissing = false
        var completed = 0
        let todo = limit.map { Array(entries.prefix($0)) } ?? entries
        let lanes = max(1, workers)

        await withTaskGroup(of: Attempt.self) { group in
            var next = todo.makeIterator()
            var dispatching = true

            for _ in 0..<lanes {
                guard let entry = next.next() else { break }
                await waitOutQuietHours()
                group.addTask { [self] in await attempt(entry) }
            }

            while let result = await group.next() {
                completed += 1
                switch result {
                case let .wrote(entry):
                    // Logged only on success, and by this loop alone: the log is both the resume
                    // point and the record the index re-keys each photograph's vector from.
                    if !dryRun { log.done(entry, at: now()) }
                    outcome.written += 1
                    consecutiveTrouble = 0
                case let .failed(entry, reason):
                    outcome.failed += 1
                    consecutiveTrouble += 1
                    lastTroubleWasMissing = false
                    log.failed(entry, reason: reason)
                case let .notThere(entry):
                    outcome.missing += 1
                    consecutiveTrouble += 1
                    lastTroubleWasMissing = true
                    log.failed(entry, reason: "not there")
                }

                if dispatching, consecutiveTrouble >= Self.givingUpAfter {
                    // Stop starting work, but let the lanes already in flight finish and be logged.
                    // Cutting an exiftool write short is not a thing to do to a photograph, and a
                    // write that completed is work the resume set should not have to repeat.
                    dispatching = false
                    outcome.stopped = lastTroubleWasMissing
                        ? "\(consecutiveTrouble) files in a row were not there - "
                            + "the volume has probably gone. Nothing lost: run again to resume."
                        : "\(consecutiveTrouble) failures in a row - stopping rather "
                            + "than working through the whole list. Run again to resume."
                    say(outcome.stopped!)
                }

                if completed % 100 == 0 {
                    say("  \(outcome.written) written of \(todo.count)"
                        + (outcome.failed + outcome.missing > 0
                           ? "  (\(outcome.failed) failed, \(outcome.missing) not there)" : ""))
                }

                guard dispatching, let entry = next.next() else { continue }
                await waitOutQuietHours()
                group.addTask { [self] in await attempt(entry) }
            }
        }
        return outcome
    }

    private func attempt(_ entry: WriteBackEntry) async -> Attempt {
        guard exists(entry.path) else { return .notThere(entry) }
        guard !dryRun else { return .wrote(entry) }
        do {
            try await writer.writeBack(
                description: entry.description,
                keywords: MetadataWriteFieldRules.normalizedKeywords(entry.keywords),
                timeoutSeconds: WriteBackPlan.timeoutSeconds(bytes: entry.bytes),
                to: URL(fileURLWithPath: entry.path))
            return .wrote(entry)
        } catch {
            return .failed(entry, String(describing: error).prefix(300).description)
        }
    }

    /// Waited out in the consuming loop rather than inside a lane, so a pause stops new work
    /// starting without interrupting a photograph already being rewritten.
    private func waitOutQuietHours() async {
        let seconds = quiet.resumeInSeconds(at: now())
        guard seconds > 0 else { return }
        say("quiet hours: pausing \(seconds / 60) minutes, back at "
            + Self.clockFormatter.string(from: now().addingTimeInterval(Double(seconds))))
        await pause(seconds)
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
