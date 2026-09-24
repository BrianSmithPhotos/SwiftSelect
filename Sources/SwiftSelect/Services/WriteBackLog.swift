import Foundation
import SwiftSelectCore

/// The manifest on disk. Read whole rather than streamed: 57,071 lines is 17 MB, and holding it
/// costs less than being unable to say how much work there is before starting.
enum WriteBackManifest {
    static func read(_ url: URL) throws -> [WriteBackEntry] {
        let text = try String(contentsOf: url, encoding: .utf8)
        var entries: [WriteBackEntry] = []
        for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            do {
                if let entry = try WriteBackPlan.entry(from: String(line)) { entries.append(entry) }
            } catch {
                // Naming the line matters: the manifest is generated, so a line the decoder
                // refuses is a disagreement between the two projects, not a typo to shrug at.
                throw WriteBackManifestError.badLine(number: number + 1, detail: String(describing: error))
            }
        }
        return entries
    }
}

enum WriteBackManifestError: Error, CustomStringConvertible {
    case badLine(number: Int, detail: String)

    var description: String {
        switch self {
        case let .badLine(number, detail): return "manifest line \(number): \(detail)"
        }
    }
}

/// The run's two logs, appended to as it goes.
///
/// `writeback-done.jsonl` is not a transcript, it is the record the index works from afterwards:
/// each line says which photograph was written and what its hash was beforehand, which is the
/// mapping that lets the vector and the thumbnails follow the photograph to its new hash instead of
/// being recomputed from a 2.6 TiB re-read. It doubles as the resume point.
///
/// `writeback-failed.jsonl` keeps the failures out of the resume set, so a rerun retries them.
final class WriteBackLog {
    static let doneName = "writeback-done.jsonl"
    static let failedName = "writeback-failed.jsonl"

    private let doneHandle: FileHandle
    private let failedHandle: FileHandle

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        doneHandle = try Self.appendHandle(directory.appendingPathComponent(Self.doneName))
        failedHandle = try Self.appendHandle(directory.appendingPathComponent(Self.failedName))
    }

    /// Paths a previous run finished. Only the done log counts: a failure has to be retried, and a
    /// missing file may well be back by the next run.
    static func alreadyWritten(in directory: URL) throws -> Set<String> {
        let url = directory.appendingPathComponent(doneName)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        var paths: Set<String> = []
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            guard let data = String(line).data(using: .utf8),
                  let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let path = row["path"] as? String else { continue }
            paths.insert(path)
        }
        return paths
    }

    func done(_ entry: WriteBackEntry, at date: Date) {
        append(to: doneHandle, [
            "path": entry.path,
            "hash": entry.hash,
            "wrote_at": Int(date.timeIntervalSince1970),
        ])
    }

    func failed(_ entry: WriteBackEntry, reason: String) {
        append(to: failedHandle, ["path": entry.path, "hash": entry.hash, "reason": reason])
    }

    func close() {
        try? doneHandle.close()
        try? failedHandle.close()
    }

    private static func appendHandle(_ url: URL) throws -> FileHandle {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        return handle
    }

    /// Written straight to the descriptor, not through a buffer: the point of a per-photograph log
    /// is that a run killed in the middle has already recorded everything it finished.
    private func append(to handle: FileHandle, _ row: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
              var line = String(data: data, encoding: .utf8) else { return }
        line.append("\n")
        try? handle.write(contentsOf: Data(line.utf8))
    }
}
