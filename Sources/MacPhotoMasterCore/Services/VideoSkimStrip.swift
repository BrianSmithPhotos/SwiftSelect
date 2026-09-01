import AVFoundation
import CoreGraphics
import Foundation

/// The row of stills under the video preview: enough of a clip at a glance to tell whether any of
/// it is worth keeping, without sitting through it (docs/SPEC.md §9). Clicking one seeks there.
public struct VideoSkimStrip {
    public struct Frame: Identifiable, Sendable {
        public let time: TimeInterval
        public let image: CGImage
        public var id: TimeInterval { time }
    }

    public init() {}

    /// Slice midpoints, not evenly spaced edges. A strip anchored at 0 and at the duration spends
    /// two of its few tiles on the two least useful moments of a hand-held clip: the first frame is
    /// mid-wobble with the exposure still settling, and the last is usually the camera being
    /// lowered. Midpoints also guarantee every time is strictly inside the clip, so none of them
    /// lands past the final frame.
    public static func sampleTimes(duration: TimeInterval, count: Int) -> [TimeInterval] {
        guard duration > 0, duration.isFinite, count > 0 else { return [] }
        return (0..<count).map { duration * (Double($0) + 0.5) / Double(count) }
    }

    /// Frames for `sampleTimes`, in clip order.
    ///
    /// Both tolerances are infinite, as in `VideoAssetReader.posterFrame`: the generator returns the
    /// nearest keyframe rather than decoding forward to an exact time. That is what makes the strip
    /// affordable off the card it was shot on — measured at 0.386s for ten frames of a 91-second 4K
    /// clip on an SD card reader, against seconds per frame for exact times.
    ///
    /// A frame the generator can't render is dropped rather than failing the strip: one unreadable
    /// keyframe in a clip is no reason to show none of it.
    public func frames(
        at url: URL, duration: TimeInterval, count: Int, maxPixelSize: Int
    ) async -> [Frame] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity

        var frames: [Frame] = []
        for time in Self.sampleTimes(duration: duration, count: count) {
            guard !Task.isCancelled else { return frames }
            let cmTime = CMTime(seconds: time, preferredTimescale: 600)
            guard let image = try? await generator.image(at: cmTime).image else { continue }
            frames.append(Frame(time: time, image: image))
        }
        return frames
    }
}
