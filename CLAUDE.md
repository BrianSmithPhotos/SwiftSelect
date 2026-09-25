# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Project

SwiftSelect (Swift): a from-scratch Swift/SwiftUI reimplementation of the Python/PySide6
sibling app [`phototags`](https://github.com/BrianSmithPhotos/phototags) — taken on as a way to
learn Swift and SwiftUI, not a line-by-line port. Read `docs/SPEC.md` (what the app should do) and
`docs/ARCHITECTURE.md` (where code should live) before starting work — both are self-contained; you
don't need the Python repo open to work here, though it's useful as a reference implementation to
compare against for logic that's being ported (e.g. Timeline JSON parsing, GPS matching).

## Stack & Tooling

- macOS 15+ / iOS 27+, Swift 5.10, SwiftUI. `swift build` / `swift run` / `swift test` from the repo root, or
  open `Package.swift` directly in Xcode. `Package.swift` itself declares `swift-tools-version: 6.1`
  (required for `mlx-swift-lm`'s macro target) but pins `swiftLanguageModes: [.v5]`, so the app's own
  code still writes and behaves like Swift 5.10 — the manifest-format bump isn't a language bump.
- `exiftool` on `PATH` (`brew install exiftool`) — all metadata read/write goes through it via
  `Process`, same as the Python sibling app. See `ExifToolClient` and `docs/ARCHITECTURE.md`
  "exiftool integration" for the batching/PATH-resolution pattern.
- `NativeMetadataReader` (ImageIO-based) is a separate, read-only prototype for EXIF/IPTC/GPS
  metadata and RAW previews without shelling out — see its header doc for the known gap (no
  manufacturer maker-note fields, e.g. Olympus `ArtFilterEffect`). Not yet wired into the app; not a
  replacement for `ExifToolClient`'s write path.
- **GRDB.swift** for local SQLite (the Timeline GPS cache) — chosen over SwiftData because the
  nearest-timestamp/bounded-window/tie-break query doesn't map cleanly onto `#Predicate` macros. See
  `docs/ARCHITECTURE.md` "Local cache (Timeline GPS matching)" for the rationale. Default to GRDB +
  raw SQL for any future local-cache work in this repo rather than reaching for SwiftData.
- Background/I/O work uses Swift structured concurrency (`async`/`await`, actors) — no `QThreadPool`
  equivalent needed; see `docs/ARCHITECTURE.md` "Concurrency rules".

## Architecture

`Views/` (SwiftUI, no logic) → `ViewModels/` (`@MainActor`, holds state, calls services from a
`Task`) → `Services/` (the actual logic, `async`, no UI imports) → `Models/` (plain data types).
Full detail in `docs/ARCHITECTURE.md`.

## Coding Style

- Swift 5.10, type-annotated where inference doesn't already make it obvious.
- Keep functions small and single-purpose. No speculative abstractions, no defensive code for cases
  that can't happen — three similar lines beat a premature helper.
- Doc comments only where the *why* isn't obvious from the signature (e.g. a documented scope gap or
  a non-obvious external-format quirk) — not on every function.
- No emojis, anywhere, ever.
- When debugging, find the root cause before changing code — don't guess-and-check.

## Deliberately deferred scope

- **Metadata write-back via ImageIO** (`NativeMetadataReader` is read-only by design) is explicitly
  deferred — don't start on it without the user asking directly.
- Anything in the Python sibling app's backlog that hasn't shipped there yet shouldn't be assumed as
  a requirement here (see `docs/SPEC.md` "Deliberately out of scope").

## Hardware & model notes

User's dev machine is a Mac Studio **M1 Ultra, 128GB unified memory** — not the latest Apple
Silicon, but memory bandwidth (819 GB/s) still beats the M5 generation (base M5: 154 GB/s; M5 Max
best config: up to 614 GB/s) for sustained local-LLM token generation, which is bandwidth-bound
rather than compute-bound. Decision: stay on this hardware rather than upgrading, until Apple ships
something like an "M5 Ultra" with bandwidth clearly ahead of the M1 Ultra.

Two independent local-inference paths exist and both run on this reasoning: **Ollama**
(`OllamaProvider`, added an MLX backend on Apple Silicon as of v0.19, March 2026) and the native
**`mlx:` provider** (`MLXNativeProvider`, built directly on `mlx-swift-lm`, in-process via Metal, no
Ollama daemon involved). The `mlx:` provider was added as an exercise in the native MLX stack, not
because Ollama's own MLX backend was found lacking — see `docs/MLX_PROVIDER.md` for the decision
record and current model allowlist.

A third, Apple-native path is the **`foundation:` provider** (`FoundationModelsProvider`): on-device
Foundation Models with `@Generable` guided generation, which *guarantees* a typed
`{description, keywords, species}` result rather than the free-form JSON the small local models emit
unreliably. The typed `species` field feeds the eBird `attachScientificNames` binomial lookup
directly on iPad. **Build constraint:** Foundation Models image input needs the macOS 27 / iOS 27
SDK, which currently ships only in **Xcode-beta** — so the whole repo is now built with that
toolchain. Run `swift build`/`swift test` with
`DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`, and `scripts/build-app-bundle.sh`
sets it automatically. The deployment floor is macOS 15 / iOS 27. The Mac floor stays below 27
on purpose: a macOS 26 or 27 floor opts SwiftUI into new window-sizing behaviour that crashes when
the `.inspector` pane is dragged (proven with a bare repro, 2026-09-25; a 15 floor is fine). So
`FoundationModelsProvider` keeps its runtime `#available(macOS 27.0, ...)` gates. The cost is
**no Liquid Glass on Mac**: SwiftPM records the linked SDK as equal to the floor, and AppKit reads
that to pick the design. Forcing SDK 27 with a 15 floor (linker `-platform_version macos 15.0
27.0`) brings glass back, but the full app then crashes the same way — the bug comes with the new
design, not the floor number. Don't retry that until Apple fixes it; retest each macOS 27 update
with the bare repro (a Feedback package was prepared outside the repo). Glass-only APIs like
`ToolbarSpacer` and `sharedBackgroundVisibility` do nothing visible until then.

## File Safety

- Deleting a file goes through `NSWorkspace.shared.recycle(_:completionHandler:)` or
  `FileManager.trashItem`, never `FileManager.removeItem`.
- Verify a copy (size + SHA-256 via `CryptoKit`) before treating a source file as safely handled —
  see `docs/SPEC.md` §5.

## Secrets & Privacy

- `Timeline*.json` and `*.sqlite`/`*.sqlite3` are gitignored — never remove that ignore or commit a
  real Timeline export or the location cache database (see `docs/SPEC.md` §8). Tests that need
  Timeline-shaped JSON use inline literals with fabricated coordinates/timestamps, never real
  exported data — see `TimelineImportParserTests.swift` for the pattern.
- No API keys or secrets committed; read from process environment.
