import Foundation
import SwiftSelectCore

enum ExifToolError: Error, LocalizedError {
    case processFailed(status: Int32, stderr: String)
    case invalidOutput
    case timedOut

    /// Without this, `localizedDescription` on a plain `Error` renders as Foundation's
    /// "The operation couldn't be completed. (SwiftSelect.ExifToolError error 0.)" — which is
    /// what every caller that reports a save failure was showing, throwing away a `stderr` that
    /// already said exactly what was wrong.
    ///
    /// exiftool puts its `Error:`/`Warning:` lines on stderr and its "N image files updated" tally
    /// on stdout, so stderr is the diagnosis. Only the first line is used: a batch write reports one
    /// error per file, and they are near-always the same cause repeated.
    var errorDescription: String? {
        switch self {
        case .processFailed(let status, let stderr):
            let firstLine = stderr
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty }
            return firstLine ?? "exiftool exited with status \(status)"
        case .invalidOutput:
            return "exiftool returned output that could not be read"
        case .timedOut:
            return "exiftool timed out"
        }
    }
}

/// Thin wrapper around the `exiftool` binary. All EXIF/IPTC/XMP read/write goes through here —
/// no hand-rolled metadata parsing. See docs/ARCHITECTURE.md "exiftool integration".
struct ExifToolClient: MetadataWriter {
    /// `-j -G1 -a -s` matches the reference app's read command: JSON output, grouped tag names,
    /// duplicate tags allowed, short tag names. See docs/SPEC.md §2.
    private static let readArguments = ["-j", "-G1", "-a", "-s"]

    /// Reads full metadata for one file as exiftool's raw JSON object (one entry per requested tag
    /// group). Field-mapping to `PhotoAsset` happens one layer up.
    func readMetadata(at url: URL) async throws -> [String: Any] {
        let output = try await run(arguments: Self.readArguments + [url.path])
        guard let array = try JSONSerialization.jsonObject(with: output) as? [[String: Any]],
              let first = array.first
        else {
            throw ExifToolError.invalidOutput
        }
        return first
    }

    /// Requests below this size are read in one exiftool invocation; larger batches are split so
    /// one invocation's runtime/output stays bounded for large import sessions.
    private static let readChunkSize = 50

    /// Reads full metadata for many files, batching them into as few exiftool invocations as
    /// possible. exiftool's cost per invocation is dominated by process/Perl-interpreter startup
    /// rather than the actual file read, so reading N files one at a time is roughly N times
    /// slower than reading them together.
    ///
    /// Each URL maps to either its metadata dictionary or the error that occurred reading it, so
    /// one unreadable or slow file in a chunk falls back to an individual `readMetadata(at:)`
    /// retry instead of failing every other file batched alongside it.
    func readMetadata(at urls: [URL]) async throws -> [URL: Result<[String: Any], Error>] {
        var results: [URL: Result<[String: Any], Error>] = [:]
        for chunk in stride(from: 0, to: urls.count, by: Self.readChunkSize).map({
            Array(urls[$0..<min($0 + Self.readChunkSize, urls.count)])
        }) {
            let bySourceFile = (try? await runChunk(chunk)) ?? [:]
            for url in chunk {
                if let match = bySourceFile[url.path] {
                    results[url] = .success(match)
                    continue
                }
                do {
                    results[url] = .success(try await readMetadata(at: url))
                } catch {
                    results[url] = .failure(error)
                }
            }
        }
        return results
    }

    /// Best-effort batched read for one chunk, keyed by exiftool's `SourceFile` tag. Any URL
    /// missing from the returned dictionary is retried individually by the caller, so this never
    /// throws.
    private func runChunk(_ urls: [URL]) async throws -> [String: [String: Any]] {
        let output = try await run(arguments: Self.readArguments + urls.map(\.path))
        guard let array = try? JSONSerialization.jsonObject(with: output) as? [[String: Any]] else {
            return [:]
        }
        var bySourceFile: [String: [String: Any]] = [:]
        for entry in array {
            if let sourceFile = entry["SourceFile"] as? String {
                bySourceFile[sourceFile] = entry
            }
        }
        return bySourceFile
    }

