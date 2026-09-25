import Foundation

/// One line of the manifest `swiftphotolog writeback` emits: a photograph whose description and
/// keywords exist in that index and nowhere a reader of the file can see them.
///
/// `bytes` is carried by the manifest rather than stat'd here because the run is pointed at an SMB
/// mount, where a stat is a round trip and the index already knows the answer. See
/// `WriteBackPlan.timeoutSeconds(bytes:)` for what it is for.
public struct WriteBackEntry: Codable, Equatable {
    public let path: String
    public let hash: String
    public let bytes: Int
    public let description: String
    public let keywords: [String]

    public init(path: String, hash: String, bytes: Int, description: String, keywords: [String]) {
        self.path = path
        self.hash = hash
        self.bytes = bytes
        self.description = description
        self.keywords = keywords
    }
}

/// The decisions a write-back run makes that have a silent failure mode, kept pure and out of the
/// runner for the same reason `BatchAISuggestionTargets` is: skipping a photograph, or timing one
/// out that was merely large, is invisible until thousands of files have gone past.
public enum WriteBackPlan {
    /// Decodes one JSONL line. Returns nil for a blank line so a trailing newline is not an error.
    public static func entry(from line: String) throws -> WriteBackEntry? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return try JSONDecoder().decode(WriteBackEntry.self, from: Data(trimmed.utf8))
    }

    /// How long to allow exiftool for one file.
    ///
    /// exiftool rewrites a file by copying it, so the cost is a full read plus a full write of every
    /// byte — over a Wi-Fi SMB mount that is the whole of the time, not a detail. The app's own 12 s
    /// per-file timeout was measured against local files and is kept as the floor for exiftool's
    /// startup and parsing; above that the allowance scales with size, or every 117 MB DNG on the
    /// NAS times out on a link that was doing exactly what it should.
    ///
    /// `margin` is threefold because the measured 19 MB/s is an average over a long run, not a
    /// guarantee for one file: the share is shared with everything else in the house.
    public static func timeoutSeconds(
        bytes: Int, megabytesPerSecond: Double = 19, margin: Double = 3, floor: Double = 12
    ) -> Double {
        let megabytes = Double(bytes) / (1024 * 1024)
        return max(floor, (megabytes * 2 / megabytesPerSecond) * margin)
    }

    /// How long to allow a cloud provider to hand over an evicted file, before exiftool starts.
    ///
    /// Deliberately not `timeoutSeconds`. That one scales with the file because it is paying for
    /// bytes over SMB; this one barely scales at all, because fetching a placeholder was measured to
    /// cost the same 12.8 to 26.8 seconds whether the file was 2 MB or 48 MB - it is a round trip to
    /// the provider, not a transfer. A flat floor generous enough for the slowest observed fetch is
    /// therefore the right shape, with a small size term so a 117 MB DNG is not held to a figure
    /// measured on files a fortieth of its size.
    ///
    /// The floor is 90 s against a 26.8 s worst case measured at 8 lanes. That is deliberately fat:
    /// the fetch competes with every other lane for one provider, the run is unattended for days,
    /// and the cost of being wrong in this direction is one slow file where the cost of being wrong
    /// in the other is a photograph logged as failed that was merely queued.
    public static func fetchTimeoutSeconds(
        bytes: Int, megabytesPerSecond: Double = 4, floor: Double = 90
    ) -> Double {
        let megabytes = Double(bytes) / (1024 * 1024)
        return max(floor, megabytes / megabytesPerSecond)
    }

    /// The entries still to do, in manifest order, given the paths a previous run finished.
    ///
    /// Keyed by path rather than hash on purpose, and it is the one place in either project where
    /// that is right: the write changes the file, so the hash in the manifest is the hash of the
    /// photograph *before* it was written and will never be seen on disk again. The path is what
    /// survives the operation.
    public static func remaining(
        entries: [WriteBackEntry], done: Set<String>
    ) -> [WriteBackEntry] {
        entries.filter { !done.contains($0.path) }
    }
}

/// Windows in which the run must not touch the NAS, mirroring the backend's `pacing.py` so the two
/// projects cannot disagree about what "quiet" means. A window is `HH:MM-HH:MM` in local time,
/// comma-separated, half-open `[start, end)`, and one whose end precedes its start wraps midnight.
public struct QuietHours: Equatable {
    /// Minutes since midnight.
    public struct Window: Equatable {
        public let start: Int
        public let end: Int
    }

    public let windows: [Window]

    /// No restriction. The run is pointed at the NAS by default, so the quiet spec is normally
    /// given - this is for a run against a local copy, and for tests about something else.
    public static let none = QuietHours(windows: [])

    private init(windows: [Window]) {
        self.windows = windows
    }

    /// An empty or whitespace-only spec means no restriction, matching `pacing.parse`.
    public init(_ spec: String?) throws {
        guard let spec, !spec.trimmingCharacters(in: .whitespaces).isEmpty else {
            windows = []
            return
        }
        windows = try spec.split(separator: ",").compactMap { part in
            let text = part.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            let halves = text.split(separator: "-", maxSplits: 1)
            guard halves.count == 2 else { throw QuietHoursError.notAWindow(text) }
            return Window(start: try Self.minutes(String(halves[0])),
                          end: try Self.minutes(String(halves[1])))
        }
    }

