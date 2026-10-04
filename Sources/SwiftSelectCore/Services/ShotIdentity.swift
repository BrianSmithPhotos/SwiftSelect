import Foundation

/// Builds the identifier that ties every file from one press of the shutter back to its frame:
/// camera serial plus the camera's own frame number, e.g. `BJSA13381-1085082`.
///
/// The camera writes no identifier of its own (no `ImageUniqueID`, no `DocumentID`), and a content
/// hash stops matching the moment a RAW is developed, so an export looks like a different
/// photograph. This id is derived rather than random on purpose: the Mac, the iPad and a backfill
/// over already-archived files all arrive at the same value, and a lost id can be worked out again.
///
/// It is unique only while the camera's file counter keeps climbing. A counter reset (a repair, a
/// settings reset) would repeat old numbers; the capture date is deliberately left out until that
/// actually happens.
public enum ShotIdentity {
    /// The camera's frame number: the first run of digits in the filename.
    ///
    /// The first run, not every digit, because the same frame has two names. Off the card it is
    /// `H1085082.ORF`; after the app's rename it is `1085082_SanRafael_20260927_1909_...`, where the
    /// later digits are the date and time. Both give `1085082`. `nil` when the name has no digits.
    public static func frameNumber(from url: URL) -> String? {
        let stem = url.deletingPathExtension().lastPathComponent
        let digits = stem.drop { !$0.isNumber }.prefix { $0.isNumber }
        return digits.isEmpty ? nil : String(digits)
    }

    /// `serial-frame` for one file, or `nil` when either half is missing — a blank serial would
    /// make ids from two cameras collide, so no id is better than a partial one.
    public static func shotID(serial: String, url: URL) -> String? {
        let serial = serial.trimmingCharacters(in: .whitespaces)
        guard !serial.isEmpty, let frame = frameNumber(from: url) else { return nil }
        return "\(serial)-\(frame)"
    }

    /// The id shared by a whole capture set: the shot id of its lowest-numbered frame, so it has
    /// the same form as a shot id and needs no counter of its own.
    public static func setID(serial: String, memberURLs: [URL]) -> String? {
        let first = memberURLs.min { frameValue($0) < frameValue($1) }
        return first.flatMap { shotID(serial: serial, url: $0) }
    }

    /// Works out the three ids for every member of one capture set, keyed by asset id. Empty when
    /// no member carries a serial.
    ///
    /// The parent rule only ever names a RAW it can be sure of:
    /// - the RAW with the same frame number (a RAW+JPEG pair, or a JPEG developed from that RAW);
    /// - else the set's only RAW (a rendering bracket: one ORF, then filter JPEGs on the following
    ///   frame numbers);
    /// - else the file itself. That covers a JPEG-only set, and an in-camera composite sitting
    ///   among a bracket's many RAWs, which came from all of them rather than any one.
    public static func tags(for members: [PhotoAsset]) -> [PhotoAsset.ID: ShotTags] {
        guard let serial = members.map(\.cameraSerial).first(where: { !$0.isEmpty }) else {
            return [:]
        }
        let stills = members.filter { !$0.isVideo }
        // A developed JPEG lives under a staging name, so its frame comes from its original.
        func source(_ asset: PhotoAsset) -> URL { asset.derivedFrom ?? asset.url }
        let raws = stills.filter { PhotoAssetLoader.isRaw($0.url) }
        guard let setID = setID(serial: serial, memberURLs: stills.map(source)) else { return [:] }

        var tags: [PhotoAsset.ID: ShotTags] = [:]
        for asset in stills {
            guard let own = shotID(serial: serial, url: source(asset)) else { continue }
            let frame = frameNumber(from: source(asset))
            let sameFrame = raws.first { frameNumber(from: $0.url) == frame }
            let parent = sameFrame ?? (raws.count == 1 ? raws.first : nil)
            let parentID = parent.flatMap { shotID(serial: serial, url: $0.url) } ?? own
            tags[asset.id] = ShotTags(documentID: own, originalDocumentID: parentID, setID: setID)
        }
        return tags
    }

    /// The ids for a whole folder, where the user may have merged capture sets by hand.
    ///
    /// The set id follows the merge, but the parent is still worked out inside the set the camera
    /// made. A merge says the frames belong together, not that they came from one RAW: five merged
    /// rendering brackets hold five ORFs, and judged as one set every filter JPEG would lose its
    /// parent to the "only RAW" rule (seen on a real card, 2026-10-04: 49 of 441).
    public static func tags(
        forSets sets: [[PhotoAsset]], cameraSets: [[PhotoAsset]]
    ) -> [PhotoAsset.ID: ShotTags] {
        var result: [PhotoAsset.ID: ShotTags] = [:]
        for members in sets {
            result.merge(tags(for: members)) { current, _ in current }
        }
        for members in cameraSets {
            for (id, cameraTags) in tags(for: members) {
                result[id]?.originalDocumentID = cameraTags.originalDocumentID
            }
        }
        return result
    }

    /// Fills in each member's serial from a camera-model-to-serial table, for a device that cannot
    /// read it from the file.
    ///
    /// The OM-3 keeps its serial in the Olympus maker note, which only exiftool reads; ImageIO on
    /// the iPad sees the model but not the serial. So the iPad holds the pairing as a setting. A
    /// serial already on the asset wins, and a model with no entry stays blank, which yields no ids
    /// rather than wrong ones.
    public static func applyingSerials(
        _ serialsByModel: [String: String], to members: [PhotoAsset]
    ) -> [PhotoAsset] {
        let table = Dictionary(
            serialsByModel.map { (normalizedModel($0.key), $0.value) }, uniquingKeysWith: { first, _ in first })
        return members.map { member in
            guard member.cameraSerial.isEmpty else { return member }
            var member = member
            member.cameraSerial = table[normalizedModel(member.cameraModel)] ?? ""
            return member
        }
    }

    private static func normalizedModel(_ model: String) -> String {
        model.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Frames compare as numbers, so `999` sorts before `1000`. A name with no digits sorts last
    /// and then yields no id.
    private static func frameValue(_ url: URL) -> Int {
        frameNumber(from: url).flatMap { Int($0) } ?? .max
    }
}

/// The ids written into one file. See `ShotIdentity`.
///
/// The field choice was proven on real exports (2026-10-04): DxO PhotoLab and Silver Efex carry
/// all three through to TIFF and JPEG, where the JPEG loses the maker note and with it the serial.
public struct ShotTags: Equatable, Sendable {
    /// This file's own frame. Written to `xmpMM:DocumentID`.
    public var documentID: String
    /// The RAW this file came from, or its own id when there is none. Written to
    /// `xmpMM:OriginalDocumentID`, and the one to group on: DxO copies `DocumentID` verbatim, so
    /// an export carries its RAW's id in both.
    public var originalDocumentID: String
    /// The capture set. Written to `photoshop:TransmissionReference`, as XMP has no field for it.
    public var setID: String

    public init(documentID: String, originalDocumentID: String, setID: String) {
        self.documentID = documentID
        self.originalDocumentID = originalDocumentID
        self.setID = setID
    }

    /// XMP paths shared by the sidecar writer and its parser.
    static let xmpMMNamespace = "http://ns.adobe.com/xap/1.0/mm/"
    static let documentIDPath = "xmpMM:DocumentID"
    static let originalDocumentIDPath = "xmpMM:OriginalDocumentID"
    static let setIDPath = "photoshop:TransmissionReference"
}
