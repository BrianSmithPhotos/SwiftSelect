import AppKit
import SwiftUI
import UniformTypeIdentifiers
import SwiftSelectCore

/// Folder navigator + thumbnail grid for the active source directory. See docs/SPEC.md §1.
///
/// Navigation is breadcrumb-style (one level open at a time) rather than a recursive expandable
/// tree — see `FolderBrowser`'s doc comment for why.
struct SourcePanelView: View {
    @Bindable var viewModel: SourceBrowserViewModel
    @State private var isChoosingFolder = false
    /// The grid's scroll view width, measured from outside it. See `columnCount(forWidth:)`.
    @State private var gridWidth: CGFloat = 0
    /// Set by a tile click, so the arrow keys step the grid only after it was last clicked, and a
    /// text field elsewhere keeps its own arrow keys.
    @FocusState private var isGridFocused: Bool
    /// Keeps the selected tile in view as the arrow keys move it. Keyed by capture set, as the
    /// grid's `ForEach` is.
    @State private var gridScrollPosition = ScrollPosition(idType: CaptureSet.ID.self)

    private static let tileMinimumWidth: CGFloat = 96
    private static let tileSpacing: CGFloat = 8
    /// Always set aside, whatever the scroll bar style, so an always-shown scroll bar appearing or
    /// going never changes the tiles' width. Costs a few points of tile size with overlay scroll bars.
    private static let scrollerAllowance: CGFloat = NSScroller.scrollerWidth(
        for: .regular, scrollerStyle: .legacy)

    private var columns: [GridItem] {
        let usable = gridWidth - Self.scrollerAllowance
        let count = Self.columnCount(forWidth: usable)
        let side = Self.tileSide(forWidth: usable, columns: count)
        return Array(repeating: GridItem(.fixed(side), spacing: Self.tileSpacing), count: count)
    }

    /// The same arithmetic as `GridItem(.adaptive(minimum: 96))`, but fed the scroll view's outer
    /// width rather than its content width. With "Show scroll bars: Always" an adaptive grid right
    /// at the one-screenful boundary loops: the scroll bar appears, narrows the content, a column
    /// drops, the content shortens, the scroll bar goes, the column returns. Built with a macOS 27
    /// floor, AppKit lets that run until it throws "more Update Constraints in Window passes than
    /// there are views in the window"; lower floors tolerate the loop, but it still runs. The
    /// outer width does not change when the scroll bar comes and goes, so neither the column count
    /// nor the (square) tile size here can oscillate.
    static func columnCount(forWidth width: CGFloat) -> Int {
        max(1, Int((width + tileSpacing) / (tileMinimumWidth + tileSpacing)))
    }

    /// Fills the usable width exactly, as the adaptive grid did, but as a fixed size.
    static func tileSide(forWidth width: CGFloat, columns: Int) -> CGFloat {
        max(tileMinimumWidth, (width - CGFloat(columns - 1) * tileSpacing) / CGFloat(columns))
    }

    /// Left/right move one tile, up/down one row.
    private func gridStep(for key: KeyEquivalent) -> Int {
        switch key {
        case .leftArrow: -1
        case .rightArrow: 1
        case .upArrow: -columns.count
        default: columns.count
        }
    }

    private var displayedCaptureSets: [CaptureSet] {
        switch viewModel.sourceViewFilter {
        case .active: viewModel.captureSets
        case .skipped: viewModel.skippedCaptureSets
        }
    }

