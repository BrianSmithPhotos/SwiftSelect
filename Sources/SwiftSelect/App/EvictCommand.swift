import Foundation
import SwiftSelectCore

/// The headless eviction: hands back the bytes of a batch once the index has read it.
enum EvictCommand {
    static func run(_ options: EvictOptions) -> Int32 {
        func say(_ line: String) {
            print(line)
            fflush(stdout)
        }

        let entries: [WriteBackEntry]
        do {
            entries = try WriteBackManifest.read(
                URL(fileURLWithPath: (options.manifest as NSString).expandingTildeInPath))
        } catch {
            WriteBackCommand.complain(String(describing: error))
            return 1
        }

        say("\(entries.count) photographs in the manifest")
        if options.dryRun { say("dry run: nothing will be handed back") }
        let outcome = EvictRun(dryRun: options.dryRun).run(paths: entries.map(\.path))

        say("\(options.dryRun ? "would have handed back" : "handed back") \(outcome.gaveBack), "
            + "already gone \(outcome.alreadyGone), not in a provider \(outcome.notCloud)")
        if outcome.notTakenYet > 0 {
            // Either an upload is still in flight or one is stuck. Bytes, not photographs, so it is
            // said and not failed - but it is said, because a silent one hid a broken step before.
            say("\(outcome.notTakenYet) the provider has not taken yet, so their bytes stay - "
                + "run this again later")
        }
        if outcome.refused > 0 {
            say("\(outcome.refused) refused, the last one: \(outcome.refusal ?? "")")
        }
        return 0
    }
}
