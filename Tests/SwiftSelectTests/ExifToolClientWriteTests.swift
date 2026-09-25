import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import SwiftSelect
@testable import SwiftSelectCore

final class ExifToolClientWriteTests: XCTestCase {
    /// A tiny 1x1 JPEG with no metadata of its own — exiftool's write path doesn't need real
    /// image content to attach IPTC/XMP/GPS tags to, and generating this in-memory keeps these
    /// tests independent of any real photo file (see CLAUDE.md "Secrets & Privacy").
    private func writeBlankImage(to url: URL, type: UTType = .jpeg) throws {
        let pixel = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        pixel.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        pixel.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let image = pixel.makeImage()!

        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func makeTempFile(named name: String = "\(UUID().uuidString).jpg") throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(name)
        try writeBlankImage(to: url, type: url.pathExtension == "tif" ? .tiff : .jpeg)
        return url
    }

    func testSingleFileWriteRoundTripsThroughReadMetadata() async throws {
        let url = try makeTempFile()
        let client = ExifToolClient()
        let gps = GPSCoordinate(latitude: 45.5, longitude: -122.6, altitude: 30)

        try await client.write(
            title: "My Title", description: "My description", keywords: ["mountain", "sunrise"],
            gps: gps, subjectDistance: 16.03, to: url)

        let metadata = try await client.readMetadata(at: url)
        XCTAssertEqual(metadata["IPTC:ObjectName"] as? String, "My Title")
        XCTAssertEqual(metadata["XMP-dc:Title"] as? String, "My Title")
        XCTAssertEqual(metadata["IPTC:Caption-Abstract"] as? String, "My description")
        XCTAssertEqual(metadata["XMP-dc:Description"] as? String, "My description")
        XCTAssertEqual(metadata["XMP-iptcCore:AltTextAccessibility"] as? String, "My description")
        XCTAssertEqual(metadata["IPTC:Keywords"] as? [String], ["mountain", "sunrise"])
        XCTAssertEqual(metadata["XMP-dc:Subject"] as? [String], ["mountain", "sunrise"])
        // Read output isn't `-n` (numeric), so GPS comes back as exiftool's human-readable
        // hemisphere-annotated strings rather than raw signed doubles — the sign-derivation tests
        // below cover the Ref tags directly.
        XCTAssertEqual(metadata["GPS:GPSLatitudeRef"] as? String, "North")
        XCTAssertEqual(metadata["GPS:GPSLongitudeRef"] as? String, "West")
        // Focus distance lands in the standard EXIF/XMP subject-distance tags other apps read, not
        // just the Olympus MakerNote this app pulls it from. Read output is `-G1`-grouped (so the
        // EXIF tag surfaces under `ExifIFD:`) and human-formatted (trailing "m").
        XCTAssertEqual(metadata["ExifIFD:SubjectDistance"] as? String, "16.03 m")
        XCTAssertEqual(metadata["XMP-exif:SubjectDistance"] as? String, "16.03 m")
    }

    func testSingleFileWriteCleansUpBackupOnSuccess() async throws {
        let url = try makeTempFile()
        let client = ExifToolClient()

        try await client.write(title: nil, description: "desc", keywords: [], gps: nil, to: url)

        let backup = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + "_original")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

    func testIdempotentKeywordResaveDoesNotDuplicate() async throws {
        let url = try makeTempFile()
        let client = ExifToolClient()

        try await client.write(title: nil, description: "desc", keywords: ["mountain", "Sunrise"], gps: nil, to: url)
        try await client.write(title: nil, description: "desc", keywords: ["Mountain", "sunrise"], gps: nil, to: url)

        let metadata = try await client.readMetadata(at: url)
        XCTAssertEqual(metadata["IPTC:Keywords"] as? [String], ["Mountain", "sunrise"])
        XCTAssertEqual(metadata["XMP-dc:Subject"] as? [String], ["Mountain", "sunrise"])
    }

    func testGPSRefDerivationForAllFourHemisphereCombinations() async throws {
        let client = ExifToolClient()
        // exiftool's default (non-numeric) read output spells these out rather than the raw
        // N/S/E/W byte exiftool was given on write.
        let cases: [(lat: Double, lon: Double, latRef: String, lonRef: String)] = [
            (45.5, 122.6, "North", "East"),
            (45.5, -122.6, "North", "West"),
            (-45.5, 122.6, "South", "East"),
            (-45.5, -122.6, "South", "West"),
        ]

        for testCase in cases {
            let url = try makeTempFile()
            try await client.write(
                title: nil, description: "desc", keywords: [],
                gps: GPSCoordinate(latitude: testCase.lat, longitude: testCase.lon, altitude: nil), to: url)

            let metadata = try await client.readMetadata(at: url)
            XCTAssertEqual(metadata["GPS:GPSLatitudeRef"] as? String, testCase.latRef)
            XCTAssertEqual(metadata["GPS:GPSLongitudeRef"] as? String, testCase.lonRef)
        }
    }

