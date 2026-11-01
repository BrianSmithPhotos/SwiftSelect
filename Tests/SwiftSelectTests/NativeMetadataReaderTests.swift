import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import SwiftSelect
@testable import SwiftSelectCore

final class NativeMetadataReaderTests: XCTestCase {
    /// Synthesizes a tiny JPEG with real EXIF/IPTC/GPS/TIFF properties in-memory, so this test
    /// needs no external fixture file or exiftool dependency — it proves the reader round-trips
    /// what ImageIO itself wrote, independent of any particular camera's output.
    private func writeSampleJPEG(to url: URL, extraProperties: [CFString: Any] = [:]) throws {
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

        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else {
            throw NativeMetadataError.unreadableFile
        }

        var properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifLensModel: "Test Lens 25mm f/1.8",
                kCGImagePropertyExifFNumber: 1.8,
                kCGImagePropertyExifExposureTime: 0.005,
                kCGImagePropertyExifFocalLength: 25,
                kCGImagePropertyExifISOSpeedRatings: [200],
                kCGImagePropertyExifDateTimeOriginal: "2026:03:15 14:30:00",
            ],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFModel: "Test Camera E-M1",
            ],
            kCGImagePropertyIPTCDictionary: [
                kCGImagePropertyIPTCObjectName: "Sample Title",
                kCGImagePropertyIPTCCaptionAbstract: "Sample caption",
                kCGImagePropertyIPTCKeywords: ["mountain", "sunrise"],
            ],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 45.5,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 122.6,
                kCGImagePropertyGPSLongitudeRef: "W",
                kCGImagePropertyGPSAltitude: 30.0,
                kCGImagePropertyGPSAltitudeRef: 0,
            ],
        ]
        for (key, value) in extraProperties {
            properties[key] = value
        }

        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw NativeMetadataError.unreadableFile
        }
    }

    func testReadMetadataAndMapToPhotoAssetRoundTripsWrittenProperties() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeSampleJPEG(to: url)

        let reader = NativeMetadataReader()
        let metadata = try reader.readMetadata(at: url)
        let asset = reader.mapToPhotoAsset(url: url, metadata: metadata)

        XCTAssertEqual(asset.title, "Sample Title")
        XCTAssertEqual(asset.descriptionText, "Sample caption")
        XCTAssertEqual(asset.keywords, ["mountain", "sunrise"])
        XCTAssertEqual(asset.cameraModel, "Test Camera E-M1")
        XCTAssertEqual(asset.lensModel, "Test Lens 25mm f/1.8")
        XCTAssertEqual(asset.aperture, "f/1.8")
        XCTAssertEqual(asset.shutterSpeed, "1/200")
        XCTAssertEqual(asset.focalLength, "25 mm")
        XCTAssertEqual(asset.iso, "200")
        XCTAssertNotNil(asset.capturedAt)

        XCTAssertEqual(asset.gpsLatitude ?? 0, 45.5, accuracy: 0.0001)
        XCTAssertEqual(asset.gpsLongitude ?? 0, -122.6, accuracy: 0.0001)
        XCTAssertEqual(asset.gpsAltitude ?? 0, 30.0, accuracy: 0.0001)
    }

    func testMapToPhotoAssetFallsBackToTIFFDescriptionWhenNoIPTCCaption() throws {
        // The JPEG encoder collapses TIFFImageDescription into IPTC Caption/Abstract when both are
        // present in one write, so this fixture omits the IPTC dictionary entirely to isolate the
        // fallback path in mapToPhotoAsset.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeSampleJPEG(
            to: url,
            extraProperties: [
                kCGImagePropertyIPTCDictionary: [:],
                kCGImagePropertyTIFFDictionary: [
                    kCGImagePropertyTIFFModel: "Test Camera E-M1",
                    kCGImagePropertyTIFFImageDescription: "fallback description",
                ],
            ])

        let reader = NativeMetadataReader()
        let metadata = try reader.readMetadata(at: url)
        let asset = reader.mapToPhotoAsset(url: url, metadata: metadata)

        XCTAssertEqual(asset.descriptionText, "fallback description")
    }

    func testMapToPhotoAssetFallsBackToFilenameStemWhenNoIPTCObjectName() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("P1010042")
            .appendingPathExtension("jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeSampleJPEG(to: url, extraProperties: [kCGImagePropertyIPTCDictionary: [:]])

        let reader = NativeMetadataReader()
        let metadata = try reader.readMetadata(at: url)
        let asset = reader.mapToPhotoAsset(url: url, metadata: metadata)

        XCTAssertEqual(asset.title, "P1010042")
    }

    func testMapToPhotoAssetReadsCaptureUTCOffset() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeSampleJPEG(
            to: url,
            extraProperties: [
                kCGImagePropertyExifDictionary: [
                    kCGImagePropertyExifDateTimeOriginal: "2026:10:18 15:03:00",
                    kCGImagePropertyExifOffsetTimeOriginal: "+01:00",
                ]
            ])

        let reader = NativeMetadataReader()
        let asset = reader.mapToPhotoAsset(url: url, metadata: try reader.readMetadata(at: url))

        XCTAssertEqual(asset.captureUTCOffsetSeconds, 3600)
    }

    func testUTCOffsetSecondsParsesSignedOffsetsAndRejectsJunk() {
        XCTAssertEqual(NativeMetadataReader.utcOffsetSeconds(fromExifOffset: "+01:00"), 3600)
        XCTAssertEqual(NativeMetadataReader.utcOffsetSeconds(fromExifOffset: "-07:00"), -25200)
        XCTAssertEqual(NativeMetadataReader.utcOffsetSeconds(fromExifOffset: "+05:30"), 19800)
        XCTAssertNil(NativeMetadataReader.utcOffsetSeconds(fromExifOffset: ""))
        XCTAssertNil(NativeMetadataReader.utcOffsetSeconds(fromExifOffset: "01:00"))
        XCTAssertNil(NativeMetadataReader.utcOffsetSeconds(fromExifOffset: "+1:00"))
    }

    func testExtractPreviewReturnsImageMatchingSourceDimensions() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeSampleJPEG(to: url)

        let reader = NativeMetadataReader()
        let preview = try reader.extractPreview(at: url, maxPixelSize: 512)

        XCTAssertEqual(preview.width, 1)
        XCTAssertEqual(preview.height, 1)
    }

    /// A grid's worth of concurrent calls, well past the ~20 that deadlocked RawCamera when these
    /// ran on the cooperative pool. A JPEG can't reproduce that deadlock; this proves the queue
    /// bridge returns every result rather than dropping or double-resuming a continuation.
    func testExtractPreviewAsyncCompletesManyConcurrentDecodes() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeSampleJPEG(to: url)

        let widths = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<100 {
                group.addTask { try await NativeMetadataReader().extractPreviewAsync(at: url, maxPixelSize: 256).width }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        XCTAssertEqual(widths, Array(repeating: 1, count: 100))
    }

    func testExtractPreviewAsyncThrowsForMissingFile() async {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("rw2")

        do {
            _ = try await NativeMetadataReader().extractPreviewAsync(at: missingURL)
            XCTFail("Expected an error for a missing file")
        } catch {}
    }

    func testReadMetadataThrowsForMissingFile() {
        let reader = NativeMetadataReader()
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("orf")

        XCTAssertThrowsError(try reader.readMetadata(at: missingURL))
    }
}
