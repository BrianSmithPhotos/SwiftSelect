import XCTest

@testable import SwiftSelect
@testable import SwiftSelectCore

/// Byte-level tests on a fabricated Lumix JPEG, plus `testMatchesExifToolAcrossACard`, which needs
/// real frames and is the proof that the iPad and the Mac name a frame the same way.
final class PanasonicLookReaderTests: XCTestCase {
    private struct Entry {
        let tag: Int
        let format: Int
        let payload: [UInt8]
        /// Components, not bytes: a short is two bytes, a long four, a rational eight.
        var count: Int { payload.count / ([3: 2, 4: 4, 5: 8][format] ?? 1) }
    }

    private func le16(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)] }
    private func le32(_ value: Int) -> [UInt8] { (0..<4).map { UInt8((value >> ($0 * 8)) & 0xFF) } }

    private func padded(_ text: String, to width: Int) -> [UInt8] {
        Array(text.utf8) + [UInt8](repeating: 0, count: width - text.utf8.count)
    }

    /// One IFD at `start`, values over four bytes in a pool after it, offsets from the TIFF header.
    private func ifd(_ entries: [Entry], at start: Int) -> [UInt8] {
        var pool = start + 2 + entries.count * 12 + 4
        var body = le16(entries.count)
        var values: [UInt8] = []
        for entry in entries {
            body += le16(entry.tag) + le16(entry.format) + le32(entry.count)
            if entry.payload.count <= 4 {
                body += entry.payload + [UInt8](repeating: 0, count: 4 - entry.payload.count)
            } else {
                body += le32(pool)
                values += entry.payload
                pool += entry.payload.count
            }
        }
        return body + le32(0) + values
    }

    /// A JPEG whose IFD0 points at an ExifIFD holding only a Panasonic maker note. The note starts
    /// 44 bytes into the TIFF block, so its directory is at 56.
    private func jpeg(style: Int, filter: Int = 0, title: String = "", lut1: String = "", lut2: String = "")
        -> Data
    {
        let note =
            Array("Panasonic\0\0\0".utf8)
            + ifd(
                [
                    Entry(tag: 0x89, format: 3, payload: le16(style)),
                    Entry(tag: 0xA1, format: 5, payload: le32(0) + le32(filter)),
                    Entry(tag: 0xD5, format: 7, payload: padded(title, to: 64)),
                    Entry(tag: 0xF1, format: 2, payload: padded(lut1, to: 256)),
                    Entry(tag: 0xF4, format: 2, payload: padded(lut2, to: 256)),
                ], at: 56)
        let ifd0 = ifd([Entry(tag: 0x8769, format: 4, payload: le32(26))], at: 8)
        let exif = ifd([Entry(tag: 0x927C, format: 7, payload: note)], at: 26)
        let tiff = Array("II".utf8) + le16(42) + le32(8) + ifd0 + exif
        let segment = Array("Exif\0\0".utf8) + tiff
        let length = segment.count + 2
        return Data([0xFF, 0xD8, 0xFF, 0xE1, UInt8(length >> 8), UInt8(length & 0xFF)] + segment)
    }

    func testNamesEachKindOfLookAsTheMacDoes() {
        let cases: [(Data, String)] = [
            (jpeg(style: 1), ""),
            (jpeg(style: 3), "Natural"),
            (jpeg(style: 5), "Landscape"),
            (jpeg(style: 21), "L.ClassicNeo"),
            (jpeg(style: 1, filter: 524288), "Old Days"),
            (jpeg(style: 5, lut1: "Scafell_sRGB33"), "Scafell-sRGB33"),
            (jpeg(style: 5, lut1: "Scafell_sRGB33", lut2: "Helvellyn_sRGB33"), "DualLUT"),
            (jpeg(style: 1, title: "MY PHOTO STYLE 1"), "MY PHOTO STYLE 1"),
            (jpeg(style: 1, title: "MY PHOTO STYLE 1", lut1: "Fresh Bright"), "Fresh Bright"),
            (jpeg(style: 1, title: "Bright and Sunny", lut1: "Fresh Bright"), "Bright and Sunny"),
        ]

        for (data, expected) in cases {
            XCTAssertEqual(PanasonicLookReader.token(in: data), expected)
        }
    }

    func testAFileWithNoPanasonicNoteHasNoToken() {
        XCTAssertEqual(PanasonicLookReader.token(in: Data([0xFF, 0xD8, 0xFF, 0xD9])), "")
        XCTAssertEqual(PanasonicLookReader.token(in: Data()), "")
    }

    /// Never traps on a cut-off file, whatever it answers.
    func testAnyPrefixIsSafeToRead() {
        let whole = jpeg(style: 5, lut1: "Scafell_sRGB33")
        for length in 0..<whole.count { _ = PanasonicLookReader.token(in: whole.prefix(length)) }
    }

    func testARawGetsNoToken() {
        XCTAssertEqual(PanasonicLookReader.token(at: URL(fileURLWithPath: "/nowhere/P1000001.RW2")), "")
    }

    /// Point `MPM_TEST_CARD` at a folder of Lumix frames to run it.
    func testMatchesExifToolAcrossACard() async throws {
        let path = ProcessInfo.processInfo.environment["MPM_TEST_CARD"]
        try XCTSkipIf(path == nil, "set MPM_TEST_CARD to a folder of camera frames to run this")
        let files = try FileManager.default
            .contentsOfDirectory(at: URL(fileURLWithPath: path!), includingPropertiesForKeys: nil)
            .filter { ["jpg", "jpeg", "rw2"].contains($0.pathExtension.lowercased()) }
        try XCTSkipIf(files.isEmpty, "no camera frames in \(path!)")

        for file in files {
            let metadata = try await ExifToolClient().readMetadata(at: file)
            XCTAssertEqual(
                PanasonicLookReader.token(at: file), ArtFilterTokenParsing.token(from: metadata),
                "disagreed on \(file.lastPathComponent)")
        }
    }
}
