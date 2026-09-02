import Foundation

/// Resolves (and creates) this app's Application Support subdirectory — the standard macOS
/// location for local databases and other files that shouldn't sync via iCloud or clutter the
/// user's visible file browsing. Shared by `SkipStateStore` and, once wired into the app,
/// `TimelineLocationCache` — both want "a stable place on disk for a small SQLite file," not
/// anything folder- or document-specific.
public enum AppSupportDirectory {
    static let directoryName = "SwiftSelect"

    /// What the folder was called before the app was renamed in 2026-09. Everything the app
    /// remembers between launches lives in it — skip and processed marks, capture-set merges, the
    /// Timeline export and its location cache — none of which is recoverable by rebuilding, so the
    /// rename moves the folder rather than starting a new one beside it.
    static let previousDirectoryName = "MacPhotoMaster"

    /// Runs the move once per process, whichever store asks for a file first. A `static let` is
    /// what makes that safe: the stores below all build themselves off the main actor and several
    /// resolve their paths at once, and Swift guarantees a type's stored static is initialised
    /// exactly once even when a dozen tasks reach it together. Two threads both calling
    /// `moveItem` would not be.
    private static let migration: Void = {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        else { return }
        try? migrateIfNeeded(in: base)
    }()

    public static func url(forFileNamed fileName: String) throws -> URL {
        _ = migration

        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let appDirectory = base.appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        return appDirectory.appendingPathComponent(fileName)
    }

    /// Renames the old folder to the new one, and only when there is nothing to lose by it: an
    /// existing new folder always wins, because by then the app has already written state into it
    /// and the old folder is a stale copy from before the rename, not a newer one.
    ///
    /// Deletable once both apps have launched under the new name. On the iPad it never fires at
    /// all — the new bundle identifier gets its own container, so the old folder is not merely
    /// absent but unreachable, which is why the rename was timed for a device with nothing staged.
    static func migrateIfNeeded(in base: URL) throws {
        let new = base.appendingPathComponent(directoryName, isDirectory: true)
        let old = base.appendingPathComponent(previousDirectoryName, isDirectory: true)

        let manager = FileManager.default
        guard !manager.fileExists(atPath: new.path), manager.fileExists(atPath: old.path) else {
            return
        }
        try manager.moveItem(at: old, to: new)
    }
}