    func testGPSAltitudeRefDerivationForBothSigns() async throws {
        let client = ExifToolClient()

        let aboveSeaLevel = try makeTempFile()
        try await client.write(
            title: nil, description: "desc", keywords: [],
            gps: GPSCoordinate(latitude: 1, longitude: 1, altitude: 30), to: aboveSeaLevel)
        let aboveMetadata = try await client.readMetadata(at: aboveSeaLevel)
        XCTAssertEqual(aboveMetadata["GPS:GPSAltitudeRef"] as? String, "Above Sea Level")

        let belowSeaLevel = try makeTempFile()
        try await client.write(
            title: nil, description: "desc", keywords: [],
            gps: GPSCoordinate(latitude: 1, longitude: 1, altitude: -30), to: belowSeaLevel)
        let belowMetadata = try await client.readMetadata(at: belowSeaLevel)
        XCTAssertEqual(belowMetadata["GPS:GPSAltitudeRef"] as? String, "Below Sea Level")
    }

    func testInvalidGPSCoordinateThrows() async throws {
        let url = try makeTempFile()
        let client = ExifToolClient()

        do {
            try await client.write(
                title: nil, description: "desc", keywords: [],
                gps: GPSCoordinate(latitude: 200, longitude: 0, altitude: nil), to: url)
            XCTFail("expected invalidLatitude to be thrown")
        } catch MetadataWriteError.invalidLatitude(let value) {
            XCTAssertEqual(value, 200)
        }
    }

    func testBatchWriteAppliesValuesToAllFiles() async throws {
        let urls = try [makeTempFile(), makeTempFile(), makeTempFile()]
        let client = ExifToolClient()

        let results = try await client.write(description: "shared desc", keywords: ["one", "two"], gps: nil, to: urls)

        for url in urls {
            guard case .success = results[url] else {
                return XCTFail("expected success for \(url)")
            }
            let metadata = try await client.readMetadata(at: url)
            XCTAssertEqual(metadata["IPTC:Caption-Abstract"] as? String, "shared desc")
            XCTAssertEqual(metadata["IPTC:Keywords"] as? [String], ["one", "two"])
        }
    }

    func testBatchWriteRollsBackAndFallsBackPerFileWhenOnePathIsInvalid() async throws {
        let goodURLs = try [makeTempFile(), makeTempFile()]
        let badURL = FileManager.default.temporaryDirectory.appendingPathComponent("does-not-exist-\(UUID().uuidString).jpg")
        let client = ExifToolClient()

        let results = try await client.write(
            description: "shared desc", keywords: ["shared"], gps: nil, to: goodURLs + [badURL])

        for url in goodURLs {
            guard case .success = results[url] else {
                return XCTFail("expected the good files to succeed via per-file fallback")
            }
            let metadata = try await client.readMetadata(at: url)
            XCTAssertEqual(metadata["IPTC:Caption-Abstract"] as? String, "shared desc")

            let backup = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + "_original")
            XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        }