    /// Only the tags capture-set grouping needs, and `-n` so they come back as the camera's raw
    /// numbers rather than exiftool's prose — `DriveMode`'s shot index and `StackedImage`'s source
    /// frame count only exist in the raw form.
    ///
    /// `-u` is what makes the interval-shooting counter readable at all: exiftool has no name for
    /// Olympus CameraSettings `0x0605` and suppresses unnamed tags without it.
    ///
    /// `Caption-Abstract` rides along because ImageIO reads it back empty on camera-original
    /// JPEGs, and this pass already visits every file at folder load.
    private static let groupingArguments = [
        "-j", "-s", "-n", "-u",
        "-DriveMode", "-Olympus_CameraSettings_0x0605", "-StackedImage",
        "-ArtFilterEffect", "-PictureMode", "-ExposureCompensation", "-Caption-Abstract",
    ]

    /// Five tags is a fraction of a full read's output, so this runs in much larger chunks than
    /// `readMetadata(at:)` — a folder of several hundred frames costs only a handful of launches.
    private static let groupingChunkSize = 250

    /// What one folder-load pass learns about each file: the maker-note signals
    /// `CaptureGroupingService` groups by, and any non-empty caption.
    struct FolderScan {
        var signals: [URL: CaptureSignals] = [:]
        var captions: [URL: String] = [:]
    }

    /// Reads a whole folder's `FolderScan` at once.
    ///
    /// Best-effort throughout: a file exiftool couldn't read is simply absent from the result, and
    /// grouping falls back to the timestamp gap for it. There is no per-file retry the way
    /// `readMetadata(at:)` has one — a missing signal degrades grouping, it doesn't fail a save.
    func readFolderScan(at urls: [URL]) async throws -> FolderScan {
        var scan = FolderScan()
        for chunk in stride(from: 0, to: urls.count, by: Self.groupingChunkSize).map({
            Array(urls[$0..<min($0 + Self.groupingChunkSize, urls.count)])
        }) {
            guard let output = try? await run(arguments: Self.groupingArguments + chunk.map(\.path)),
                let entries = try? JSONSerialization.jsonObject(with: output) as? [[String: Any]]
            else { continue }
            for entry in entries {
                guard let sourceFile = entry["SourceFile"] as? String else { continue }
                let url = URL(fileURLWithPath: sourceFile)
                scan.signals[url] = Self.groupingSignals(from: entry)
                let caption = Self.text(entry["Caption-Abstract"])
                if !caption.isEmpty { scan.captions[url] = caption }
            }
        }
        return scan
    }

    static func groupingSignals(from entry: [String: Any]) -> CaptureSignals {
        CaptureSignals.grouping(
            driveMode: numbers(entry["DriveMode"]),
            intervalCounter: numbers(entry["Olympus_CameraSettings_0x0605"]),
            stackedImage: numbers(entry["StackedImage"]),
            render: [
                CaptureSignals.artFilterEffect(numbers(entry["ArtFilterEffect"])),
                text(entry["PictureMode"]), text(entry["ExposureCompensation"]),
            ])
    }

    private static func numbers(_ value: Any?) -> [Int] {
        if let number = value as? NSNumber { return [number.intValue] }
        guard let string = value as? String else { return [] }
        return string.split(separator: " ").compactMap { Int($0) }
    }

    private static func text(_ value: Any?) -> String {
        switch value {
        case let string as String: return string
        case let number as NSNumber: return number.stringValue
        default: return ""
        }
    }

