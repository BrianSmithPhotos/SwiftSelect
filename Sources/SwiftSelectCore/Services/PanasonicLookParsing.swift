import Foundation

/// The Lumix counterpart of `ArtFilterTokenParsing` and `CameraLookParsing`: the filename token and
/// the look readings, from `exiftool`'s raw JSON metadata dict.
///
/// Worked out on a Lumix S9 (firmware 2.0) by shooting one frame per photo style, then frames with
/// every setting dialled to a different value. The settings sit in tags exiftool has no name for,
/// which is why the full read passes `-u`; the named `Contrast`, `Saturation`, `Sharpness` and
/// `HighlightShadow` tags never moved on that camera and are not read.
///
/// The RW2 of a pair carries the same tags as its JPEG but none of the look is applied to it.
public enum PanasonicLookParsing {
    /// The look worth naming in a filename, in this order: the Real Time LUT's file name (or
    /// `DualLUT` for two stacked), a saved
    /// custom style's name, then the photo style unless it is Standard. A RAW gets none.
    ///
    /// Underscores become dashes because the token is one `_`-separated filename segment: a LUT
    /// file named `Scafell_sRGB33` would otherwise read as two.
    public static func token(from metadata: [String: Any]) -> String {
        guard text(metadata, "File:FileType") != "RW2" else { return "" }
        let luts = luts(metadata)
        if luts.count > 1 { return dualLut }
        if let lut = luts.first { return lut.name }
        if let customStyle = customStyle(metadata) { return customStyle }
        let style = styleName(text(metadata, "Panasonic:PhotoStyle"))
        return style == "Standard" ? "" : style
    }

    /// The look for the strip and for Instructions, or `nil` for a Standard frame with nothing
    /// dialled in, and for a file that is not a Lumix one.
    ///
    /// With a LUT or a custom style the mode is its name, and the photo style is reported as the
    /// base it sits on: the same LUT over Monochrome and over Landscape are different pictures.
    public static func parse(from metadata: [String: Any]) -> CameraLook? {
        let photoStyle = text(metadata, "Panasonic:PhotoStyle")
        guard !photoStyle.isEmpty else { return nil }
        let base = styleName(photoStyle)

        var look = CameraLook()
        let luts = luts(metadata)
        if let lut = luts.first {
            look.mode = luts.count > 1 ? dualLut : lut.name
            // The base is the photo style even under a saved custom style: the custom style names
            // the set of dialled settings, not what the LUT sits on.
            look.readings.append(.init(name: "Base", value: base))
            if let customStyle = customStyle(metadata) {
                look.readings.append(.init(name: "Style", value: customStyle))
            }
            if luts.count > 1 {
                for (index, lut) in luts.enumerated() {
                    look.readings.append(.init(name: "LUT \(index + 1)", value: "\(lut.name) \(lut.opacity)%"))
                }
            } else if lut.opacity != 100 {
                look.readings.append(.init(name: "Opacity", value: "\(lut.opacity)%"))
            }
        } else if let customStyle = customStyle(metadata) {
            look.mode = customStyle
            look.readings.append(.init(name: "Base", value: base))
        } else {
            look.mode = base
        }
        look.readings += settings(metadata)

        if look.isModeOnly, look.mode == "Standard" { return nil }
        return look
    }

    /// exiftool's photo style text mapped to the camera's own name where the two differ ("Scenery"
    /// is the camera's Landscape). The
    /// `Unknown (n)` entries are styles newer than exiftool 13.55's table, matched to the S9's menu
    /// by shooting one frame per style in menu order; the styles exiftool does name all landed
    /// where the menu said they would. An `Unknown` outside the table has no name to give.
    private static let cameraStyleNames: [String: String] = [
        "Standard or Custom": "Standard", "Scenery": "Landscape",
        "Unknown (16)": "Flat", "Unknown (19)": "Cinelike V2", "Unknown (20)": "L.Monochrome S",
        "Unknown (21)": "L.ClassicNeo", "Unknown (22)": "LEICA Monochrome",
    ]

