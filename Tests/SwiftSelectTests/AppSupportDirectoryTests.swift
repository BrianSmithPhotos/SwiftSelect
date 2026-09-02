import XCTest

@testable import SwiftSelectCore

/// The 2026-09 rename moves the folder holding everything the app remembers between launches. It
/// runs once, unattended, against real user state that cannot be rebuilt, so the cases where it
/// must do nothing matter as much as the one where it moves.
final class AppSupportDirectoryTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: self.base) }
    }

    func testTheOldFolderIsRenamedWithItsContents() throws {
        try write("skip_state.sqlite3", "state", in: AppSupportDirectory.previousDirectoryName)

        try AppSupportDirectory.migrateIfNeeded(in: base)

        XCTAssertEqual(try read("skip_state.sqlite3", in: AppSupportDirectory.directoryName), "state")
        XCTAssertFalse(exists(AppSupportDirectory.previousDirectoryName))
    }

    /// The dangerous case. Both folders exist only if the renamed app has already run and written
    /// state of its own, so the old one is the stale copy — moving it over the top would discard
    /// every mark made since the rename.
    func testAnExistingNewFolderIsNeverOverwritten() throws {
        try write("skip_state.sqlite3", "old", in: AppSupportDirectory.previousDirectoryName)
        try write("skip_state.sqlite3", "current", in: AppSupportDirectory.directoryName)

        try AppSupportDirectory.migrateIfNeeded(in: base)

        XCTAssertEqual(try read("skip_state.sqlite3", in: AppSupportDirectory.directoryName), "current")
        XCTAssertTrue(exists(AppSupportDirectory.previousDirectoryName), "the old folder is left to be inspected")
    }

    /// The iPad case, and every launch after the first: nothing to move, and no error for it.
    func testNothingToMoveIsNotAnError() throws {
        XCTAssertNoThrow(try AppSupportDirectory.migrateIfNeeded(in: base))
        XCTAssertFalse(exists(AppSupportDirectory.directoryName), "migration must not create the folder itself")
    }

    /// Running twice has to be as safe as running once — the static that fires it is per process,
    /// and the app is launched repeatedly.
    func testMigratingTwiceLeavesTheMovedStateAlone() throws {
        try write("skip_state.sqlite3", "state", in: AppSupportDirectory.previousDirectoryName)

        try AppSupportDirectory.migrateIfNeeded(in: base)
        try AppSupportDirectory.migrateIfNeeded(in: base)

        XCTAssertEqual(try read("skip_state.sqlite3", in: AppSupportDirectory.directoryName), "state")
    }

    private func write(_ fileName: String, _ contents: String, in directoryName: String) throws {
        let directory = base.appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try contents.write(to: directory.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
    }

    private func read(_ fileName: String, in directoryName: String) throws -> String {
        try String(contentsOf: base.appendingPathComponent(directoryName).appendingPathComponent(fileName),
                   encoding: .utf8)
    }

    private func exists(_ directoryName: String) -> Bool {
        FileManager.default.fileExists(atPath: base.appendingPathComponent(directoryName).path)
    }
}