    /// Writes title/description/keywords/GPS to a single file. `title` is per-file-unique (it's
    /// usually rename-derived), so it's only exposed here, never in the batched overload below —
    /// see docs/SPEC.md §3.
    ///
    /// Relies on exiftool's own automatic `<path>_original` backup rather than `-overwrite_original`:
    /// on success the backup is deleted; on failure the backup is restored over the (possibly
    /// half-written) file so the write is all-or-nothing from the caller's perspective.
    func write(
        title: String?, description: String, keywords: [String], gps: GPSCoordinate?,
        subjectDistance: Double? = nil, instructions: String? = nil, to url: URL
    ) async throws {
        try await write(title: title, description: description, keywords: keywords, gps: gps,
                        subjectDistance: subjectDistance, instructions: instructions,
                        timeoutSeconds: Self.singleFileTimeout, to: url)
    }

    /// The same write with the allowance named rather than fixed. An overload rather than a
    /// defaulted parameter because the plain signature above is the `MetadataWriter` witness, and
    /// Swift matches a protocol requirement on the exact signature.
    ///
    /// The fixed 12 s is right for a local file, where the cost is exiftool starting up. It is not
    /// right over SMB: exiftool rewrites a file by copying it, so a full read and a full write
    /// cross the link, and 26,033 of the photo index's 57,071 captioned files need longer than 12 s
    /// on that arithmetic alone. See `WriteBackPlan.timeoutSeconds(bytes:)`.
    func write(
        title: String?, description: String, keywords: [String], gps: GPSCoordinate?,
        subjectDistance: Double? = nil, instructions: String? = nil,
        timeoutSeconds: Double, to url: URL
    ) async throws {
        try MetadataWriteFieldRules.validate(gps: gps)
        let assignments = Self.writeArguments(
            title: title, description: description, keywords: keywords, gps: gps,
            subjectDistance: subjectDistance, instructions: instructions)
        do {
            _ = try await runWrite(assignments: assignments, paths: [url.path],
                                   timeoutSeconds: timeoutSeconds)
            cleanupBackup(for: url)
        } catch {
            restoreBackupIfPresent(for: url)
            throw error
        }
    }

    /// Writes the same description/keywords/GPS to every file in `urls` in one exiftool invocation
    /// — the batching optimization from docs/ARCHITECTURE.md "exiftool integration". Grouping files
    /// by identical target values is the caller's job (e.g. a capture-set save); this method just
    /// writes whatever list it's given.
    ///
    /// exiftool's exit code reflects the whole invocation, not which of several files in it
    /// succeeded (confirmed empirically: a batch with one bad path among good ones still writes the
    /// good ones but exits non-zero). So on any failure this restores every file's backup — even
    /// ones exiftool did manage to write — rather than guessing which succeeded, then retries each
    /// file individually so a single bad file doesn't cost the whole group its write.
    func write(description: String, keywords: [String], gps: GPSCoordinate?, to urls: [URL]) async throws -> [URL: Result<Void, Error>] {
        try MetadataWriteFieldRules.validate(gps: gps)
        guard !urls.isEmpty else { return [:] }

        let assignments = Self.writeArguments(
            title: nil, description: description, keywords: keywords, gps: gps, subjectDistance: nil,
            instructions: nil)
        do {
            _ = try await runWrite(assignments: assignments, paths: urls.map(\.path),
                                   timeoutSeconds: Self.batchTimeoutPerFile * Double(urls.count))
            for url in urls { cleanupBackup(for: url) }
            return Dictionary(uniqueKeysWithValues: urls.map { ($0, .success(())) })
        } catch {
            for url in urls { restoreBackupIfPresent(for: url) }
            var results: [URL: Result<Void, Error>] = [:]
            for url in urls {
                do {
                    try await write(title: nil, description: description, keywords: keywords, gps: gps, to: url)
                    results[url] = .success(())
                } catch {
                    results[url] = .failure(error)
                }
            }
            return results
        }
    }

    /// Matches the reference app's per-file/per-file-in-batch timeouts (12s per file) — see
    /// docs/ARCHITECTURE.md "exiftool integration".
    private static let singleFileTimeout: Double = 12
    private static let batchTimeoutPerFile: Double = 12