        guard case .failure = results[badURL] else {
            return XCTFail("expected the nonexistent file to fail")
        }
    }

    /// An accented caption has to come back exactly as it went in, in both halves.
    ///
    /// `Process` encodes arguments with the Darwin file-system representation, which is canonically
    /// decomposed, so a precomposed "è" reached exiftool as "e" + U+0300. The XMP half then held a
    /// different string that looked identical, and the IPTC IIM half - cp1252, with no combining
    /// marks - stored a literal "?". Measured on a real photograph: "Soufrière" read back as
    /// "Soufrie?re". The fix hands the assignments over in a UTF-8 argfile instead.
    func testAccentedTextSurvivesTheWriteInBothIPTCAndXMP() async throws {
        let url = try makeTempFile()
        let client = ExifToolClient()
        // An en-dash alongside the accent: U+2013 has no decomposition and does exist in cp1252, so
        // it survived the old path and is the control that proves the accent was the problem.
        let caption = "A beach in Soufri\u{00E8}re with a 24\u{2013}70 mm lens"

        try await client.write(
            title: nil, description: caption, keywords: ["Soufri\u{00E8}re", "beach"], gps: nil,
            subjectDistance: nil, to: url)

        let metadata = try await client.readMetadata(at: url)
        XCTAssertEqual(metadata["IPTC:Caption-Abstract"] as? String, caption)
        XCTAssertEqual(metadata["XMP-dc:Description"] as? String, caption)
        XCTAssertEqual(metadata["XMP-iptcCore:AltTextAccessibility"] as? String, caption)
        XCTAssertEqual(metadata["IPTC:Keywords"] as? [String], ["Soufri\u{00E8}re", "beach"])
        // Equality alone would pass on a decomposed string in a Swift comparison, which normalises.
        // The count is what catches it: 41 precomposed scalars, 42 decomposed.
        XCTAssertEqual((metadata["XMP-dc:Description"] as? String)?.unicodeScalars.count, 41)
    }

    /// The batch path takes the same route, so it gets the same guarantee.
    func testAccentedTextSurvivesABatchWrite() async throws {
        let urls = try [makeTempFile(), makeTempFile()]
        let client = ExifToolClient()
        let caption = "Caf\u{00E9} in Z\u{00FC}rich"

        let results = try await client.write(
            description: caption, keywords: ["caf\u{00E9}", "city"], gps: nil, to: urls)

        for url in urls {
            guard case .success = results[url] else {
                return XCTFail("expected the batch write to succeed")
            }
            let metadata = try await client.readMetadata(at: url)
            XCTAssertEqual(metadata["IPTC:Caption-Abstract"] as? String, caption)
            XCTAssertEqual((metadata["IPTC:Caption-Abstract"] as? String)?.unicodeScalars.count, 14)
            XCTAssertEqual(metadata["IPTC:Keywords"] as? [String], ["caf\u{00E9}", "city"])
        }
    }

    /// A second write must leave the IPTC digest current, not stale.
    ///
    /// Photoshop stores IPTCDigest as a checksum of the legacy IIM block so Adobe apps can detect a
    /// non-XMP-aware edit. The first write here establishes a digest; the second changes the IIM
    /// block, and without `-IPTCDigest=new` exiftool then reports "IPTCDigest is not current. XMP
    /// may be out of sync" and Bridge offers a metadata-conflict prompt.
    func testASecondWriteLeavesTheIPTCDigestCurrent() async throws {
        let url = try makeTempFile()
        let client = ExifToolClient()

        try await client.write(
            title: nil, description: "first", keywords: ["one"], gps: nil, subjectDistance: nil,
            to: url)
        // The stored digest lives in the Photoshop IRB, not the IPTC group; File:CurrentIPTCDigest
        // is the freshly computed value exiftool compares it against, and is always present.
        let first = try await client.readMetadata(at: url)
        let firstDigest = first["Photoshop:IPTCDigest"] as? String
        XCTAssertNotNil(firstDigest, "the write should establish a stored digest")
        XCTAssertEqual(firstDigest, first["File:CurrentIPTCDigest"] as? String)

        try await client.write(
            title: nil, description: "second", keywords: ["two"], gps: nil, subjectDistance: nil,
            to: url)
        let metadata = try await client.readMetadata(at: url)
        // A stale digest is the failure, so the digest must have moved with the text.
        XCTAssertNotEqual(metadata["Photoshop:IPTCDigest"] as? String, firstDigest)
        XCTAssertEqual(metadata["Photoshop:IPTCDigest"] as? String,
                       metadata["File:CurrentIPTCDigest"] as? String)
        XCTAssertEqual(metadata["IPTC:Caption-Abstract"] as? String, "second")
        // And exiftool must have nothing to say about it.
        let warnings = try await Self.warnings(for: url)
        XCTAssertFalse(warnings.contains("IPTCDigest"), "unexpected warning: \(warnings)")
    }

    /// TIFF needs a digest pass of its own, so prove it gets one. exiftool 13.55 leaves the
    /// stored digest disagreeing with the computed one whenever it changes IIM and sets the digest
    /// in a single call on a TIFF - see `ExifToolClient.reconcileTIFFDigests` for the measurements.
    /// Two writes, because a first write on a fresh file and a rewrite over existing tags are
    /// different cases and both were observed to fail.
    func testTIFFComesOutWithACurrentIPTCDigest() async throws {
        let url = try makeTempFile(named: "\(UUID().uuidString).tif")
        let client = ExifToolClient()

        for (description, keyword) in [("first", "one"), ("second", "two")] {
            try await client.write(
                title: nil, description: description, keywords: [keyword], gps: nil,
                subjectDistance: nil, to: url)
            let metadata = try await client.readMetadata(at: url)
            XCTAssertEqual(metadata["IPTC:Caption-Abstract"] as? String, description)
            XCTAssertEqual(metadata["Photoshop:IPTCDigest"] as? String,
                           metadata["File:CurrentIPTCDigest"] as? String,
                           "stale digest after writing \(description)")
            let warnings = try await Self.warnings(for: url)
            XCTAssertFalse(warnings.contains("IPTCDigest"), "unexpected warning: \(warnings)")
        }
        // The reconciliation pass uses -overwrite_original, so it must leave no second backup.
        let backup = url.appendingPathExtension("_original")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

    /// exiftool's own warning channel, which `readMetadata` deliberately does not surface.
    func testTextOutsideLatin1SurvivesInIPTCToo() async throws {
        let url = try makeTempFile()
        let client = ExifToolClient()
        // Neither of these exists in cp1252, so before the block was declared UTF-8 the IIM half
        // stored a literal "?" per character while XMP held them correctly. This is the whole
        // reason for -IPTC:CodedCharacterSet=UTF8.
        let caption = "\u{041B}\u{0415}\u{0411}\u{0415}\u{0414}\u{041A}\u{0410} and M\u{0101}ori"

        try await client.write(
            title: nil, description: caption, keywords: ["M\u{0101}ori", "\u{041B}\u{0415}\u{0411}\u{0415}\u{0414}\u{041A}\u{0410}"], gps: nil,
            subjectDistance: nil, to: url)

        let metadata = try await client.readMetadata(at: url)
        XCTAssertEqual(metadata["IPTC:Caption-Abstract"] as? String, caption)
        XCTAssertEqual(metadata["IPTC:Keywords"] as? [String],
                       ["M\u{0101}ori", "\u{041B}\u{0415}\u{0411}\u{0415}\u{0414}\u{041A}\u{0410}"])
        XCTAssertEqual(metadata["XMP-dc:Description"] as? String, caption)
        XCTAssertEqual(metadata["IPTC:CodedCharacterSet"] as? String, "UTF8")
    }

    func testDeclaringUTF8LeavesTheIPTCFieldsWeDoNotWriteAlone() async throws {
        let url = try makeTempFile()
        // Changing the declared charset makes exiftool re-encode the whole IIM block, not just the
        // fields being assigned. That is harmless for ASCII and destructive for anything else - a
        // pre-existing "Z\u{00FC}rich" comes back as fc under a block claiming UTF8 - so this pins the
        // half that is safe. The index says the write-back set holds no non-ASCII here at all.
        try await Self.exiftool([
            "-overwrite_original", "-IPTC:City=Zurich", "-IPTC:By-line=Brian Smith",
            "-IPTC:CopyrightNotice=(c) Brian Smith", url.path])

        try await ExifToolClient().write(
            title: nil, description: "a caption", keywords: ["one"], gps: nil,
            subjectDistance: nil, to: url)

        let metadata = try await ExifToolClient().readMetadata(at: url)
        XCTAssertEqual(metadata["IPTC:City"] as? String, "Zurich")
        XCTAssertEqual(metadata["IPTC:By-line"] as? String, "Brian Smith")
        XCTAssertEqual(metadata["IPTC:CopyrightNotice"] as? String, "(c) Brian Smith")
        // Byte-level, because a Swift string comparison would hide a re-encoding that round-trips.
        let raw = try await Self.exiftool(["-b", "-IPTC:City", url.path])
        XCTAssertEqual(Array(raw.utf8), Array("Zurich".utf8))
    }

    private static func warnings(for url: URL) async throws -> String {
        try await exiftool(["-warning", "-a", "-s3", url.path])
    }

    /// Runs exiftool directly, for the two things the client cannot do: seeding a fixture with
    /// metadata the client never writes, and reading raw bytes back to check how they were encoded.
    @discardableResult
    private static func exiftool(_ arguments: [String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ExifToolClient.exiftoolPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// A newline in a value cannot go in a line-delimited argfile, so that write stays on argv.
    /// Losing an accent is a smaller harm than an argument silently splitting in two.
    func testDescriptionWithANewlineStillWrites() async throws {
        let url = try makeTempFile()
        let client = ExifToolClient()
        let caption = "First line\nsecond line"

        try await client.write(
            title: nil, description: caption, keywords: [], gps: nil, subjectDistance: nil, to: url)

        let metadata = try await client.readMetadata(at: url)
        XCTAssertEqual(metadata["XMP-dc:Description"] as? String, caption)
    }

    /// The folder-load pass carries the caption, because ImageIO's scan reads it back empty on
    /// camera-original JPEGs. A file with no caption is absent rather than an empty string.
    func testFolderScanReadsCaptions() async throws {
        let described = try makeTempFile()
        let blank = try makeTempFile()
        let client = ExifToolClient()
        try await client.write(
            title: nil, description: "Māori café", keywords: [], gps: nil, subjectDistance: nil,
            to: described)

        let scan = try await client.readFolderScan(at: [described, blank])

        XCTAssertEqual(scan.captions[described], "Māori café")
        XCTAssertNil(scan.captions[blank])
    }
}