    private static func styleName(_ photoStyle: String) -> String {
        if let named = cameraStyleNames[photoStyle] { return named }
        // `L. Monochrome` loses its space: in a filename it would read `L.-Monochrome`.
        return photoStyle.hasPrefix("Unknown") ? "" : photoStyle.replacingOccurrences(of: "L. ", with: "L.")
    }

    /// Two stacked LUTs look like neither one, and both names would make a long filename, so the
    /// pair gets this name and the look lists the two.
    private static let dualLut = "DualLUT"

    /// The filled LUT slots in order, each with its own opacity. The camera can stack two.
    private static func luts(_ metadata: [String: Any]) -> [(name: String, opacity: Int)] {
        ["LUT1", "LUT2"].compactMap { slot in
            let name = text(metadata, "Panasonic:\(slot)Name")
            guard !name.isEmpty else { return nil }
            let opacity = number(text(metadata, "Panasonic:\(slot)Opacity")) ?? 100
            return (name.replacingOccurrences(of: "_", with: "-"), Int(opacity))
        }
    }

    /// A saved custom style reads as its base style's number; its name is in unnamed tag `0x00d5`.
    /// exiftool cuts that tag's padded field short and marks the cut with `[...]`, so the name
    /// arrives as `MY PHOTO STYLE 1[...]`, and as a bare `[...]` when no custom style is set.
    private static func customStyle(_ metadata: [String: Any]) -> String? {
        let name = text(metadata, "Panasonic:Panasonic_0x00d5")
            .replacingOccurrences(of: "[...]", with: "").trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// The dialled settings that are not at 0, in the camera's menu order. The camera steps some
    /// of them in halves, so they are kept as rendered text rather than whole numbers.
    private static func settings(_ metadata: [String: Any]) -> [CameraLook.Reading] {
        // `0x00db` is highlights then shadows.
        let highlightShadow = text(metadata, "Panasonic:Panasonic_0x00db")
            .split(separator: " ").map { number(String($0)) }
        let values: [(String, Double?)] = [
            ("Contrast", number(text(metadata, "Panasonic:Panasonic_0x00d7"))),
            ("Highlights", highlightShadow.first ?? nil),
            ("Shadows", highlightShadow.count > 1 ? highlightShadow[1] : nil),
            ("Saturation", number(text(metadata, "Panasonic:Panasonic_0x00d8"))),
            ("Hue", number(text(metadata, "Panasonic:Panasonic_0x00da"))),
            ("Sharpness", number(text(metadata, "Panasonic:Panasonic_0x00d9"))),
            ("Noise reduction", number(text(metadata, "Panasonic:NoiseReductionStrength"))),
        ]
        var readings: [CameraLook.Reading] = values.compactMap { name, value in
            guard let value, value != 0 else { return nil }
            return CameraLook.Reading(name: name, value: signed(value))
        }
        let grain = text(metadata, "Panasonic:MonochromeGrainEffect")
        if !grain.isEmpty, grain != "Off" {
            readings.append(.init(name: "Grain", value: grainWithColourNoise[grain] ?? grain.lowercased()))
        }
        return readings
    }

    /// Colour Noise On adds 3 to the grain number, which takes it past exiftool's table (1 Low,
    /// 2 Standard, 3 High). Shot on the S9: Low with it on wrote 4 and Standard with it on wrote 5,
    /// High with it on wrote 6, while Standard and High with it off wrote 2 and 3.
    private static let grainWithColourNoise: [String: String] = [
        "Unknown (4)": "low, colour noise", "Unknown (5)": "standard, colour noise",
        "Unknown (6)": "high, colour noise",
    ]

    private static func number(_ text: String) -> Double? { Double(text) }

    /// `+2`, `-0.5`, `+1.5`: whole steps without a trailing `.0`.
    private static func signed(_ value: Double) -> String {
        let magnitude = value == value.rounded() ? String(Int(abs(value))) : String(abs(value))
        return (value > 0 ? "+" : "-") + magnitude
    }

    /// A tag with no PrintConv arrives as a JSON number rather than a string.
    private static func text(_ metadata: [String: Any], _ key: String) -> String {
        guard let value = metadata[key] else { return "" }
        return String(describing: value).trimmingCharacters(in: .whitespaces)
    }
}
