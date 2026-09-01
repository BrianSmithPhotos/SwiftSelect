import CoreGraphics
import Foundation

/// The one place a thumbnail is asked for without the caller having to know whether it is looking
/// at a still or a clip. Grid tiles and filmstrips go through this; the large preview does not,
/// because there a video is played rather than shown as a frame.
///
/// Returns `nil` rather than throwing: a tile with no thumbnail is a normal, recoverable state
/// (an unsupported RAW variant, a clip with no decodable frame), and every call site already
/// renders a placeholder for it.
public enum MediaPreviewLoader {
    public static func thumbnail(at url: URL, maxPixelSize: Int) async -> CGImage? {
        if PhotoAssetLoader.isVideo(url) {
            return try? await VideoAssetReader().posterFrame(at: url, maxPixelSize: maxPixelSize)
        }
        return try? await NativeMetadataReader().extractPreviewAsync(at: url, maxPixelSize: maxPixelSize)
    }
}
