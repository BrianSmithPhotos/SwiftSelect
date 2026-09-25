import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import SwiftSelect
@testable import SwiftSelectCore

final class ReloadReproTests: XCTestCase {
    func testWriteThenReloadViaPhotoAssetLoaderRoundTripsDescription() async throws {
        let sourceDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }

        let pixel = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        pixel.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        pixel.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let image = pixel.makeImage()!
        let url = sourceDirectory.appendingPathComponent("P1010042.JPG")
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let client = ExifToolClient()
        try await client.write(
            title: nil, description: "My description", keywords: ["mountain", "sunrise"], gps: nil, to: url)

        let loader = PhotoAssetLoader()
        let assets = try await loader.loadAssets(in: sourceDirectory)
        let asset = try XCTUnwrap(assets.first)

        print("RELOADED descriptionText = '\(asset.descriptionText)'")
        print("RELOADED keywords = \(asset.keywords)")
        XCTAssertEqual(asset.descriptionText, "My description")
        XCTAssertEqual(asset.keywords, ["mountain", "sunrise"])
    }

    /// Reproduces the user's real-world scenario against an actual OM SYSTEM ORF that already has
    /// pre-existing IPTC fields (Copyright, Byline, StarRating) baked in from the camera — closer to
    /// the real card than a blank synthetic fixture. Skips itself when the card isn't mounted.
    func testWriteRealisticDescriptionThenReloadRealORF() async throws {
        let cardURL = URL(fileURLWithPath: "/Volumes/OM SYSTEM/DCIM/105OMSYS/F1052228.ORF")
        guard FileManager.default.fileExists(atPath: cardURL.path) else {
            throw XCTSkip("SD card not mounted")
        }
        let sourceDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }
        let url = sourceDirectory.appendingPathComponent("F1052228.ORF")
        try FileManager.default.copyItem(at: cardURL, to: url)

        let realisticDescription =
            "A red-tailed hawk perched on a weathered fence post, scanning the golden grassland at dusk."
        let client = ExifToolClient()
        try await client.write(
            title: nil, description: realisticDescription, keywords: ["hawk", "wildlife", "grassland"],
            gps: nil, to: url)

        let viaExifTool = try await client.readMetadata(at: url)
        print("VIA EXIFTOOL Caption-Abstract = '\(viaExifTool["IPTC:Caption-Abstract"] ?? "nil")'")
        print("VIA EXIFTOOL Keywords = \(viaExifTool["IPTC:Keywords"] ?? "nil")")

        let loader = PhotoAssetLoader()
        let assets = try await loader.loadAssets(in: sourceDirectory)
        let asset = try XCTUnwrap(assets.first)
        print("RELOADED (real ORF) descriptionText = '\(asset.descriptionText)'")
        print("RELOADED (real ORF) keywords = \(asset.keywords)")

        XCTAssertEqual(asset.descriptionText, realisticDescription)
        XCTAssertEqual(asset.keywords, ["hawk", "wildlife", "grassland"])
    }

    /// Simulates a second save overwriting a first (AI auto-save, then a manual edit + save) — the
    /// exact sequence the user reported.
    func testSecondSaveWithDifferentDescriptionOverwritesFirst() async throws {
        let cardURL = URL(fileURLWithPath: "/Volumes/OM SYSTEM/DCIM/105OMSYS/F1052228.ORF")
        guard FileManager.default.fileExists(atPath: cardURL.path) else {
            throw XCTSkip("SD card not mounted")
        }
        let sourceDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }
        let url = sourceDirectory.appendingPathComponent("F1052228.ORF")
        try FileManager.default.copyItem(at: cardURL, to: url)

        let client = ExifToolClient()
        try await client.write(
            title: nil, description: "AI generated description of a hawk.", keywords: ["hawk"], gps: nil,
            to: url)
        try await client.write(
            title: nil, description: "Manually edited description of a hawk on a post.",
            keywords: ["hawk", "post"], gps: nil, to: url)

        let loader = PhotoAssetLoader()
        let assets = try await loader.loadAssets(in: sourceDirectory)
        let asset = try XCTUnwrap(assets.first)
        print("AFTER SECOND SAVE descriptionText = '\(asset.descriptionText)'")
        print("AFTER SECOND SAVE keywords = \(asset.keywords)")

        XCTAssertEqual(asset.descriptionText, "Manually edited description of a hawk on a post.")
        XCTAssertEqual(asset.keywords, ["hawk", "post"])
    }

    /// Locks the fix for what used to be an unexplained ImageIO limitation: on a real OM SYSTEM
    /// camera JPEG, `PhotoAssetLoader`'s ImageIO-based scan read back an empty description even
    /// though `exiftool` had written — and independently read back — the correct value.
    ///
    /// The cause, proven 2026-09-25 on real OM-3 JPEGs: the camera writes a present-but-blank
    /// `IFD0:ImageDescription` into every JPEG, ImageIO merges that with `IPTC:Caption-Abstract`
    /// and `XMP-dc:Description` into one description, and the blank field wins — so
    /// `CGImageSourceCopyPropertiesAtIndex` returned `""` for *both* the IPTC caption and the TIFF
    /// description. Two copies of one file differing only in that field read back `""` and the
    /// caption respectively. It is not reproducible with a synthetic fixture, because `exiftool`
    /// deletes the tag rather than leaving it present and empty, which is why this test needs the
    /// card.
    ///
    /// `ExifToolClient` now writes the field, so the description survives to ImageIO and therefore
    /// to the iPad, which reads only through that path.
    /// `SourceBrowserViewModel.loadArtFilterTokenIfNeeded()`'s correction pass stays: it still
    /// covers card files written before this fix.
    func testSingleFileWriteToRealCameraJPEGThenReload_readsTheDescriptionThroughImageIO() async throws {
        let jpegCardURL = URL(fileURLWithPath: "/Volumes/OM SYSTEM/DCIM/105OMSYS/F1052228.JPG")
        guard FileManager.default.fileExists(atPath: jpegCardURL.path) else {
            throw XCTSkip("SD card not mounted")
        }
        let sourceDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }
        let jpegURL = sourceDirectory.appendingPathComponent("F1052228.JPG")
        try FileManager.default.copyItem(at: jpegCardURL, to: jpegURL)

        let client = ExifToolClient()
        let description = "A red-tailed hawk perched on a weathered fence post at dusk."
        try await client.write(
            title: nil, description: description, keywords: ["hawk", "wildlife"], gps: nil, to: jpegURL)

        let viaExifTool = try await client.readMetadata(at: jpegURL)
        XCTAssertEqual(viaExifTool["IPTC:Caption-Abstract"] as? String, description)

        let loader = PhotoAssetLoader()
        let assets = try await loader.loadAssets(in: sourceDirectory)
        let asset = try XCTUnwrap(assets.first)
        XCTAssertEqual(asset.descriptionText, description,
                       "ImageIO read no description back, so the camera's blank IFD0:ImageDescription "
                       + "is winning again — check ExifToolClient still writes that field.")
    }

    /// `saveMetadata(scope: .captureSet(...))` uses the *batched* multi-URL write, not the
    /// single-file one exercised above — reproduces that exact path on a real RAW+JPEG pair, and
    /// confirms the fix above holds on the batch path too. The ORF sibling never had the problem —
    /// only JPEG carries the camera's blank `IFD0:ImageDescription` — so it is the control here.
    func testBatchedWriteToRAWPlusJPEGPairThenReloadBoth_readsBothDescriptionsThroughImageIO() async throws {
        let jpegCardURL = URL(fileURLWithPath: "/Volumes/OM SYSTEM/DCIM/105OMSYS/F1052228.JPG")
        let rawCardURL = URL(fileURLWithPath: "/Volumes/OM SYSTEM/DCIM/105OMSYS/F1052228.ORF")
        guard FileManager.default.fileExists(atPath: jpegCardURL.path),
            FileManager.default.fileExists(atPath: rawCardURL.path)
        else {
            throw XCTSkip("SD card not mounted")
        }
        let sourceDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }
        let jpegURL = sourceDirectory.appendingPathComponent("F1052228.JPG")
        let rawURL = sourceDirectory.appendingPathComponent("F1052228.ORF")
        try FileManager.default.copyItem(at: jpegCardURL, to: jpegURL)
        try FileManager.default.copyItem(at: rawCardURL, to: rawURL)

        let client = ExifToolClient()
        let description = "A red-tailed hawk perched on a weathered fence post at dusk."
        let results = try await client.write(
            description: description, keywords: ["hawk", "wildlife"], gps: nil, to: [jpegURL, rawURL])
        for (url, result) in results {
            if case .failure(let error) = result {
                XCTFail("write failed for \(url.lastPathComponent): \(error)")
            }
        }

        let loader = PhotoAssetLoader()
        let assets = try await loader.loadAssets(in: sourceDirectory)
        let assetsByExtension = Dictionary(uniqueKeysWithValues: assets.map { ($0.url.pathExtension.uppercased(), $0) })

        XCTAssertEqual(assetsByExtension["ORF"]?.descriptionText, description)
        XCTAssertEqual(assetsByExtension["JPG"]?.descriptionText, description,
                       "the JPEG read back empty — the camera's blank IFD0:ImageDescription is "
                       + "winning again on the batch path.")
        for asset in assets {
            XCTAssertEqual(asset.keywords, ["hawk", "wildlife"], "mismatch for \(asset.url.lastPathComponent)")
        }
    }
}
