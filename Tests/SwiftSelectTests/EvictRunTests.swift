import XCTest

@testable import SwiftSelect
@testable import SwiftSelectCore

final class EvictRunTests: XCTestCase {

    // MARK: - what gets handed back

    func testAFileTheProviderHoldsGivesItsBytesBack() {
        var subject = EvictRun()
        subject.presence = { _ in .present }
        subject.uploaded = { _ in true }
        var given: [String] = []
        subject.evict = { given.append($0) }
        let outcome = subject.run(paths: ["/icloud/a.jpg", "/icloud/b.jpg"])
        XCTAssertEqual(given, ["/icloud/a.jpg", "/icloud/b.jpg"])
        XCTAssertEqual(outcome.gaveBack, 2)
    }

    func testANasFileIsNeverTouched() {
        // There is no provider holding it, so giving back its bytes would be a delete - and nothing
        // in this project deletes a photograph.
        var subject = EvictRun()
        subject.presence = { _ in .notCloud }
        subject.uploaded = { _ in XCTFail("asked the provider about a file with no provider"); return false }
        subject.evict = { XCTFail("evicted \($0), which is not in a cloud provider") }
        let outcome = subject.run(paths: ["/Volumes/Photos/a.RAF"])
        XCTAssertEqual(outcome.notCloud, 1)
        XCTAssertEqual(outcome.gaveBack, 0)
    }

    func testAPlaceholderIsLeftAsItIs() {
        var subject = EvictRun()
        subject.presence = { _ in .evicted }
        subject.evict = { XCTFail("evicted \($0), which is already a placeholder") }
        let outcome = subject.run(paths: ["/icloud/a.jpg"])
        XCTAssertEqual(outcome.alreadyGone, 1)
        XCTAssertEqual(outcome.gaveBack, 0)
    }

    func testBytesStayWhileTheProviderHasNotTakenTheChange() {
        // The one thing this must never do: drop the only copy of a rewrite.
        var subject = EvictRun()
        subject.presence = { _ in .present }
        subject.uploaded = { _ in false }
        subject.evict = { XCTFail("evicted \($0) before the provider had it") }
        let outcome = subject.run(paths: ["/icloud/a.jpg"])
        XCTAssertEqual(outcome.notTakenYet, 1)
        XCTAssertEqual(outcome.gaveBack, 0)
    }

    func testARefusalIsCountedAndReported() {
        var subject = EvictRun()
        subject.presence = { _ in .present }
        subject.uploaded = { _ in true }
        subject.evict = { _ in throw CocoaError(.fileWriteNoPermission) }
        let outcome = subject.run(paths: ["/icloud/a.jpg"])
        XCTAssertEqual(outcome.refused, 1)
        XCTAssertEqual(outcome.gaveBack, 0)
        XCTAssertNotNil(outcome.refusal)
    }

    func testOneRefusalDoesNotStopTheBatch() {
        var subject = EvictRun()
        subject.presence = { _ in .present }
        subject.uploaded = { _ in true }
        subject.evict = { path in
            if path == "/icloud/bad.jpg" { throw CocoaError(.fileWriteNoPermission) }
        }
        let outcome = subject.run(paths: ["/icloud/bad.jpg", "/icloud/a.jpg", "/icloud/b.jpg"])
        XCTAssertEqual(outcome.gaveBack, 2)
        XCTAssertEqual(outcome.refused, 1)
    }

    func testADryRunHandsNothingBack() {
        var subject = EvictRun()
        subject.presence = { _ in .present }
        subject.uploaded = { _ in true }
        subject.evict = { XCTFail("evicted \($0) on a dry run") }
        subject.dryRun = true
        let outcome = subject.run(paths: ["/icloud/a.jpg"])
        XCTAssertEqual(outcome.gaveBack, 1)
    }

    // MARK: - the arguments

    func testTheVerbIsRecognisedWithItsManifest() throws {
        let options = try EvictOptions.parse(arguments: ["SwiftSelect", "evict",
                                                         "--manifest", "batch.jsonl"])
        XCTAssertEqual(options, EvictOptions(manifest: "batch.jsonl"))
    }

    func testADryRunIsAsked() throws {
        let options = try EvictOptions.parse(arguments: ["SwiftSelect", "evict",
                                                         "--manifest", "b.jsonl", "--dry-run"])
        XCTAssertEqual(options?.dryRun, true)
    }

    func testAnythingElseIsNotThisVerbAtAll() throws {
        // A double-clicked .app is handed argv it never asked for and must open its window.
        XCTAssertNil(try EvictOptions.parse(arguments: ["SwiftSelect"]))
        XCTAssertNil(try EvictOptions.parse(arguments: ["SwiftSelect", "writeback",
                                                        "--manifest", "m", "--log", "l"]))
        XCTAssertNil(try EvictOptions.parse(arguments: ["SwiftSelect", "-NSDocumentRevisions", "YES"]))
    }

    func testAManifestIsRequired() {
        XCTAssertThrowsError(try EvictOptions.parse(arguments: ["SwiftSelect", "evict"])) { error in
            XCTAssertEqual(error as? WriteBackOptionsError, .missingValue("--manifest"))
        }
    }

    func testAnUnknownArgumentIsRefusedRatherThanIgnored() {
        XCTAssertThrowsError(try EvictOptions.parse(
            arguments: ["SwiftSelect", "evict", "--manifest", "m", "--force"])) { error in
            XCTAssertEqual(error as? WriteBackOptionsError, .unknownArgument("--force"))
        }
    }
}
