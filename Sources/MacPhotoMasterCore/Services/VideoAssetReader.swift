import AVFoundation
import CoreGraphics
import Foundation

public enum VideoAssetError: Error {
    case noRenderableFrame(URL)
}

/// Reads the two fields a video needs to take its place in the browsing grid, and renders a poster
/// frame for its tile.
///
/// AVFoundation rather than ImageIO: a `.MOV` has no `CGImageSource` at all, so
/// `NativeMetadataReader` cannot see one — a video read through it would fail and silently vanish
/// from the folder listing, which is the opposite of what browsing a card should do.
///
/// Deliberately thin. A video carries none of the EXIF/IPTC this app edits and none of the
/// maker-note signals capture-set grouping relies on, so only the capture time (which places the
/// clip in the grid's timeline) and the duration are read. See docs/SPEC.md §9.
public struct VideoAssetReader {
    public init() {}

    /// Builds the `PhotoAsset` a video is browsed as. Never throws: a clip whose container metadata
    /// can't be read still belongs in the grid, so the capture time falls back to the file's own
    /// modification date — which for a file straight off a card is when the camera finished writing
    /// it, and puts the clip in the right place in the day regardless.
    public func loadAsset(at url: URL) async -> PhotoAsset {
        var asset = PhotoAsset(id: url)
        asset.title = url.deletingPathExtension().lastPathComponent

        let avAsset = AVURLAsset(url: url)
        asset.capturedAt = await Self.creationDate(of: avAsset) ?? Self.modificationDate(of: url)
        asset.videoDuration = await Self.duration(of: avAsset)
        return asset
    }

    /// A still from one second in, scaled to fit `maxPixelSize`. Not frame zero: the first frame of
    /// a hand-held clip is routinely mid-wobble or still settling exposure, which makes a card's
    /// worth of tiles hard to tell apart. Both tolerances are infinite so the generator returns the
    /// nearest keyframe instead of decoding forward to an exact time — the difference between an
    /// instant thumbnail and seconds of decoding per tile.
    public func posterFrame(at url: URL, maxPixelSize: Int) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity

        // A clip shorter than the requested second has no frame at that time at all, so the start
        // of the file is the fallback rather than a failure.
        if let image = try? await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image {
            return image
        }
        guard let image = try? await generator.image(at: .zero).image else {
            throw VideoAssetError.noRenderableFrame(url)
        }
        return image
    }

    /// The container's own creation date. `nil` when the file carries none, or carries one
    /// AVFoundation can't turn into a `Date` (some cameras write a free-text string here).
    private static func creationDate(of asset: AVURLAsset) async -> Date? {
        guard let item = try? await asset.load(.creationDate) else { return nil }
        return try? await item.load(.dateValue)
    }

    /// `nil` rather than zero for a stream whose length isn't known: `CMTime` reports that as
    /// non-numeric, and `seconds` on a non-numeric time is `NaN`, which would render as a garbage
    /// duration rather than as "unknown".
    private static func duration(of asset: AVURLAsset) async -> TimeInterval? {
        guard let duration = try? await asset.load(.duration), duration.isNumeric else { return nil }
        return duration.seconds
    }

    private static func modificationDate(of url: URL) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.modificationDate] as? Date
    }

    /// `"1:23"` / `"1:02:03"` — the duration as a player would show it, for the tile badge and the
    /// metadata panel. Empty for a still or an unknown length.
    public static func durationText(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "" }
        let total = Int(seconds.rounded())
        let (hours, minutes, remainder) = (total / 3600, (total % 3600) / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
            : String(format: "%d:%02d", minutes, remainder)
    }
}
