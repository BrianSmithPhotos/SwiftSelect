import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import SwiftSelect
@testable import SwiftSelectCore

final class PhotoAssetLoaderTests: XCTestCase {
    /// Same synthesis approach as `NativeMetadataReaderTests` — a real, tiny in-memory JPEG so
    /// this test needs no external fixture.
    private func writeSampleJPEG(to url: URL) throws {
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
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    func testLoadAssetsSkipsUnsupportedExtensionsAndUnreadableFiles() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        try writeSampleJPEG(to: folder.appendingPathComponent("real.jpg"))
        // Not a real JPEG despite the extension — exercises the "skip, don't fail the batch" path.
        try Data("not an image".utf8).write(to: folder.appendingPathComponent("corrupt.jpg"))
        // Unsupported extension — must be filtered out before any read is attempted.
        try Data("hello".utf8).write(to: folder.appendingPathComponent("notes.txt"))

        let assets = try await PhotoAssetLoader().loadAssets(in: folder)

        XCTAssertEqual(assets.map(\.url.lastPathComponent), ["real.jpg"])
    }

    /// The two sets have to stay in step — `supportedExtensions` is what the folder scan filters on
    /// and `rawExtensions` is what `RawDevelopService` offers to `CIRAWFilter`, so a RAW format
    /// reachable by one but not the other would either be unbrowsable or undevelopable.
    func testRawExtensionsAreAllSupportedAndRecognisedAsRaw() {
        XCTAssertTrue(PhotoAssetLoader.rawExtensions.isSubset(of: PhotoAssetLoader.supportedExtensions))
        XCTAssertEqual(PhotoAssetLoader.rawExtensions, ["orf", "ori", "raf", "rw2"])

        XCTAssertTrue(PhotoAssetLoader.isRaw(URL(fileURLWithPath: "/x/P1010042.ORF")))
        // The original beside a hi-res composite, which shares its frame's stem and so has to be
        // loaded with it rather than left on the card.
        XCTAssertTrue(PhotoAssetLoader.isRaw(URL(fileURLWithPath: "/x/P1010042.ORI")))
        XCTAssertTrue(PhotoAssetLoader.isRaw(URL(fileURLWithPath: "/x/DSCF5072.RAF")))
        XCTAssertTrue(PhotoAssetLoader.isRaw(URL(fileURLWithPath: "/x/P1000001.RW2")))
        XCTAssertFalse(PhotoAssetLoader.isRaw(URL(fileURLWithPath: "/x/P1010042.JPG")))
    }

    /// Same pairing as the RAW check above: the folder scan filters on `supportedExtensions`, and
    /// everything downstream asks `isVideo` which route a file takes, so the two must agree.
    func testVideoExtensionsAreAllSupportedAndRecognisedAsVideo() {
        XCTAssertTrue(PhotoAssetLoader.videoExtensions.isSubset(of: PhotoAssetLoader.supportedExtensions))
        XCTAssertEqual(PhotoAssetLoader.videoExtensions, ["mov", "mp4"])
        for extension_ in PhotoAssetLoader.videoExtensions {
            XCTAssertTrue(PhotoAssetLoader.isVideo(URL(fileURLWithPath: "/card/H1076833.\(extension_)")))
        }
    }

    /// The camera writes `.MOV` in caps.
    func testVideoRecognitionIsCaseInsensitive() {
        XCTAssertTrue(PhotoAssetLoader.isVideo(URL(fileURLWithPath: "/card/H1076833.MOV")))
        XCTAssertFalse(PhotoAssetLoader.isVideo(URL(fileURLWithPath: "/card/P1010042.ORF")))
    }

    func testLoadAssetsReturnsEmptyArrayForFolderWithNoSupportedFiles() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        try Data("hello".utf8).write(to: folder.appendingPathComponent("notes.txt"))

        let assets = try await PhotoAssetLoader().loadAssets(in: folder)

