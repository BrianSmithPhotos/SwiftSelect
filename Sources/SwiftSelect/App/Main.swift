import Foundation
import SwiftSelectCore

/// The one entry point, choosing between the app and the headless write-back run.
///
/// `SwiftSelectApp` no longer carries `@main` itself: a target has exactly one entry point, and
/// this one has to decide before any of SwiftUI is touched. Anything that is not the `writeback` or
/// `evict` verb opens the window as before, because a double-clicked .app is handed argv it never
/// asked for and must not be able to fail on it.
@main
struct Main {
    static func main() {
        // The eviction verb first, and it is synchronous: handing bytes back is a resource read and
        // a call per file, with nothing to await.
        do {
            if let evicting = try EvictOptions.parse(arguments: CommandLine.arguments) {
                exit(EvictCommand.run(evicting))
            }
        } catch {
            WriteBackCommand.complain("\(error)\n\n\(EvictOptions.usage)")
            exit(2)
        }

        let options: WriteBackOptions?
        do {
            options = try WriteBackOptions.parse(arguments: CommandLine.arguments)
        } catch {
            WriteBackCommand.complain("\(error)\n\n\(WriteBackOptions.usage)")
            exit(2)
        }

        guard let options else {
            SwiftSelectApp.main()
            return
        }

        // A semaphore rather than an async main, so the GUI path above is exactly the entry point
        // it always was: an `async main()` would have SwiftUI start its run loop from inside the
        // concurrency runtime's own main task.
        //
        // `Task.detached`, not `Task`, and that is the whole of it: a `@main` type's `main()` is
        // main-actor isolated, so a plain `Task` inherits that isolation and cannot start until the
        // main thread is free - which `wait()` below guarantees it never will be. The symptom is a
        // process that prints nothing at all and hangs forever.
        let finished = DispatchSemaphore(value: 0)
        let status = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        status.initialize(to: 0)
        Task.detached(priority: .userInitiated) {
            status.pointee = await WriteBackCommand.run(options)
            finished.signal()
        }
        finished.wait()
        exit(status.pointee)
    }
}
