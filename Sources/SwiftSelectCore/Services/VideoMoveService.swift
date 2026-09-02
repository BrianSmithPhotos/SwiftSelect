import Foundation

/// Copies a video off the card into `~/videotmp/<batch>/`, verified the same way a photo's copy is
/// and with the camera's own filename kept. See docs/SPEC.md §9.
///
/// Separate from `ProcessMoveService` rather than a branch inside it, because a video shares none
/// of what that service exists to do: no date-routed library folder, no rename, no title, no
/// metadata write, and so none of the staging-then-annotate sequencing those need. What the two do
/// share — copy first, never touch the source, verify size + SHA-256 before trusting the copy — is
/// `CopyVerification`, which both call.
///
/// The destination is a holding area, not a library: videos leave the app here for whatever editing
/// tool takes them next, which is why they are grouped by batch rather than by capture date.
public struct VideoMoveService {
    private let renameService = RenameService()

    public init() {}

    #if os(macOS)
        /// `~/videotmp`. Fixed rather than user-picked, unlike the photo library root: this is a
        /// staging folder the user hands on to an editor, not a destination worth persisting a
        /// choice for. Built from `homeDirectoryForCurrentUser` so no username is ever written into
        /// the source. Mac-only: the iPad has no home directory to reach, so it stages clips inside
        /// its own sandbox (`IPadVideoBundle`) and lets the Mac's import finish the move.
        public static var defaultDestinationRoot: URL {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("videotmp", isDirectory: true)
        }
    #endif

    /// The folder this batch's videos land in — the root itself when no batch label is set, so a
    /// forgotten label leaves clips loose at the top level where they are obvious, rather than
    /// hidden under an invented name.
    public static func destinationDirectory(batch: String, root: URL) -> URL {
        let folder = RenameService.sanitizeComponent(batch)
        return folder.isEmpty ? root : root.appendingPathComponent(folder, isDirectory: true)
    }

    /// Copies `asset.url` into its batch folder under `root`, keeping the camera's filename, and
    /// verifies the copy before reporting success. The source is never touched, per docs/SPEC.md's
    /// non-destructive card workflow.
    ///
    /// Lands under a hidden staging name and is renamed into place only once verified, the same way
    /// `ProcessMoveService` does it — an 866 MB clip off a card reader takes long enough that
    /// anything watching the folder would otherwise see, and could start reading, a partial file.
    /// `async` for the same reason `ProcessMoveService.processAndCopy` is, despite awaiting
    /// nothing: a nonisolated `async` method does not inherit its caller's actor, so the copy and
    /// its two SHA-256 passes run off the main thread rather than freezing the UI for the length of
    /// a multi-hundred-megabyte read from a card reader.
    public func processAndCopy(asset: PhotoAsset, batch: String, destinationRoot: URL) async throws
        -> ProcessMoveResult
    {
        guard FileManager.default.fileExists(atPath: asset.url.path) else {
            throw ProcessMoveError.sourceNotFound(asset.url)
        }

        let directory = Self.destinationDirectory(batch: batch, root: destinationRoot)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let existingNames = Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
        let finalName = renameService.ensureUniqueName(
            asset.url.lastPathComponent, existingNames: existingNames)
        let destinationURL = directory.appendingPathComponent(finalName)
        let stagingURL = directory.appendingPathComponent(
            ".mpm-staging-\(UUID().uuidString).\(asset.url.pathExtension)")

        try FileManager.default.copyItem(at: asset.url, to: stagingURL)
        do {
            try CopyVerification.verify(source: asset.url, destination: stagingURL)
            try FileManager.default.moveItem(at: stagingURL, to: destinationURL)
        } catch {
            // Trash, never `removeItem`, per CLAUDE.md "File Safety" — same as the photo path's
            // handling of a copy that failed verification.
            _ = try? FileManager.default.trashItem(at: stagingURL, resultingItemURL: nil)
            throw error
        }

        return ProcessMoveResult(sourceURL: asset.url, destinationURL: destinationURL)
    }
}
