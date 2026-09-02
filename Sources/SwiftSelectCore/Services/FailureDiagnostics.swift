import Foundation

/// Detail for the per-file failures a batch collects, beyond what `localizedDescription` carries.
///
/// A batch reports one line per file, and those lines used to be `error.localizedDescription`
/// alone. That string is all a `POSIXError` has — "The operation couldn't be completed. Bad file
/// descriptor" names neither the domain, the code, nor the call that failed, so a real failure
/// (63 files, 59 of them failing that way) could not be traced back to a syscall from the report
/// it produced. The domain and code are what identify it.
public enum FailureDiagnostics {
    /// One file's failure: the readable message, then the domain/code that pins it down, then any
    /// underlying error. `LocalizedError` types (e.g. `ExifToolError`, which puts exiftool's own
    /// stderr line in `errorDescription`) still lead with their own message.
    public static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        var text = "\(error.localizedDescription) [\(nsError.domain) \(nsError.code)]"
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += " <- \(underlying.localizedDescription) [\(underlying.domain) \(underlying.code)]"
        }
        return text
    }

    /// Descriptor pressure at the moment a batch failed, appended once to a report that has
    /// failures in it. Exhaustion is invisible in a per-file message but obvious here, and the
    /// limit is not knowable after the fact: a GUI app starts at 256 and something in the stack
    /// raises it, so the number has to be read from inside the process that hit it.
    public static func resourceSnapshot() -> String {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return "open files: unknown" }
        // Only descriptors below the soft limit can exist, so that bounds the scan. Capped because
        // the limit can be raised into the hundreds of thousands and this runs on a failure path.
        let scanTo = Int32(min(limit.rlim_cur, 65536))
        var open = 0
        for descriptor in Int32(0)..<scanTo where fcntl(descriptor, F_GETFD) != -1 { open += 1 }
        let ceiling = scanTo < Int32(limit.rlim_cur) ? "\(open)+ (scan capped)" : "\(open)"
        return "open files: \(ceiling) of soft limit \(limit.rlim_cur)"
    }
}
