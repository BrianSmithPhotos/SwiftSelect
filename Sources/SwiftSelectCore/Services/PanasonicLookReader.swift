import Foundation

/// The Lumix look token read straight from a JPEG's own bytes, for the iPad, where exiftool cannot
/// run. It rebuilds the handful of tags `PanasonicLookParsing.token` reads, in the text exiftool
/// would have printed them in, and hands them to that same function, so both platforms name a
/// frame the same way. They must: the Mac import re-derives the token with exiftool, and a
/// different answer would put two tokens in the keywords and two notes in the description.
///
/// JPEG only. An RW2 gets no token, because none of the look is applied to it.
public enum PanasonicLookReader {
    /// The look values sit about 6 KB into a Lumix S9 JPEG; this is the same head
    /// `OlympusMakerNoteReader` reads, and for the same reason: through iPadOS's file provider
    /// every byte crosses the cable.
    private static let headLength = 64 * 1024

    /// The token for each file that has one. Off the calling actor, because each open is a round
    /// trip through the file provider.
    public static func tokens(at urls: [URL]) async -> [URL: String] {
        await withTaskGroup(of: (URL, String).self) { group in
            for url in urls { group.addTask { (url, token(at: url)) } }
            var found: [URL: String] = [:]
            for await (url, token) in group where !token.isEmpty { found[url] = token }
            return found
        }
    }

    public static func token(at url: URL) -> String {
        guard ["jpg", "jpeg"].contains(url.pathExtension.lowercased()),
            let handle = try? FileHandle(forReadingFrom: url)
        else { return "" }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: headLength) else { return "" }
        return token(in: head)
    }

    static func token(in data: Data) -> String {
        metadata(in: data).map(PanasonicLookParsing.token(from:)) ?? ""
    }

    /// The look tags as exiftool names and prints them, or `nil` for anything that is not a JPEG
    /// with a Panasonic maker note.
    static func metadata(in data: Data) -> [String: Any]? {
        guard data.count > 2, data[0] == 0xFF,
            let tiff = OlympusMakerNoteReader.tiffHeaderOffset(in: data), tiff + 8 <= data.count
        else { return nil }
        let file = TIFFBytes(data: data, isBigEndian: data[tiff] == 0x4D)
        guard let ifd0 = file.uint32(at: tiff + 4),
            let exifPointer = file.entries(at: tiff + ifd0, base: tiff).first(where: { $0.tag == 0x8769 }),
            let exifOffset = file.uint32(at: exifPointer.valueOffset),
            let note = file.entries(at: tiff + exifOffset, base: tiff).first(where: { $0.tag == 0x927C }),
            file.matches("Panasonic\0\0\0", at: note.valueOffset)
        else { return nil }
        // One flat directory after a 12-byte header, its offsets counted from the TIFF header.
        let entries = file.entries(at: note.valueOffset + 12, base: tiff)
        func entry(_ tag: Int) -> TIFFBytes.Entry? { entries.first { $0.tag == tag } }

        var metadata: [String: Any] = [:]
        if let style = entry(0x89).flatMap({ file.numbers(of: $0).first }) {
            metadata["Panasonic:PhotoStyle"] = photoStyles[style] ?? "Unknown (\(style))"
        }
        // Declared a rational but holds two plain 32-bit numbers; the second is the filter.
        if let filter = entry(0xA1), file.uint32(at: filter.valueOffset) == 0,
            let code = file.uint32(at: filter.valueOffset + 4)
        {
            metadata["Panasonic:FilterEffect"] = filters[code] ?? "Unknown (0 \(code))"
        }
        metadata["Panasonic:Panasonic_0x00d5"] = entry(0xD5).map { string($0, in: data) }
        metadata["Panasonic:LUT1Name"] = entry(0xF1).map { string($0, in: data) }
        metadata["Panasonic:LUT2Name"] = entry(0xF4).map { string($0, in: data) }
        return metadata
    }

    /// A fixed-width field padded with NULs, read up to the first one.
    private static func string(_ entry: TIFFBytes.Entry, in data: Data) -> String {
        let start = min(max(entry.valueOffset, 0), data.count)
        let end = min(start + entry.count, data.count)
        return String(decoding: data[start..<end].prefix { $0 != 0 }, as: UTF8.self)
    }

    /// exiftool 13.55's own names for `PhotoStyle` (0x89). The numbers it has no name for print
    /// as `Unknown (n)`, which `PanasonicLookParsing` then maps to the camera's menu.
    private static let photoStyles: [Int: String] = [
        0: "Auto", 1: "Standard or Custom", 2: "Vivid", 3: "Natural", 4: "Monochrome", 5: "Scenery",
        6: "Portrait", 8: "Cinelike D", 9: "Cinelike V", 11: "L. Monochrome", 12: "Like709",
        15: "L. Monochrome D", 17: "V-Log", 18: "Cinelike D2",
    ]

    /// exiftool 13.55's names for the second number of `FilterEffect` (0xA1).
    private static let filters: [Int: String] = [
        0: "Off", 1: "Expressive", 2: "Retro", 4: "High Key", 8: "Sepia", 16: "High Dynamic",
        32: "Miniature Effect", 256: "Low Key", 512: "Toy Effect", 1024: "Dynamic Monochrome",
        2048: "Soft Focus", 4096: "Impressive Art", 8192: "Cross Process", 16384: "One Point Color",
        32768: "Star Filter", 524288: "Old Days", 1_048_576: "Sunshine", 2_097_152: "Bleach Bypass",
        4_194_304: "Toy Pop", 8_388_608: "Fantasy", 33_554_432: "Monochrome",
        67_108_864: "Rough Monochrome", 134_217_728: "Silky Monochrome",
    ]
}
