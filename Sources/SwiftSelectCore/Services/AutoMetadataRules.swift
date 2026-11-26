import Foundation

/// Metadata rules applied only at write time (save/process), never shown live in the editable
/// fields — docs/SPEC.md §6: "a 'straight out of camera' keyword on unedited JPEGs, and an appended
/// note when an in-camera filter/effect was active." Ported from the Python reference app's
/// `services/auto_metadata.py`; pure functions so `SourceBrowserViewModel.saveMetadata` and
/// `ProcessMoveService.processAndCopy` can both apply them without any shared I/O state, mirroring
/// `MetadataEditParsing`'s split.
public enum AutoMetadataRules {
    private static let soocJPEGExtensions: Set<String> = ["jpg", "jpeg"]

    /// `"sooc"` for an unedited JPEG (this app never edits pixels, so any JPEG on disk is
    /// straight-out-of-camera by definition), else empty.
    public static func soocToken(for url: URL) -> String {
        soocJPEGExtensions.contains(url.pathExtension.lowercased()) ? "sooc" : ""
    }

    /// The rule above, minus its one exception: a `RawDevelopService` output is a JPEG by extension
    /// but emphatically not straight out of camera — Apple's RAW engine rendered it, which is the
    /// whole reason it exists.
    public static func soocToken(for asset: PhotoAsset) -> String {
        isDeveloped(asset) ? "" : soocToken(for: asset.url)
    }

    /// A `RawDevelopService` output, recognised by `derivedFrom` where the original is known, or by
    /// its decoder keyword where it isn't: a JPEG developed on the iPad reaches the Mac's import as
    /// a plain `.jpg`, and `RAW9` in its keywords is the only trace of how it was made.
    static func isDeveloped(_ asset: PhotoAsset) -> Bool {
        asset.derivedFrom != nil || RawDevelopService.token(in: asset.keywords) != nil
    }

    /// The in-camera look string for Instructions, or empty when the file never received that
    /// rendering.
    ///
    /// A RAW carries the look's *readings* but not the look. Measured on a real pair
    /// (H1071885.JPG/.ORF, 2026-08-09): the files differ in exactly one tag — `PictureMode` reverts
    /// to `"Natural"` in the ORF — while `ColorCreatorEffect` is byte-for-byte identical in both. So
    /// the parser legitimately returns a full look for an ORF, and writing it would annotate the
    /// file with a rendering Apple's engine never applied, since it does not read Olympus maker
    /// notes. A `RawDevelopService` output is the same story one step on, which is why it shares
    /// `soocToken(for:)`'s `derivedFrom` test: a JPEG by extension, but Apple's rendering of the
    /// RAW rather than the camera's.
    public static func cameraLookInstructions(for asset: PhotoAsset) -> String {
        guard !PhotoAssetLoader.isRaw(asset.url), !isDeveloped(asset) else { return "" }
        return asset.cameraLookSummary
    }

    /// The decoder token (`RAW9`) a developed JPEG must keep through a save, or `nil` for any
    /// other file.
    ///
    /// The token is the only record of which decoder rendered the file, and it lives in the
    /// keywords, which a save replaces wholesale. An AI suggestion fills the editor with a fresh
    /// list that has no token in it, so without this the save erased it and the processed file
    /// lost `RAW9` from its name, landing on the camera JPEG's name with a `_1` suffix.
    public static func developToken(for asset: PhotoAsset) -> String? {
        guard asset.derivedFrom != nil else { return nil }
        return RawDevelopService.token(in: asset.keywords)
    }

    /// Appends develop/camera/lens/art-filter/SOOC tokens to `keywords`, case-insensitively
    /// de-duplicated against each other. Blank tokens are skipped.
    ///
    /// A keyword matching a token apart from case takes the token's own spelling, in place. AI
    /// providers are fed the existing keywords and asked for lowercase ones, so they echo `RAW9`
    /// back as `raw9`; keeping whichever came first left the AI's spelling on the file.
    public static func keywordsWithAutoTokens(
        _ keywords: [String], developToken: String? = nil, artFilterToken: String?,
        cameraToken: String?, lensToken: String?, soocToken: String
    ) -> [String] {
        let tokens = [developToken ?? "", artFilterToken ?? "", cameraToken ?? "", lensToken ?? "", soocToken]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        // First spelling wins among the tokens themselves, matching the old de-duplication.
        var tokenByLowercased: [String: String] = [:]
        for token in tokens where tokenByLowercased[token.lowercased()] == nil {
            tokenByLowercased[token.lowercased()] = token
        }
        var seenLowercased = Set<String>()
        var result: [String] = []
        for keyword in keywords + tokens where seenLowercased.insert(keyword.lowercased()).inserted {
            result.append(tokenByLowercased[keyword.lowercased()] ?? keyword)
        }
        return result
    }

    /// Appends `"In camera effect <token>."` to `description`, skipping if that exact note is
    /// already present (re-saving shouldn't duplicate it) or if there's no active filter token.
    public static func descriptionWithArtFilterNote(_ description: String, artFilterToken: String?) -> String {
        let trimmedToken = (artFilterToken ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else { return description }
        let note = "In camera effect \(trimmedToken)."
        guard !description.contains(note) else { return description }
        return description.isEmpty ? note : "\(description) \(note)"
    }

    /// The description with any effect note taken out - only what a person or the AI wrote. Every
    /// save adds the note, even with an empty description, so a GPS-only save leaves note-only text.
    public static func descriptionWithoutArtFilterNote(_ description: String) -> String {
        description.replacing(#/In camera effect [^.]+\./#, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