    /// Builds the `-TAG=value` argv per docs/SPEC.md §3's field->tag table. Keywords are cleared
    /// (blank `-IPTC:Keywords=`/`-XMP-dc:Subject=`) before being rewritten one `-tag=value` pair at
    /// a time — the idempotent way to "replace the keyword list" with exiftool, since its `+=`
    /// append operator would duplicate keywords on every re-save.
    private static func writeArguments(
        title: String?, description: String, keywords: [String], gps: GPSCoordinate?,
        subjectDistance: Double?, instructions: String?
    ) -> [String] {
        // Declare the legacy IIM block UTF-8, first, so everything below it is stored as written.
        // Without this exiftool encodes IIM as cp1252 and anything outside it becomes a literal "?":
        // "ЛЕБЕДКА" came back as "???????" and "Māori" as "M?ori", while the XMP half - which is
        // UTF-8 by definition - held both correctly. IIM carries no charset unless told, so a reader
        // is guessing either way; saying UTF8 is the only answer that is true.
        //
        // The cost is real but not ours to pay. Changing the declared charset makes exiftool
        // re-encode IIM fields this write never touches: a pre-existing City of "Zürich" went from
        // c3bc to fc while the block now claims UTF8, which is mojibake. That is a hazard for files
        // already holding non-ASCII in City, By-line, CopyrightNotice and the like - and the index
        // says there are none. Across all 58,568 photographs queued for write-back, exactly two
        // carry any of those fields at all and both are pure ASCII, which re-encodes to itself.
        // One file already declares UTF8. So this is safe for the library it will be run against,
        // and a file arriving later with a non-ASCII City is the case to re-measure before trusting.
        var arguments: [String] = ["-IPTC:CodedCharacterSet=UTF8"]
        if let title {
            arguments.append("-IPTC:ObjectName=\(title)")
            arguments.append("-XMP-dc:Title=\(title)")
        }
        arguments.append("-IPTC:Caption-Abstract=\(description)")
        arguments.append("-XMP-dc:Description=\(description)")
        // IPTC's accessibility alt text (standard 2021.1) gets the same string: it's the one field
        // in this app whose job is already "describe what's in the picture", which is exactly what
        // alt text is for. Lightroom Classic 12.3+ shows it in its own metadata box, and it's what
        // a WordPress plugin reads to fill the alt attribute. Its sibling ExtDescrAccessibility is
        // deliberately left unwritten — it's for a *longer* description of a complex image, and
        // there's no second source here to fill it with; copying the same text into both would just
        // show duplicate data in tools that display them separately.
        arguments.append("-XMP-iptcCore:AltTextAccessibility=\(description)")

        arguments.append("-IPTC:Keywords=")
        arguments.append("-XMP-dc:Subject=")
        for keyword in MetadataWriteFieldRules.normalizedKeywords(keywords) {
            arguments.append("-IPTC:Keywords=\(keyword)")
            arguments.append("-XMP-dc:Subject=\(keyword)")
        }

        if let gps {
            arguments.append("-GPSLatitude=\(gps.latitude)")
            arguments.append("-GPSLatitudeRef=\(gps.latitude >= 0 ? "N" : "S")")
            arguments.append("-GPSLongitude=\(gps.longitude)")
            arguments.append("-GPSLongitudeRef=\(gps.longitude >= 0 ? "E" : "W")")
            if let altitude = gps.altitude {
                arguments.append("-GPSAltitude=\(altitude)")
                // exiftool's default (non-numeric) write mode only recognizes GPSAltitudeRef's
                // descriptive PrintConv strings as input — writing the raw byte value ("0"/"1")
                // directly is silently coerced to 0 regardless of what's given (confirmed
                // empirically against exiftool 13.55; the Python reference app writes the raw
                // byte and appears to have the same latent bug).
                arguments.append("-GPSAltitudeRef=\(altitude >= 0 ? "Above Sea Level" : "Below Sea Level")")
            }
        }

        // Standard EXIF/XMP home for focus distance (metres), so viewers that don't parse Olympus
        // MakerNotes still show it — the maker-note tag this app reads for display is where OM bodies
        // record it, but they leave EXIF:SubjectDistance itself empty.
        if let subjectDistance {
            arguments.append("-EXIF:SubjectDistance=\(subjectDistance)")
            arguments.append("-XMP-exif:SubjectDistance=\(subjectDistance)")
        }

        // The in-camera creative-dial look (see `CameraLookParsing`), which no standard tag carries.
        // Instructions is the destination because a probe of six candidate fields found it's one of
        // only four DxO PhotoLab surfaces at all, and the only one of those not already spoken for.
        // Legacy IPTC IIM caps SpecialInstructions at 256 characters where XMP has no limit, so the
        // IIM half is truncated rather than letting exiftool reject the whole write; the XMP half
        // always carries the full string.
        if let instructions, !instructions.isEmpty {
            arguments.append("-IPTC:SpecialInstructions=\(String(instructions.prefix(256)))")
            arguments.append("-XMP-photoshop:Instructions=\(instructions)")
        }

        // Recompute the IPTC digest, because this write always changes the legacy IIM block.
        // Photoshop stores IPTCDigest as a checksum of that block so Adobe apps can tell whether a
        // non-XMP-aware tool edited IIM behind XMP's back; leaving it stale makes Bridge and
        // Photoshop offer a metadata-conflict prompt. Both halves get identical text here, so the
        // conflict is a nuisance rather than a real disagreement - but a prompt on a file nobody
        // edited is still wrong, and for a file carrying no digest yet this writes a correct one.
        //
        // This is correct on JPEG and PSD but not on TIFF, where it takes a second invocation of
        // its own - see `reconcileTIFFDigests`.
        arguments.append("-IPTCDigest=new")
        return arguments
    }

