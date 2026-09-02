import Foundation

/// Where a video sits inside the iPad's Process package, and how the Mac reads the batch label back
/// out of it — docs/SPEC.md §9.
///
/// The iPad can't reach `~/videotmp` (it can't reach anything outside its own sandbox), so a clip
/// is staged in the same `ProcessedLibrary` folder the user already moves off the device, and the
/// Mac's import finishes the move. The batch label can't ride in the filename the way it does for a
/// still — the user asked for the camera name to be kept — so it rides in the directory instead:
///
///     ProcessedLibrary/Videos/Skomer/H1076833.MOV   batch "Skomer"
///     ProcessedLibrary/Videos/H1076833.MOV          no batch set that session
public enum IPadVideoBundle {
    /// The subtree videos are staged under, kept out of the date-based library tree beside it so an
    /// import can tell the two apart by location alone.
    public static let directoryName: String = "Videos"

    /// The root the whole video subtree hangs off, which is also what the iPad hands
    /// `VideoMoveService` as its destination root — staging a clip and finally moving it are the
    /// same copy-verify-rename operation, just landing in different places.
    public static func stagingRoot(in libraryRoot: URL) -> URL {
        libraryRoot.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// The directory a clip is staged into. Expressed through `VideoMoveService` rather than built
    /// here, so the batch folder the iPad writes and the one the Mac later creates under
    /// `~/videotmp` can't drift apart.
    public static func stagingDirectory(libraryRoot: URL, batch: String) -> URL {
        VideoMoveService.destinationDirectory(batch: batch, root: stagingRoot(in: libraryRoot))
    }

    /// The batch label a staged clip carries, or `""` for one staged with no batch set.
    ///
    /// Read from the parent directory's name rather than by walking down from `exportRoot`, so it
    /// still works whichever level the user actually copied to the Mac — the whole package, or just
    /// the one batch folder out of it. `exportRoot` itself and the `Videos` folder are the two names
    /// that mean "no batch", not a label.
    public static func batchLabel(for videoURL: URL, exportRoot: URL) -> String {
        let parent = videoURL.deletingLastPathComponent()
        // Compared as paths, not URLs: `deletingLastPathComponent` leaves a trailing slash that
        // makes two URLs for the same directory unequal.
        guard parent.standardizedFileURL.path != exportRoot.standardizedFileURL.path else { return "" }
        let name = parent.lastPathComponent
        return name == directoryName ? "" : name
    }
}
