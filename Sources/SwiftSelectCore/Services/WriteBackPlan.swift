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
