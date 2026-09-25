import Foundation
import SwiftSelectCore

/// The headless write-back: everything between the arguments and the runner.
///
/// Pointed at the photo index's manifest, it writes each caption the index holds into the
/// photograph itself, so anything that opens the file - Lightroom, DxO, an export, another copy of
/// this app - sees the words too. It opens no window and reads no database.
enum WriteBackCommand {
    static func run(_ options: WriteBackOptions) async -> Int32 {
        func say(_ line: String) {
            print(line)
            fflush(stdout)
        }

        let quiet: QuietHours
        do {
            quiet = try QuietHours(options.quiet)
        } catch {
            complain("not a quiet-hours spec: \(options.quiet ?? "")")
            return 2
        }

        let logDirectory = URL(fileURLWithPath: (options.logDirectory as NSString).expandingTildeInPath)
        let entries: [WriteBackEntry]
        let done: Set<String>
        let log: WriteBackLog
        do {
            entries = try WriteBackManifest.read(
                URL(fileURLWithPath: (options.manifest as NSString).expandingTildeInPath))
            done = try WriteBackLog.alreadyWritten(in: logDirectory)
            log = try WriteBackLog(directory: logDirectory)
        } catch {
            complain(String(describing: error))
            return 1
        }
        defer { log.close() }

        let todo = WriteBackPlan.remaining(entries: entries, done: done)
        let bytes = todo.reduce(0) { $0 + $1.bytes }
        say("\(entries.count) photographs in the manifest, \(done.count) already written")
        say("\(todo.count) to write, \(gibibytes(bytes)) - and the same again read back, "
            + "because exiftool rewrites a file rather than editing it")
        if let limit = options.limit { say("stopping after \(limit), as asked") }
        if options.workers > 1 { say("\(options.workers) photographs in flight at once") }
        if !quiet.windows.isEmpty { say("quiet hours: \(options.quiet ?? "")") }
        if options.dryRun { say("dry run: nothing will be written") }
        guard !todo.isEmpty else {
            say("nothing to do")
            return 0
        }

        let run = WriteBackRun(writer: ExifToolClient(), quiet: quiet, dryRun: options.dryRun,
                               workers: options.workers)
        let outcome = await run.run(entries: todo, log: log, limit: options.limit)

        say("")
        say("\(options.dryRun ? "would have written" : "written") \(outcome.written), "
            + "failed \(outcome.failed), not there \(outcome.missing)")
        if outcome.failed + outcome.missing > 0 {
            say("failures listed in \(logDirectory.appendingPathComponent(WriteBackLog.failedName).path)")
        }
        if !options.dryRun {
            say("each write changed the file, so its hash has changed. "
                + WriteBackLog.doneName + " maps every photograph to the hash it had before, "
                + "which is what the index needs to carry its vector and thumbnails across.")
        }
        return outcome.stopped == nil ? 0 : 1
    }

    static func complain(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private static func gibibytes(_ bytes: Int) -> String {
        String(format: "%.1f GiB", Double(bytes) / 1024 / 1024 / 1024)
    }
}
