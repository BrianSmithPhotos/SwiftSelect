import XCTest

@testable import SwiftSelectCore

final class WriteBackOptionsTests: XCTestCase {

    func testAnOrdinaryLaunchIsNotAWriteBackRun() throws {
        // A double-clicked .app is handed argv it never asked for, and must open its window rather
        // than fail on it.
        XCTAssertNil(try WriteBackOptions.parse(arguments: ["SwiftSelect"]))
        XCTAssertNil(try WriteBackOptions.parse(arguments: ["SwiftSelect", "-NSDocumentRevisionsDebugMode", "YES"]))
        XCTAssertNil(try WriteBackOptions.parse(arguments: ["SwiftSelect", "/some/folder"]))
    }

    func testTheVerbWithItsTwoRequiredPaths() throws {
        let options = try XCTUnwrap(WriteBackOptions.parse(arguments: [
            "SwiftSelect", "writeback", "--manifest", "/m.jsonl", "--log", "/logs",
        ]))
        XCTAssertEqual(options.manifest, "/m.jsonl")
        XCTAssertEqual(options.logDirectory, "/logs")
        XCTAssertNil(options.quiet)
        XCTAssertNil(options.limit)
        XCTAssertFalse(options.dryRun)
    }

    func testTheOptionalOnes() throws {
        let options = try XCTUnwrap(WriteBackOptions.parse(arguments: [
            "SwiftSelect", "writeback", "--manifest", "/m.jsonl", "--log", "/logs",
            "--quiet", "17:00-21:30", "--limit", "25", "--dry-run",
        ]))
        XCTAssertEqual(options.quiet, "17:00-21:30")
        XCTAssertEqual(options.limit, 25)
        XCTAssertTrue(options.dryRun)
    }

    func testWorkersDefaultsToOneSoTheWirelessRunIsUnchanged() throws {
        let options = try XCTUnwrap(WriteBackOptions.parse(arguments: [
            "SwiftSelect", "writeback", "--manifest", "/m.jsonl", "--log", "/logs",
        ]))
        XCTAssertEqual(options.workers, 1)
    }

    func testWorkersIsRead() throws {
        let options = try XCTUnwrap(WriteBackOptions.parse(arguments: [
            "SwiftSelect", "writeback", "--manifest", "/m.jsonl", "--log", "/logs",
            "--workers", "8",
        ]))
        XCTAssertEqual(options.workers, 8)
    }

    func testWorkersMustBeAPositiveNumber() {
        // Zero would mean a run that dispatches nothing and reports itself finished.
        for bad in ["0", "-2", "lots", ""] {
            XCTAssertThrowsError(try WriteBackOptions.parse(arguments: [
                "SwiftSelect", "writeback", "--manifest", "/m.jsonl", "--log", "/logs",
                "--workers", bad,
            ]), "--workers \(bad) should be refused")
        }
    }

    func testBothPathsAreRequired() {
        XCTAssertThrowsError(try WriteBackOptions.parse(arguments: ["SwiftSelect", "writeback"]))
        XCTAssertThrowsError(try WriteBackOptions.parse(
            arguments: ["SwiftSelect", "writeback", "--manifest", "/m.jsonl"]))
        XCTAssertThrowsError(try WriteBackOptions.parse(
            arguments: ["SwiftSelect", "writeback", "--log", "/logs"]))
    }

    func testAFlagWithNoValueIsRefusedRatherThanIgnored() {
        // "--manifest --log /logs" must not quietly write to a file called --log.
        XCTAssertThrowsError(try WriteBackOptions.parse(
            arguments: ["SwiftSelect", "writeback", "--manifest", "/m.jsonl", "--log"]))
    }

    func testAnUnknownArgumentStopsTheRun() {
        // Once the verb is given, a mistyped flag is a mistake worth refusing: the alternative is a
        // days-long run that silently ignored --quiet and walked onto the NAS at teatime.
        XCTAssertThrowsError(try WriteBackOptions.parse(arguments: [
            "SwiftSelect", "writeback", "--manifest", "/m.jsonl", "--log", "/logs", "--quite", "x",
        ])) { error in
            XCTAssertEqual(error as? WriteBackOptionsError, .unknownArgument("--quite"))
        }
    }

    func testALimitMustBeAPositiveNumber() {
        for bad in ["0", "-5", "lots", ""] {
            XCTAssertThrowsError(try WriteBackOptions.parse(arguments: [
                "SwiftSelect", "writeback", "--manifest", "/m.jsonl", "--log", "/l", "--limit", bad,
            ]), "accepted \(bad)")
        }
    }
    func testTheBytesAreGivenBackUnlessKeepLocalIsAsked() throws {
        let ordinary = try WriteBackOptions.parse(
            arguments: ["SwiftSelect", "writeback", "--manifest", "m", "--log", "l"])
        XCTAssertEqual(ordinary?.keepLocal, false)
        let batched = try WriteBackOptions.parse(
            arguments: ["SwiftSelect", "writeback", "--manifest", "m", "--log", "l",
                        "--keep-local"])
        XCTAssertEqual(batched?.keepLocal, true)
    }
}