    private var emptyStateMessage: String {
        guard !viewModel.breadcrumb.isEmpty else { return "Open a folder to browse photos." }
        switch viewModel.sourceViewFilter {
        case .active: return "No supported photos in this folder."
        case .skipped: return "No skipped items in this folder."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Source")
                    .font(.headline)
                Spacer()
                Button("Open Folder…") { isChoosingFolder = true }
            }

            if !viewModel.breadcrumb.isEmpty {
                BreadcrumbBar(segments: viewModel.breadcrumb) { viewModel.navigate(to: $0) }
            }

            if !viewModel.subfolders.isEmpty {
                SubfolderStrip(folders: viewModel.subfolders) { viewModel.navigate(to: $0) }
            }

            // Segmented rather than a toggle button so "Active" and "Skipped" read as two distinct
            // views of the same folder, not a hide/show flag layered on top of one grid.
            Picker("View", selection: $viewModel.sourceViewFilter) {
                Text("Active").tag(SourceViewFilter.active)
                Text("Skipped (\(viewModel.skippedCaptureSets.count))").tag(SourceViewFilter.skipped)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 240)

            if viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else if let message = viewModel.loadErrorMessage {
                Text(message)
                    .foregroundStyle(.red)
            } else if displayedCaptureSets.isEmpty {
                Text(emptyStateMessage)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: Self.tileSpacing) {
                        ForEach(displayedCaptureSets) { captureSet in
                            if let representative = captureSet.representative {
                                CaptureTileView(
                                    asset: representative,
                                    memberCount: captureSet.members.count,
                                    isSelected: viewModel.multiSelectedIDs.contains(representative.id),
                                    isProcessed: viewModel.isProcessed(captureSet),
                                    onSelect: { modifiers in
                                        isGridFocused = true
                                        viewModel.selectTile(representative.id, modifiers: modifiers)
                                    }
                                )
                                .contextMenu {
                                    switch viewModel.sourceViewFilter {
                                    case .active:
                                        Button("Skip") { viewModel.skip(captureSet) }
                                        Button("Develop RAW") {
                                            viewModel.developRAW(scope: .captureSet(captureSet))
                                        }
                                        .disabled(
                                            viewModel.isDevelopingRAW
                                                || !viewModel.canDevelopRAW(scope: .captureSet(captureSet)))
                                        Divider()
                                        Button("Merge into One Capture Set") {
                                            viewModel.mergeSelectedCaptureSets()
                                        }
                                        .disabled(!viewModel.canMergeSelection)
                                        if viewModel.isMerged(captureSet) {
                                            Button("Split Apart") { viewModel.splitApart(captureSet) }
                                        }
                                    case .skipped:
                                        Button("Un-skip") { viewModel.unskip(captureSet) }
                                    }
                                }
                            }
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.vertical, 4)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
                .scrollPosition($gridScrollPosition)
                .onChange(of: viewModel.selectedCaptureSet?.id) { _, id in
                    guard let id else { return }
                    withAnimation { gridScrollPosition.scrollTo(id: id) }
                }
                .focusable()
                .focused($isGridFocused)
                // The selected tile already shows where you are; a ring round the grid adds nothing.
                .focusEffectDisabled()
                .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                    // AppKit flags arrow keys as numeric-pad keys, so test only the modifiers a person
                    // holds. Shift/cmd-arrow are left alone rather than half-handled.
                    guard press.modifiers.isDisjoint(with: [.shift, .command, .option, .control])
                    else { return .ignored }
                    viewModel.stepGridSelection(by: gridStep(for: press.key))
                    return .handled
                }
            }
        }
        .padding()
        // Without this the VStack sizes to its content and the pane centres it, so the header sits
        // mid-pane while a folder is loading and jumps to the top once the grid arrives. Claiming
        // the full height keeps the header where it lands.
        .frame(maxHeight: .infinity, alignment: .top)
        // .fileImporter is the SwiftUI-native folder/file picker — it wraps the same NSOpenPanel
        // you'd otherwise drive by hand from AppKit, but as a modifier tied to `isPresented`
        // rather than something you present imperatively.
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            if case let .success(url) = result {
                viewModel.openFolder(at: url)
            }
        }
        // A visually hidden button is the standard SwiftUI way to attach a keyboard shortcut that
        // isn't tied to an on-screen control — `.hidden()` only affects rendering, so the shortcut
        // still registers with the window's responder chain. Mirrors the context-menu "Skip" action
        // so the same set-level skip is reachable either by right-click or the Delete key. Disabled
        // outside the Active filter — the Skipped filter's selection now previews a capture set the
        // same way Active does (see `SourceBrowserViewModel.selectTile`), so without this the Delete
        // key would re-skip an already-skipped set and duplicate it into `skippedCaptureSets`.
        .background {
            Button("Skip Selected", action: viewModel.skipSelected)
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(viewModel.sourceViewFilter != .active || viewModel.selectedCaptureSet == nil)
                .hidden()
        }
    }
}

/// Finder-path-bar-style row of the folders between the opened root and the current folder.
/// Clicking a segment jumps straight there (via `SourceBrowserViewModel.navigate(to:)`, which
/// truncates the breadcrumb back to that point).
private struct BreadcrumbBar: View {
    let segments: [URL]
    let onSelect: (URL) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(segments.enumerated()), id: \.element) { index, url in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Button(url.lastPathComponent) { onSelect(url) }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .fontWeight(index == segments.count - 1 ? .semibold : .regular)
                }
            }
        }
    }
}

