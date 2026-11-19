import Foundation

/// What one metadata save actually did. A save can return without writing anything - another save
/// is still running, or the scope held only clips - and a batch AI run has to be able to tell that
/// apart from a write. On 2026-11-18 a 1120-file GPS save on an SD card ran under a whole batch,
/// every batch write returned early on the busy guard, and the batch reported all of them done.
public enum MetadataSaveOutcome: Equatable, Sendable {
    /// Another save held the writer, so this one wrote nothing.
    case busy
    /// The scope had no writable files (clips carry no description).
    case nothingToSave
    case saved(fileCount: Int, failureCount: Int)

    /// Throws unless every file in the scope was written. For callers like the batch run that hand
    /// the answer to nobody else - if it did not land on disk, it is lost, so it must count as failed.
    public func requireWritten() throws {
        switch self {
        case .busy:
            throw MetadataSaveError.busy
        case .nothingToSave:
            throw MetadataSaveError.nothingWritten
        case .saved(let fileCount, let failureCount) where failureCount > 0:
            throw MetadataSaveError.partial(failed: failureCount, of: fileCount)
        case .saved:
            return
        }
    }
}

public enum MetadataSaveError: LocalizedError, Equatable {
    case busy
    case nothingWritten
    case partial(failed: Int, of: Int)

    public var errorDescription: String? {
        switch self {
        case .busy: return "not saved - another save was still running"
        case .nothingWritten: return "not saved - no writable files in the set"
        case .partial(let failed, let total): return "\(failed) of \(total) file(s) failed to save"
        }
    }
}