    /// Reads a sidecar `NativeMetadataWriter` wrote and folds its fields into the original file
    /// via the normal dual IPTC/XMP write path, then deletes the sidecar — turning a provisional
    /// edit made where a direct write wasn't safe (see `NativeMetadataWriter`'s doc comment) into
    /// the same authoritative in-file metadata a direct save produces here. No-op (returns
    /// `false`) if no sidecar exists for `url`.
    ///
    /// Reads `GPSLatitude#`/`GPSLongitude#` (the `#` suffix) rather than the default formatted
    /// strings — this needs the signed decimal value `write(...)` expects, not exiftool's
    /// human-readable "45 deg 31' 22.80\" N".
    func foldInSidecarIfPresent(for url: URL) async throws -> Bool {
        let sidecar = NativeMetadataWriter.sidecarURL(for: url)
        guard FileManager.default.fileExists(atPath: sidecar.path) else { return false }

        let output = try await run(
            arguments: [
                "-j", "-Title", "-Description", "-Subject", "-GPSLatitude#", "-GPSLongitude#",
                sidecar.path,
            ])
        guard let array = try JSONSerialization.jsonObject(with: output) as? [[String: Any]],
            let fields = array.first
        else {
            throw ExifToolError.invalidOutput
        }

        var gps: GPSCoordinate?
        if let latitude = fields["GPSLatitude"] as? Double,
            let longitude = fields["GPSLongitude"] as? Double
        {
            gps = GPSCoordinate(latitude: latitude, longitude: longitude, altitude: nil)
        }

        try await write(
            title: fields["Title"] as? String,
            description: fields["Description"] as? String ?? "",
            keywords: fields["Subject"] as? [String] ?? [],
            gps: gps,
            to: url)

        try FileManager.default.removeItem(at: sidecar)
        return true
    }

