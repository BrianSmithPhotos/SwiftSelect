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
/// killed run resumes having lost only the file in flight, and it stops itself rather than pressing
/// on when the volume stops answering.
struct WriteBackRun {
    struct Outcome: Equatable {
        var written = 0
        var failed = 0
        var missing = 0
        /// Why the run stopped early, or nil if it reached the end of the list.
        var stopped: String?
    }

    /// Consecutive failures that mean the volume has gone rather than the file being bad. The share
    /// has dropped mid-run before, and the failure mode to avoid is a run that logs 40,000 failures
    /// to an unmounted path and reports itself finished. A handful of scattered stale entries - a
    /// file `refile` moved since the manifest was made - will not reach this.
    static let givingUpAfter = 10

    let writer: WriteBackWriter
    let quiet: QuietHours
    let dryRun: Bool
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

    func run(entries: [WriteBackEntry], log: WriteBackLog, limit: Int? = nil) async -> Outcome {
        var outcome = Outcome()
        var consecutiveFailures = 0
        let todo = limit.map { Array(entries.prefix($0)) } ?? entries

        for (offset, entry) in todo.enumerated() {
            await waitOutQuietHours()

            guard exists(entry.path) else {
                outcome.missing += 1
                consecutiveFailures += 1
                log.failed(entry, reason: "not there")
                if consecutiveFailures >= Self.givingUpAfter {
                    outcome.stopped = "\(consecutiveFailures) files in a row were not there - "
                        + "the volume has probably gone. Nothing lost: run again to resume."
                    say(outcome.stopped!)
                    return outcome
                }
                continue
            }

            if dryRun {
                outcome.written += 1
                consecutiveFailures = 0
                continue
            }

            do {
                try await writer.writeBack(
                    description: entry.description,
                    keywords: MetadataWriteFieldRules.normalizedKeywords(entry.keywords),
                    timeoutSeconds: WriteBackPlan.timeoutSeconds(bytes: entry.bytes),
                    to: URL(fileURLWithPath: entry.path))
                // Logged only on success, and before the next file is touched: the log is both the
                // resume point and the record the index re-keys each photograph's vector from.
                log.done(entry, at: now())
                outcome.written += 1
                consecutiveFailures = 0
            } catch {
                outcome.failed += 1
                consecutiveFailures += 1
                log.failed(entry, reason: String(describing: error).prefix(300).description)
                if consecutiveFailures >= Self.givingUpAfter {
                    outcome.stopped = "\(consecutiveFailures) failures in a row - stopping rather "
                        + "than working through the whole list. Run again to resume."
                    say(outcome.stopped!)
                    return outcome
                }
            }

            if (offset + 1) % 100 == 0 {
                say("  \(outcome.written) written of \(todo.count)"
                    + (outcome.failed + outcome.missing > 0
                       ? "  (\(outcome.failed) failed, \(outcome.missing) not there)" : ""))
            }
        }
        return outcome
    }

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