    private static func minutes(_ hhmm: String) throws -> Int {
        let parts = hhmm.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard (1...2).contains(parts.count), let hours = Int(parts[0]) else {
            throw QuietHoursError.notATime(hhmm)
        }
        guard let mins = parts.count == 2 ? Int(parts[1]) : 0 else {
            throw QuietHoursError.notATime(hhmm)
        }
        // Stricter than the backend on purpose: `pacing._minutes` checks only the total against
        // 1440, so it reads "21:99" as 22:39 and runs against a window nobody wrote. The spec is
        // typed by hand into .env and guards the NAS, so a typo should stop the run, not shift it.
        guard (0..<24).contains(hours), (0..<60).contains(mins) else {
            throw QuietHoursError.notATime(hhmm)
        }
        return hours * 60 + mins
    }

    /// Seconds to wait before work may continue; 0 means go. A duration rather than a boolean, so
    /// the caller is one sleep with no polling loop and the decision is testable without a clock.
    public func resumeInSeconds(at date: Date, calendar: Calendar = .current) -> Int {
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        for window in windows {
            let inside = window.start < window.end
                ? (minute >= window.start && minute < window.end)
                : (minute >= window.start || minute < window.end)
            guard inside else { continue }
            let remaining = ((window.end - minute) % 1440 + 1440) % 1440
            return remaining * 60 - (parts.second ?? 0)
        }
        return 0
    }
}

public enum QuietHoursError: Error, Equatable {
    case notAWindow(String)
    case notATime(String)
}

/// The headless run's arguments. Parsing is here rather than in the entry point so the rules are
/// testable without launching anything: an entry point that has already decided to run headless
/// cannot then be asked what it would have decided.
public struct WriteBackOptions: Equatable {
    /// argv[1] that means "do not open a window".
    public static let verb = "writeback"

    public let manifest: String
    /// Where the done and failed logs go. The done log is the evidence the index re-keys vectors
    /// from, so it is an argument, not a temporary file.
    public let logDirectory: String
    public let quiet: String?
    public let dryRun: Bool
    public let limit: Int?
    /// Photographs in flight at once. One unless asked, because on Wi-Fi lanes buy 13% and on a
    /// wire they buy about half the run - see `WriteBackRun.workers`.
    public let workers: Int

    public init(manifest: String, logDirectory: String, quiet: String? = nil,
                dryRun: Bool = false, limit: Int? = nil, workers: Int = 1) {
        self.manifest = manifest
        self.logDirectory = logDirectory
        self.quiet = quiet
        self.dryRun = dryRun
        self.limit = limit
        self.workers = workers
    }

    /// nil when this is an ordinary launch - a double-clicked .app gets argv it never asked for,
    /// so anything that is not the verb has to mean "open the window" rather than "bad arguments".
    public static func parse(arguments: [String]) throws -> WriteBackOptions? {
        guard arguments.count > 1, arguments[1] == verb else { return nil }

        var values: [String: String] = [:]
        var dryRun = false
        var index = 2
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--dry-run":
                dryRun = true
                index += 1
            case "--manifest", "--log", "--quiet", "--limit", "--workers":
                guard index + 1 < arguments.count else {
                    throw WriteBackOptionsError.missingValue(argument)
                }
                values[argument] = arguments[index + 1]
                index += 2
            default:
                throw WriteBackOptionsError.unknownArgument(argument)
            }
        }

        guard let manifest = values["--manifest"] else {
            throw WriteBackOptionsError.missingValue("--manifest")
        }
        guard let log = values["--log"] else {
            throw WriteBackOptionsError.missingValue("--log")
        }
        var limit: Int?
        if let text = values["--limit"] {
            guard let value = Int(text), value > 0 else {
                throw WriteBackOptionsError.notACount(text)
            }
            limit = value
        }
        var workers = 1
        if let text = values["--workers"] {
            guard let value = Int(text), value > 0 else {
                throw WriteBackOptionsError.notACount(text)
            }
            workers = value
        }
        return WriteBackOptions(manifest: manifest, logDirectory: log,
                                quiet: values["--quiet"], dryRun: dryRun, limit: limit,
                                workers: workers)
    }

    public static let usage = """
        usage: SwiftSelect writeback --manifest FILE --log DIR [--quiet SPEC] [--limit N]
                                    [--workers N] [--dry-run]

          --manifest  the JSONL from `swiftphotolog writeback`
          --log       directory for writeback-done.jsonl and writeback-failed.jsonl
          --quiet     windows to stay off the NAS in, e.g. 07:00-08:30,17:00-21:30
          --limit     stop after N photographs, for a first run against a few
          --workers   photographs in flight at once, default 1. Worth turning up on a wired
                      link and not on Wi-Fi, where the link is the wall
          --dry-run   say what would be written and write nothing
        """
}

public enum WriteBackOptionsError: Error, Equatable {
    case missingValue(String)
    case unknownArgument(String)
    case notACount(String)
}
