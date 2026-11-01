import Foundation

/// One file on disk plus the EXIF fields the app cares about. See docs/SPEC.md §2.
public struct PhotoAsset: Identifiable, Hashable {
    public let id: URL
    public var url: URL { id }

    public var title: String = ""
    public var descriptionText: String = ""
    public var keywords: [String] = []

    public var cameraModel: String = ""
    public var lensModel: String = ""
    public var aperture: String = ""
    public var shutterSpeed: String = ""
    public var focalLength: String = ""
    public var iso: String = ""
    /// Olympus/OM System maker-note field (e.g. "16.03 m") — like `artFilterToken`, standard EXIF
    /// doesn't carry this reliably, so `NativeMetadataReader`'s ImageIO scan can't read it; it's
    /// filled in the same lazy per-selection `exiftool` pass as `artFilterToken`.
    public var focusDistance: String = ""

    /// The camera body's serial number, the first half of a `ShotIdentity` id. It lives in the
    /// Olympus maker note, so the Mac fills it from the folder-load `exiftool` pass.
    public var cameraSerial: String = ""

    /// The camera's wall clock read as if it were this device's time zone — renames and the grid
    /// rely on that, so it shows the digits the camera recorded. It is only the true instant when
    /// the camera was set to this device's zone; `captureTimestampUTC` is the true instant.
    public var capturedAt: Date?
    /// The camera's own UTC offset for `capturedAt` (EXIF `OffsetTimeOriginal`, "+01:00" -> 3600),
    /// or nil when the file carries none.
    public var captureUTCOffsetSeconds: Int?

    /// The real capture instant, for matching against Timeline's UTC points. Without the camera's
    /// offset this falls back to `capturedAt` as-is, which is right only when camera and device
    /// share a zone: a camera on UK time read on a Mac on Pacific time lands 8 hours late.
    public var captureTimestampUTC: Int? {
        guard let capturedAt else { return nil }
        let asRead = Int(capturedAt.timeIntervalSince1970)
        guard let captureUTCOffsetSeconds else { return asRead }
        return asRead + TimeZone.current.secondsFromGMT(for: capturedAt) - captureUTCOffsetSeconds
    }

    public var artFilterToken: String?
    /// The in-camera creative-dial settings (see `CameraLookParsing`), read from the same lazy
    /// `exiftool` pass as `artFilterToken` and `nil` for anything that wasn't shot with the dial
    /// engaged — which includes every ORF, since the RAW deliberately stays at the neutral mode-dial
    /// value.
    ///
    /// Held typed rather than as the rendered string so the look visualiser can draw the individual
    /// readings; `cameraLookSummary` is the string that goes to Instructions.
    public var cameraLook: CameraLook?

    /// The look as the one-line string written to IPTC/XMP Instructions on process/move. Empty when
    /// there is nothing to report, so a caller can skip the write rather than stamp a blank field.
    public var cameraLookSummary: String { cameraLook?.summary ?? "" }

    public var gpsLatitude: Double?
    public var gpsLongitude: Double?
    public var gpsAltitude: Double?

    /// The RAW file this asset was developed from, for a `RawDevelopService` output — `nil` for
    /// every file that came off the camera. One field doing three jobs: it marks the asset as
    /// derived, it names the original whose filename the rename must be built from (the derivative
    /// lives under a staging key, whose digits `RenameService.sequence(from:)` would otherwise
    /// harvest), and it keys `RawDerivedStore`.
    public var derivedFrom: URL?

    /// Length in seconds of a video, `nil` for every still. The only field a `.MOV` fills that a
    /// photo doesn't — see `VideoAssetReader` for why a video is carried as a `PhotoAsset` rather
    /// than as a type of its own.
    public var videoDuration: TimeInterval?

    /// Whether this is a video rather than a still, decided by extension alone
    /// (`PhotoAssetLoader.videoExtensions`). Videos browse, preview and skip like stills, but carry
    /// no editable metadata and process to their own destination — see docs/SPEC.md §9.
    public var isVideo: Bool { PhotoAssetLoader.isVideo(url) }
}
