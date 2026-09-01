import Foundation

/// The copy check docs/SPEC.md's "Copy verification" working assumption demands: size, then a
/// SHA-256 of both files. Shared by `ProcessMoveService` and `VideoMoveService` so the rule that
/// decides a source file is safely handled exists in exactly one place, whichever destination the
/// file was headed for.
public enum CopyVerification {
    public static func verify(source: URL, destination: URL) throws {
        let sourceSize = try fileSize(at: source)
        let destinationSize = try fileSize(at: destination)
        guard sourceSize == destinationSize else {
            throw ProcessMoveError.copySizeMismatch(source: source, destination: destination)
        }
        guard try FileHashing.sha256(of: source) == FileHashing.sha256(of: destination) else {
            throw ProcessMoveError.copyChecksumMismatch(source: source, destination: destination)
        }
    }

    private static func fileSize(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? Int) ?? 0
    }
}
