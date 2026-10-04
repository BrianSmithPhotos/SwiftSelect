import XCTest

@testable import SwiftSelectCore

final class ShotIdentityTests: XCTestCase {
    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name)") }

    func testFrameNumberFromACardFilenameDropsTheMonthLetter() {
        XCTAssertEqual(ShotIdentity.frameNumber(from: url("H1085082.ORF")), "1085082")
    }

    func testFrameNumberFromARenamedFileIgnoresTheDateAndTime() {
        let renamed = url("1085082_SanRafael_20260927_1909_OM-3_OLYMPUS-M.12mm-F2.0.orf")

        XCTAssertEqual(ShotIdentity.frameNumber(from: renamed), "1085082")
    }

    func testFrameNumberIsTheSameForADxOExportOfTheSameFrame() {
        let export = url("1085082_SanRafael_20260927_1909_OM-3_OLYMPUS-M.12mm-F2.0_Nik.tif")

        XCTAssertEqual(ShotIdentity.frameNumber(from: export), "1085082")
    }

    func testFrameNumberIsNilWithoutDigits() {
        XCTAssertNil(ShotIdentity.frameNumber(from: url("export.jpg")))
    }

    func testShotIDJoinsSerialAndFrame() {
        XCTAssertEqual(
            ShotIdentity.shotID(serial: "BJSA13381", url: url("H1085082.ORF")), "BJSA13381-1085082")
    }

    func testShotIDMatchesBeforeAndAfterRename() {
        let card = ShotIdentity.shotID(serial: "BJSA13381", url: url("H1085082.JPG"))
        let renamed = ShotIdentity.shotID(
            serial: "BJSA13381", url: url("1085082_SanRafael_20260927_1909_OM-3.jpg"))

        XCTAssertEqual(card, renamed)
    }

    func testShotIDTrimsTheSerial() {
        XCTAssertEqual(
            ShotIdentity.shotID(serial: " BJSA13381 ", url: url("H1085082.ORF")),
            "BJSA13381-1085082")
    }

    func testShotIDIsNilWithoutASerial() {
        XCTAssertNil(ShotIdentity.shotID(serial: "", url: url("H1085082.ORF")))
        XCTAssertNil(ShotIdentity.shotID(serial: "  ", url: url("H1085082.ORF")))
    }

    func testShotIDIsNilWithoutAFrameNumber() {
        XCTAssertNil(ShotIdentity.shotID(serial: "BJSA13381", url: url("export.jpg")))
    }

    func testSetIDIsTheLowestFrameOfARenderingBracket() {
        let members = [url("H1078921.JPG"), url("H1078918.ORF"), url("H1078919.JPG")]

        XCTAssertEqual(
            ShotIdentity.setID(serial: "BJSA13381", memberURLs: members), "BJSA13381-1078918")
    }

    func testSetIDComparesFramesAsNumbersNotText() {
        let members = [url("1000_a.jpg"), url("999_a.jpg")]

        XCTAssertEqual(ShotIdentity.setID(serial: "S", memberURLs: members), "S-999")
    }

    func testSetIDSkipsAMemberWithNoFrameNumber() {
        let members = [url("export.jpg"), url("H1078918.ORF")]

        XCTAssertEqual(
            ShotIdentity.setID(serial: "BJSA13381", memberURLs: members), "BJSA13381-1078918")
    }

    func testSetIDIsNilForAnEmptySet() {
        XCTAssertNil(ShotIdentity.setID(serial: "BJSA13381", memberURLs: []))
    }

    // MARK: - tags(for:)

    private func asset(_ name: String, serial: String = "BJSA13381", derivedFrom: String? = nil)
        -> PhotoAsset
    {
        var asset = PhotoAsset(id: url(name))
        asset.cameraSerial = serial
        asset.derivedFrom = derivedFrom.map(url)
        return asset
    }

    private func tags(_ members: [PhotoAsset]) -> [String: ShotTags] {
        let byID = ShotIdentity.tags(for: members)
        return Dictionary(
            uniqueKeysWithValues: byID.map { ($0.key.lastPathComponent, $0.value) })
    }

    func testARawAndItsJPEGShareOneShot() {
        let result = tags([asset("H1085082.ORF"), asset("H1085082.JPG")])

        let expected = ShotTags(
            documentID: "BJSA13381-1085082", originalDocumentID: "BJSA13381-1085082",
            setID: "BJSA13381-1085082")
        XCTAssertEqual(result["H1085082.ORF"], expected)
        XCTAssertEqual(result["H1085082.JPG"], expected)
    }

    func testFilterJPEGsInARenderingBracketPointAtTheOneRaw() {
        let result = tags([asset("H1078918.ORF"), asset("H1078918.JPG"), asset("H1078919.JPG")])

        XCTAssertEqual(
            result["H1078919.JPG"],
            ShotTags(
                documentID: "BJSA13381-1078919", originalDocumentID: "BJSA13381-1078918",
                setID: "BJSA13381-1078918"))
    }

    func testABurstFramePointsAtItsOwnRawNotANeighbour() {
        let result = tags([
            asset("H1000001.ORF"), asset("H1000001.JPG"), asset("H1000002.ORF"),
            asset("H1000002.JPG"),
        ])

        XCTAssertEqual(result["H1000002.JPG"]?.originalDocumentID, "BJSA13381-1000002")
        XCTAssertEqual(result["H1000002.JPG"]?.setID, "BJSA13381-1000001")
    }

    func testACompositeAmongManyRawsIsItsOwnParent() {
        let result = tags([asset("H1000001.ORF"), asset("H1000002.ORF"), asset("H1000003.JPG")])

        XCTAssertEqual(result["H1000003.JPG"]?.originalDocumentID, "BJSA13381-1000003")
    }

    func testAJPEGOnlySetIsItsOwnParent() {
        let result = tags([asset("H1000001.JPG")])

        XCTAssertEqual(result["H1000001.JPG"]?.originalDocumentID, "BJSA13381-1000001")
    }

    func testADevelopedJPEGTakesItsFrameFromItsOriginal() {
        let developed = asset("staging-20260927-abc.jpg", derivedFrom: "H1085082.ORF")

        let result = tags([asset("H1085082.ORF"), developed])

        XCTAssertEqual(result["staging-20260927-abc.jpg"]?.documentID, "BJSA13381-1085082")
        XCTAssertEqual(result["staging-20260927-abc.jpg"]?.originalDocumentID, "BJSA13381-1085082")
    }

    func testOneMembersSerialServesTheWholeSet() {
        let result = tags([asset("H1085082.ORF"), asset("H1085082.JPG", serial: "")])

        XCTAssertEqual(result["H1085082.JPG"]?.documentID, "BJSA13381-1085082")
    }

    func testNoSerialMeansNoTags() {
        XCTAssertTrue(tags([asset("H1085082.ORF", serial: "")]).isEmpty)
    }

    // MARK: - tags(forSets:cameraSets:)

    func testAMergeChangesTheSetIDButNotTheParent() {
        let first = [asset("H1000001.ORF"), asset("H1000001.JPG"), asset("H1000002.JPG")]
        let second = [asset("H1000009.ORF"), asset("H1000009.JPG"), asset("H1000010.JPG")]

        let byID = ShotIdentity.tags(forSets: [first + second], cameraSets: [first, second])
        let result = Dictionary(
            uniqueKeysWithValues: byID.map { ($0.key.lastPathComponent, $0.value) })

        XCTAssertEqual(
            result["H1000010.JPG"],
            ShotTags(
                documentID: "BJSA13381-1000010", originalDocumentID: "BJSA13381-1000009",
                setID: "BJSA13381-1000001"))
        XCTAssertEqual(result["H1000002.JPG"]?.originalDocumentID, "BJSA13381-1000001")
    }

    func testUnmergedSetsMatchThePerSetRule() {
        let set = [asset("H1078918.ORF"), asset("H1078919.JPG")]

        XCTAssertEqual(
            ShotIdentity.tags(forSets: [set], cameraSets: [set]), ShotIdentity.tags(for: set))
    }

    // MARK: - applyingSerials

    private func modelAsset(_ name: String, model: String, serial: String = "") -> PhotoAsset {
        var asset = PhotoAsset(id: url(name))
        asset.cameraModel = model
        asset.cameraSerial = serial
        return asset
    }

    func testASerialIsFilledInFromTheModelTable() {
        let filled = ShotIdentity.applyingSerials(
            ["OM-3": "BJSA13381"], to: [modelAsset("H1085082.ORF", model: "OM-3")])

        XCTAssertEqual(ShotIdentity.tags(for: filled).values.first?.documentID, "BJSA13381-1085082")
    }

    func testTheModelMatchIgnoresCaseAndPadding() {
        let filled = ShotIdentity.applyingSerials(
            [" om-3 ": "BJSA13381"], to: [modelAsset("H1085082.ORF", model: "OM-3")])

        XCTAssertEqual(filled.first?.cameraSerial, "BJSA13381")
    }

    func testAModelWithNoEntryGetsNoIDs() {
        let filled = ShotIdentity.applyingSerials(
            ["OM-3": "BJSA13381"], to: [modelAsset("P1010001.ORF", model: "E-M1MarkII")])

        XCTAssertTrue(ShotIdentity.tags(for: filled).isEmpty)
    }

    func testASerialReadFromTheFileIsKept() {
        let filled = ShotIdentity.applyingSerials(
            ["OM-3": "WRONG"], to: [modelAsset("H1085082.ORF", model: "OM-3", serial: "BJSA13381")])

        XCTAssertEqual(filled.first?.cameraSerial, "BJSA13381")
    }
}