    private func backupURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + "_original")
    }

    private func cleanupBackup(for url: URL) {
        try? FileManager.default.removeItem(at: backupURL(for: url))
    }

    private func restoreBackupIfPresent(for url: URL) {
        let backup = backupURL(for: url)
        guard FileManager.default.fileExists(atPath: backup.path) else { return }
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.moveItem(at: backup, to: url)
    }

    /// Homebrew install locations to fall back to when `PATH` doesn't resolve exiftool. macOS
    /// launches .app bundles (Dock/Finder) with a minimal PATH (`/usr/bin:/bin:/usr/sbin:/sbin`)
    /// that excludes these, so a `PATH`-only lookup that works when run from Xcode/a terminal
    /// fails silently once bundled.
    private static let homebrewExiftoolCandidates = [
        "/opt/homebrew/bin/exiftool",  // Apple Silicon
        "/usr/local/bin/exiftool",  // Intel
    ]

    /// Resolved once per process: checks `PATH` first (covers `swift run`/Xcode where the
    /// launching shell's environment is inherited), then the known Homebrew locations.
    /// Internal rather than private so a test can invoke the same binary this client does,
    /// instead of hardcoding a path that differs between Apple Silicon and Intel.
    static let exiftoolPath: String = {
        if let pathVariable = ProcessInfo.processInfo.environment["PATH"] {
            for directory in pathVariable.split(separator: ":") {
                let candidate = "\(directory)/exiftool"
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        for candidate in homebrewExiftoolCandidates {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return "exiftool"
    }()

    /// Coordinates `run(arguments:timeoutSeconds:)`'s three independent async completion sources
    /// (stdout drained to EOF, stderr drained to EOF, process termination) and resumes the
    /// continuation exactly once all three have reported in — see that method's doc comment for
    /// why stdout/stderr must be drained on their own background reads rather than only inside
    /// `terminationHandler`.
    private final class RunCompletionState: @unchecked Sendable {
        private let lock = NSLock()
        private var stdoutData: Data?
        private var stderrData: Data?
        private var termination: (status: Int32, didTimeOut: Bool)?
        private var resumed = false
        private let continuation: CheckedContinuation<Data, Error>

        init(continuation: CheckedContinuation<Data, Error>) {
            self.continuation = continuation
        }

        func receiveStdout(_ data: Data) {
            lock.lock()
            stdoutData = data
            lock.unlock()
            tryResume()
        }

        func receiveStderr(_ data: Data) {
            lock.lock()
            stderrData = data
            lock.unlock()
            tryResume()
        }

        func receiveTermination(status: Int32, didTimeOut: Bool) {
            lock.lock()
            termination = (status, didTimeOut)
            lock.unlock()
            tryResume()
        }

        /// The launch itself failed, so the three normal completion sources will never all report
        /// in. Routed through the same `resumed` flag rather than resuming the continuation
        /// directly at the call site: the two background reads are already dispatched by the time
        /// `process.run()` can throw, and once their pipes hit EOF they would resume this same
        /// continuation a second time — which traps.
        func receiveLaunchFailure(_ error: Error) {
            lock.lock()
            guard !resumed else {
                lock.unlock()
                return
            }
            resumed = true
            lock.unlock()
            continuation.resume(throwing: error)
        }

        private func tryResume() {
            lock.lock()
            guard !resumed, let stdoutData, let stderrData, let termination else {
                lock.unlock()
                return
            }
            resumed = true
            lock.unlock()

            if termination.didTimeOut {
                continuation.resume(throwing: ExifToolError.timedOut)
                return
            }
            guard termination.status == 0 else {
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                continuation.resume(
                    throwing: ExifToolError.processFailed(status: termination.status, stderr: stderr))
                return
            }
            continuation.resume(returning: stdoutData)
        }
    }

    /// `Process.terminationHandler` and the timeout's `DispatchWorkItem` both run on background
    /// queues concurrently with each other, so the flag they race on needs its own lock rather than
    /// a plain captured `var` (which the Swift 6 concurrency checker correctly flags as unsafe).
    private final class TimeoutState: @unchecked Sendable {
        private let lock = NSLock()
        private var didTimeOut = false
        var workItem: DispatchWorkItem?

        /// Called from the timeout's `DispatchWorkItem` — `Process.terminate()` on an
        /// already-exited process is a harmless no-op, so no race check is needed here.
        func markTimedOut() {
            lock.lock()
            defer { lock.unlock() }
            didTimeOut = true
        }

        /// Called from `terminationHandler`. Cancels the timeout (it's moot once the process has
        /// exited on its own) and reports whether the timeout had already fired.
        ///
        /// Dropping the reference matters as much as cancelling it. This object is captured by the
        /// work item's block, so holding the item here is a retain cycle that `cancel()` does not
        /// break: neither side is ever freed, and the block's other capture — the `Process`, and
        /// through it both `Pipe`s — leaks its file descriptors for the life of the app. Measured
        /// at two descriptors per timed run, which is every file the app writes.
        func cancelAndCheckTimedOut() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            workItem?.cancel()
            workItem = nil
            return didTimeOut
        }
    }

    /// Runs `exiftool` and returns its stdout, or throws on a nonzero exit/timeout.
    ///
    /// stdout/stderr are drained on their own background reads started right after `process.run()`,
    /// not from inside `terminationHandler` — `readDataToEndOfFile()` blocks on each `read()` until
    /// data is available or EOF, so this drains continuously as exiftool writes rather than waiting
    /// for the process to exit first. That distinction matters: a `-j -G1 -a -s` read across even a
    /// couple of files can push stdout past the pipe's ~64KB kernel buffer (Olympus/OM System
    /// MakerNotes are especially verbose), and if that's left undrained until termination, exiftool
    /// blocks on its own `write()` into the full pipe and can never reach exit — deadlocking this
    /// call forever. `RunCompletionState` resumes the continuation once stdout, stderr, and
    /// termination have all reported in, however they interleave.
    /// Runs a write with the `-TAG=value` assignments handed over in a UTF-8 argfile rather than
    /// as arguments, and only the paths on argv.
    ///
    /// Foundation's `Process` encodes each argument with the file-system representation, which on
    /// Darwin is canonically *decomposed*. A precomposed "è" (U+00E8) therefore reaches exiftool as
    /// "e" followed by U+0300. Proven with `/bin/echo`: Swift holds `00E8`, the child sees
    /// `65 cc 80`, where the same text through a shell arrives as `c3 a8`. exiftool faithfully
    /// writes what it was given, so the XMP half ends up decomposed - visually identical, a
    /// different string - and the IPTC IIM half, which has no combining marks, stores a literal "?"
    /// in place of the accent. Measured on a real write: "Soufrière" came back from IIM as
    /// "Soufrie?re". Declaring the block UTF-8 does not help here: the argument is already mangled
    /// by the time exiftool sees it, whatever charset it is then stored in.
    ///
    /// An argfile is read as bytes, one argument a line, so nothing re-encodes the values. Paths
    /// stay on argv deliberately: there the decomposed form is what APFS wants.
    ///
    /// Two cases keep the plain argv path. Assignments that are entirely ASCII cannot be changed by
    /// the encoding, so they take the route they always took. A value containing a newline cannot
    /// go in a line-delimited argfile at all, and losing an accent is a smaller harm than an
    /// argument silently splitting in two - the photo index's 57,130 captions and 696,430 keywords
    /// contain no newline, but a description typed in the app could.
    private func runWrite(assignments: [String], paths: [String],
                          timeoutSeconds: Double) async throws -> Data {
        let output = try await runAssignments(assignments: assignments, paths: paths,
                                              timeoutSeconds: timeoutSeconds)
        await reconcileTIFFDigests(paths: paths, timeoutSeconds: timeoutSeconds)
        return output
    }

    /// Re-sets the IPTC digest on TIFF targets, which need a pass of their own.
    ///
    /// Measured on exiftool 13.55: an invocation that both changes the legacy IIM block and sets
    /// `-IPTCDigest=new` gets the digest right on JPEG and on PSD, and wrong on TIFF - the stored
    /// value matches neither the block before the write nor the block after it, so the file keeps
    /// warning "IPTCDigest is not current. XMP may be out of sync" and Adobe apps keep offering a
    /// metadata-conflict prompt. It is not our argv: plain exiftool does the same in either
    /// argument order, with or without clearing the old digest in the same call, and on a TIFF that
    /// carries no digest at all as well as one that does. A second, digest-only invocation
    /// reconciles it every time, which is what this is.
    ///
    /// Deliberately best-effort. The caption is already written and correct by this point, and a
    /// digest is advisory metadata about the *other* half of a write both halves of which agree -
    /// so a failure here leaves the file exactly as it would have been without this pass, and must
    /// not unwind a good write. `-overwrite_original` because the caller has already cleaned up its
    /// `_original`, and a second backup would outlive the run.
    ///
    /// The cost is a second full rewrite, which over SMB means the bytes cross the link twice more:
    /// 85 files and 21.7 GB of the 58,196-file write-back set, about 38 minutes of Wi-Fi.
    private func reconcileTIFFDigests(paths: [String], timeoutSeconds: Double) async {
        let tiffs = paths.filter {
            let ext = ($0 as NSString).pathExtension.lowercased()
            return ext == "tif" || ext == "tiff"
        }
        guard !tiffs.isEmpty else { return }
        _ = try? await run(arguments: ["-overwrite_original", "-IPTCDigest=new"] + tiffs,
                           timeoutSeconds: timeoutSeconds)
    }

    private func runAssignments(assignments: [String], paths: [String],
                                timeoutSeconds: Double) async throws -> Data {
        let needsArgFile = assignments.contains { !$0.allSatisfy(\.isASCII) }
        let hasNewline = assignments.contains { $0.contains(where: \.isNewline) }
        guard needsArgFile, !hasNewline else {
            return try await run(arguments: assignments + paths, timeoutSeconds: timeoutSeconds)
        }

        let argFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftselect-write-\(UUID().uuidString).args")
        try Data((assignments.joined(separator: "\n") + "\n").utf8).write(to: argFile)
        defer { try? FileManager.default.removeItem(at: argFile) }
        return try await run(arguments: ["-@", argFile.path] + paths, timeoutSeconds: timeoutSeconds)
    }

    private func run(arguments: [String], timeoutSeconds: Double? = nil) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: Self.exiftoolPath)
            process.arguments = arguments

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let timeoutState = TimeoutState()
            let completion = RunCompletionState(continuation: continuation)

            DispatchQueue.global(qos: .utility).async {
                completion.receiveStdout(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            }
            DispatchQueue.global(qos: .utility).async {
                completion.receiveStderr(stderrPipe.fileHandleForReading.readDataToEndOfFile())
            }

            process.terminationHandler = { finished in
                let didTimeOut = timeoutState.cancelAndCheckTimedOut()
                completion.receiveTermination(status: finished.terminationStatus, didTimeOut: didTimeOut)
            }

            do {
                try process.run()
                if let timeoutSeconds {
                    // `[weak process]` so a finished run's descriptors come back immediately rather
                    // than at the deadline: `asyncAfter` holds the work item until then even once
                    // it is cancelled, and a strong capture would pin the process — and both pipes
                    // — for the full timeout. A run that beat the clock leaves nothing to
                    // terminate, so the optional is simply nil by then.
                    let workItem = DispatchWorkItem { [weak process] in
                        timeoutState.markTimedOut()
                        process?.terminate()
                    }
                    timeoutState.workItem = workItem
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: workItem)
                }
            } catch {
                // The child never started, so nothing will ever close the write ends and the two
                // reads above would block forever on their pipes, holding both descriptors and a
                // dispatch thread each. Closing them here gives those reads their EOF.
                try? stdoutPipe.fileHandleForWriting.close()
                try? stderrPipe.fileHandleForWriting.close()
                completion.receiveLaunchFailure(error)
            }
        }
    }
}