/// Chip row of the current folder's immediate subfolders. Tapping one descends into it.
private struct SubfolderStrip: View {
    let folders: [URL]
    let onSelect: (URL) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(folders, id: \.self) { folder in
                    Button {
                        onSelect(folder)
                    } label: {
                        Label(folder.lastPathComponent, systemImage: "folder")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

/// One capture-set tile: the representative's thumbnail, plus a badge when the set has more than
/// one member (e.g. a RAW+JPEG pair from the same shutter press).
private struct CaptureTileView: View {
    let asset: PhotoAsset
    let memberCount: Int
    let isSelected: Bool
    /// Non-blocking hint that this set has already been through Process & Move at least once — see
    /// `ProcessedStateStore`'s doc comment. Never disables re-selecting or reprocessing the tile.
    let isProcessed: Bool
    /// Cmd-click toggles this tile in/out of the grid's multi-selection, shift-click ranges from
    /// the last clicked tile, a plain click resets to just this one — see
    /// `SourceBrowserViewModel.selectTile`. `NSEvent.modifierFlags` reads the real modifier-key
    /// state at the moment of a genuine user click; this is unrelated to (and unaffected by) the
    /// AppleScript/System Events automation quirks documented for this app elsewhere.
    let onSelect: (NSEvent.ModifierFlags) -> Void

    @State private var thumbnail: CGImage?

    var body: some View {
        // A real Button (rather than a plain view with `.onTapGesture`) so the tap action and the
        // accessibility frame/press-action live on the same node — otherwise VoiceOver and
        // AXPress-based UI automation see a properly framed element with no action wired to it.
        Button(action: { onSelect(NSEvent.modifierFlags) }) {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let thumbnail {
                        Image(decorative: thumbnail, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 3)
                }
                .overlay(alignment: .topLeading) {
                    // Top-left, clear of the member-count and processed badges along the bottom.
                    // A poster frame is a still like any other, so without this a clip is
                    // indistinguishable from a photo until it is selected.
                    //
                    // A camcorder rather than a play triangle: nothing in the grid plays, so a
                    // triangle here offers a control that isn't there. The badge says what the file
                    // is; the transport that actually plays it lives under the preview.
                    if asset.isVideo {
                        Label(
                            VideoAssetReader.durationText(asset.videoDuration),
                            systemImage: "video.fill"
                        )
                        .font(.system(size: 8, weight: .bold))
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(4)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if memberCount > 1 {
                        Text("\(memberCount)")
                            .font(.caption2.bold())
                            .padding(4)
                            .background(.black.opacity(0.6), in: Circle())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 3)
                            .padding(.bottom, 0)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    // Both badges are overlays on the same base shape (rather than ZStack siblings)
                    // so `.bottomTrailing`/`.bottomLeading` resolve against identical bounds — a
                    // separate positioning mechanism per badge drifted out of vertical alignment.
                    // The checkmark glyph runs smaller than the count digit's font size because an
                    // SF Symbol at a given point size renders visually heavier/larger than text.
                    if isProcessed {
                        Image(systemName: "checkmark")
                            .font(.system(size: 6, weight: .bold))
                            .padding(3)
                            .background(.green.opacity(0.85), in: Circle())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 3)
                            .padding(.bottom, 4)
                    }
                }
                .clipped()
        }
        .buttonStyle(.plain)
        // `.task(id:)` re-runs whenever `asset.id` changes (SwiftUI diffs the id, not just
        // presence) and auto-cancels the previous run — important here because ForEach reuses
        // this view's identity across scroll/relayout, and without the id keying, a fast scroll
        // could leave a stale thumbnail decode from a previous asset finishing after this tile
        // was reassigned to a new one.
        .task(id: asset.id) {
            thumbnail = await MediaPreviewLoader.thumbnail(at: asset.url, maxPixelSize: 256)
        }
        // Without this, VoiceOver (and UI-automation hit-testing) only see the badge Text as a
        // leaf element with a bogus position inside the LazyVGrid's virtualized content — not the
        // tile itself. Combining into one element gives it the button's real on-screen frame.
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("captureTile.\(asset.id.lastPathComponent)")
        .accessibilityLabel(
            memberCount > 1 ? "\(asset.url.lastPathComponent), \(memberCount) items" : asset.url.lastPathComponent)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#Preview {
    SourcePanelView(viewModel: SourceBrowserViewModel())
}
