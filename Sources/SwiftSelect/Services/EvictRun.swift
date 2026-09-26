import Foundation
import SwiftSelectCore

/// Gives back the local bytes of a batch the index chain has already been past.
///
/// The other half of the batched iCloud workflow. The write-back keeps the bytes so that scan, hash,
/// rekey and exif can read them - `hash` skips an evicted file as dataless, and 24 files that had
/// given their bytes back cost 51.9 s to fetch again where the same 24 took 0.65 s while local - and
/// then this hands them back in one pass.
///
/// It gives back only what a provider already holds, and it never touches a file that is not in a
/// provider at all. That is what keeps it away from the NAS: eviction there would be a delete, and
/// nothing in this project deletes a photograph.
struct EvictRun {
    struct Outcome: Equatable {
        /// Bytes handed back. The file keeps its name, its size and its metadata.
        var gaveBack = 0
        /// Already a placeholder, so there was nothing to hand back.
        var alreadyGone = 0
        /// Not in a cloud provider - the NAS, or a local disk. Left alone.
        var notCloud = 0
        /// In a provider that has not taken the local change yet. Left alone, and worth saying: it
        /// means either the upload is still in flight or something is wrong with it.
        var notTakenYet = 0
        /// The provider said no. Not an error - it means not yet - but it is counted and reported.
        var refused = 0
        var refusal: String?
    }

    var presence: (String) -> CloudFile.Presence = { CloudFile.presence(at: URL(fileURLWithPath: $0)) }
    var uploaded: (String) -> Bool = { CloudFile.isUploaded(at: URL(fileURLWithPath: $0)) }
    var evict: (String) throws -> Void = { try CloudFile.evict(at: URL(fileURLWithPath: $0)) }
    var dryRun = false

    /// Evictions in flight at once. Each one is a round trip to the provider's daemon, about 0.55 s
    /// whatever the file's size, so they overlap well: 8 at once cost 0.09 s a file against 0.61 s
    /// one at a time (measured 2026-09-26 on files uploaded long before).
    var lanes = 1

    func run(paths: [String]) -> Outcome {
        let lock = NSLock()
        var next = 0
        var outcome = Outcome()
        // Each lane takes the next path until none are left, so a slow file holds up only its lane.
        DispatchQueue.concurrentPerform(iterations: max(1, lanes)) { _ in
            while true {
                lock.lock()
                let index = next
                next += 1
                lock.unlock()
                guard index < paths.count else { return }
                let step = step(paths[index])
                lock.lock()
                outcome.add(step)
                lock.unlock()
            }
        }
        return outcome
    }

    enum Step {
        case notCloud, alreadyGone, notTakenYet, gaveBack
        case refused(String)
    }

    func step(_ path: String) -> Step {
        switch presence(path) {
        case .notCloud: return .notCloud
        case .evicted: return .alreadyGone
        case .present: break
        }
        // The provider has to say it holds the file before its only local copy goes. `isUploaded`
        // lags a write by about 0.4 s, but by the time a batch has been through the index chain
        // that is long past - see `WriteBackRun.graceSeconds` for the measurement.
        guard uploaded(path) else { return .notTakenYet }
        guard !dryRun else { return .gaveBack }
        do {
            try evict(path)
            return .gaveBack
        } catch {
            return .refused(String(describing: error).prefix(200).description)
        }
    }
}

extension EvictRun.Outcome {
    mutating func add(_ step: EvictRun.Step) {
        switch step {
        case .notCloud: notCloud += 1
        case .alreadyGone: alreadyGone += 1
        case .notTakenYet: notTakenYet += 1
        case .gaveBack: gaveBack += 1
        case .refused(let reason):
            refused += 1
            refusal = reason
        }
    }
}