        XCTAssertTrue(assets.isEmpty)
    }

    /// The shape the Mac app's iPad import meets: a processed-library tree, with JPEGs one level
    /// deeper than their RAW siblings (`ProcessMoveService.destinationDirectory`) and an `.xmp`
    /// sidecar next to each image that must not be mistaken for one.
    func testLoadAssetsInTreeDescendsIntoMonthDayAndJPGFolders() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let dayFolder = root.appendingPathComponent("6 June").appendingPathComponent("21")
        let jpgFolder = dayFolder.appendingPathComponent("jpg")
        try FileManager.default.createDirectory(at: jpgFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try writeSampleJPEG(to: dayFolder.appendingPathComponent("1010042_20260621_1405_OM-1_12-40mm.jpg"))
        try writeSampleJPEG(to: jpgFolder.appendingPathComponent("1010043_20260621_1406_OM-1_12-40mm.jpg"))
        try Data("<x:xmpmeta/>".utf8)
            .write(to: dayFolder.appendingPathComponent("1010042_20260621_1405_OM-1_12-40mm.xmp"))

        let assets = try await PhotoAssetLoader().loadAssets(inTree: root)

        XCTAssertEqual(
            assets.map(\.url.lastPathComponent),
            [
                "1010042_20260621_1405_OM-1_12-40mm.jpg",
                "1010043_20260621_1406_OM-1_12-40mm.jpg",
            ])
    }

    func testLoadAssetsInTreeThrowsForAFolderThatIsNotThere() async throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        do {
            _ = try await PhotoAssetLoader().loadAssets(inTree: missing)
            XCTFail("Expected an unreadableFolder error")
        } catch {
            XCTAssertEqual(error as? PhotoAssetLoaderError, .unreadableFolder(missing))
        }
    }

    func testLoadAssetsReadsEveryFileWhenCountExceedsTheConcurrencyCap() async throws {
        // Deliberately more files than any plausible core count, to exercise the "refill the
        // queue as a child task finishes" bookkeeping in readAssets(at:) rather than just the
        // initial batch of concurrent reads.
        let fileCount = ProcessInfo.processInfo.activeProcessorCount * 3 + 5
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        var expectedNames: Set<String> = []
        for index in 0..<fileCount {
            let name = String(format: "photo-%03d.jpg", index)
            try writeSampleJPEG(to: folder.appendingPathComponent(name))
            expectedNames.insert(name)
        }

        let assets = try await PhotoAssetLoader().loadAssets(in: folder)

        XCTAssertEqual(assets.count, fileCount)
        XCTAssertEqual(Set(assets.map(\.url.lastPathComponent)), expectedNames)
    }

    // MARK: - Capture UTC offset

    /// 2026-10-18 15:03:00 on the camera's clock, read the way `NativeMetadataReader` reads it: as
    /// this device's local time, whatever zone the test machine is in.
    private static let cameraWallClock: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 15, minute: 3))!
    }()

    /// The same wall clock as a real instant on a camera set to UTC+1: 14:03:00 UTC.
    private static let trueInstantUTC = 1_792_332_180

    private func asset(_ name: String, offset: Int? = nil) -> PhotoAsset {
        var asset = PhotoAsset(id: URL(fileURLWithPath: "/card/DCIM/\(name)"))
        asset.capturedAt = Self.cameraWallClock
        asset.captureUTCOffsetSeconds = offset
        return asset
    }

    func testCaptureTimestampUTCAppliesTheCameraOffset() {
        XCTAssertEqual(asset("P1010434.JPG", offset: 3600).captureTimestampUTC, Self.trueInstantUTC)
    }

    func testCaptureTimestampUTCWithoutOffsetKeepsTheWallClockAsRead() {
        XCTAssertEqual(
            asset("P1010434.RW2").captureTimestampUTC, Int(Self.cameraWallClock.timeIntervalSince1970))
    }

    func testRAWTakesTheOffsetOfItsSameNamedJPEG() {
        let filled = PhotoAssetLoader.fillingCaptureOffsetsFromSiblings([
            asset("P1010434.RW2"), asset("P1010434.JPG", offset: 3600), asset("P1010435.RW2"),
        ])

        XCTAssertEqual(filled.map(\.captureUTCOffsetSeconds), [3600, 3600, nil])
        XCTAssertEqual(filled[0].captureTimestampUTC, Self.trueInstantUTC)
    }

    /// A reused filename from another shoot shares the stem but not the capture time.
    func testSiblingWithADifferentCaptureTimeLendsNoOffset() {
        var other = asset("P1010434.JPG", offset: 3600)
        other.capturedAt = Self.cameraWallClock.addingTimeInterval(60)

        let filled = PhotoAssetLoader.fillingCaptureOffsetsFromSiblings([asset("P1010434.RW2"), other])

        XCTAssertNil(filled[0].captureUTCOffsetSeconds)
    }
}
