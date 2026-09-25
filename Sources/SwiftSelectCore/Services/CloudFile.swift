import Foundation

/// Whether a file's bytes are on this machine, and how to ask for them when they are not.
///
/// The write-back's list holds 62,675 photographs inside iCloud Drive and 1,652 inside OneDrive,
/// and 97% of the iCloud ones are evicted: a name, a size, and no content. Waking one measured
/// 12.8 to 26.8 seconds with no relationship to its size - 2.1 MB took 26.8 s where 48.2 MB took
/// 12.5 - so the cost is a round trip to Apple and the bytes are nearly free once it moves. That is
/// why a placeholder is woken deliberately here, with its own allowance, instead of inside a
/// timeout sized for moving bytes: `WriteBackPlan.timeoutSeconds` gives a small file 12 seconds,
/// and every small placeholder would fail before exiftool saw a byte.
///
/// The test is ubiquity, not the allocated size. Both answer correctly for iCloud, but a file on
/// the SMB mount reports no ubiquity at all, so a NAS original can never be mistaken for a
/// placeholder and fetched for nothing - which across 4,645 GB of originals is the one mistake in
/// this run that would cost days. OneDrive answers through the same interface, so one path covers
/// both providers.
public enum CloudFile {
    public enum Presence: Equatable {
        /// Not in a cloud provider at all - the NAS, or a local disk. Nothing to do.
        case notCloud
        /// In a provider, and the bytes are here.
        case present
        /// In a provider, and the bytes are not here. This one has to be fetched.
        case evicted
    }

    public enum Failure: Error, Equatable {
        /// The provider was asked and the file was still not here when the allowance ran out.
        case notFetched(path: String, afterSeconds: Double)
        /// The provider refused the request outright.
        case refused(path: String, reason: String)
    }

    /// Asks the provider for an evicted file and waits until its bytes are here.
    ///
    /// The poll re-reads the status through a **fresh** URL each time, and that is the whole trick.
    /// `NSURL` caches resource values once read, so polling one URL object returns the same
    /// `notDownloaded` forever while the file quietly arrives behind it - measured, and it made a
    /// working fetch look like a 180 s timeout on all four test files when every one of them had in
    /// fact landed. A stale cache here would fail photographs that were merely still in the queue.
    ///
    /// Returns the seconds it took, so the run can report what the provider is actually costing.
    @discardableResult
    public static func fetch(
        at url: URL, timeoutSeconds: Double,
        pollSeconds: Double = 0.25,
        sleep: (Double) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1e9)) },
        clock: () -> Date = Date.init
    ) async throws -> Double {
        let start = clock()
        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
        } catch {
            throw Failure.refused(path: url.path, reason: String(describing: error).prefix(200).description)
        }
        while true {
            // A new URL, not `url`, for the caching reason above.
            if presence(at: URL(fileURLWithPath: url.path)) != .evicted {
                return clock().timeIntervalSince(start)
            }
            let waited = clock().timeIntervalSince(start)
            guard waited < timeoutSeconds else {
                throw Failure.notFetched(path: url.path, afterSeconds: waited)
            }
            await sleep(pollSeconds)
        }
    }

    public static func presence(at url: URL) -> Presence {
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isUbiquitousItem == true else { return .notCloud }
        // `.current` and `.downloaded` both mean the bytes are here; only `.notDownloaded` does not.
        // A nil status on a ubiquitous file is treated as present rather than fetched blindly.
        guard let status = values.ubiquitousItemDownloadingStatus else { return .present }
        return status == .notDownloaded ? .evicted : .present
    }
}
