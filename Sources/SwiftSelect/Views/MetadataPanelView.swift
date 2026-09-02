import SwiftUI
import UniformTypeIdentifiers
import SwiftSelectCore

/// Editable metadata fields + AI/GPS/save/process actions. See docs/SPEC.md §2-7.
///
/// Description/keywords/GPS are editable and wired to `SourceBrowserViewModel.saveMetadata` (spec
/// §3); Title is a read-only live preview of the eventual rename (see `titlePreview`), never
/// independently typed — it only becomes real metadata at Process & Move time. The remaining fields
/// (camera/lens/exposure/capture time) stay read-only display too — they come from the file itself,
/// not something a user retypes. Process/move (spec §5) is wired below the fields, mirroring the
/// Python reference app's `metadata_panel` button row rather than a source-panel button or
/// right-click menu — it's the last action taken once editing an SD card's images is done, so it
/// belongs at the foot of this pane.
struct MetadataPanelView: View {
    @ObservedObject var viewModel: SourceBrowserViewModel
    @State private var isChoosingLibraryFolder = false
    /// Set right before showing the library-folder picker for a process action that ran with no
    /// library root configured yet, so the picker's completion handler knows to run that action
    /// once the pick resolves. Normal path is Settings (Cmd+,); this is just a fallback so a first
    /// run isn't a dead end.
    @State private var pendingProcessScope: ProcessMoveScope?

    private var asset: PhotoAsset? { viewModel.selectedAsset }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Metadata")
                .font(.headline)
                .padding([.top, .horizontal])

            if let asset, asset.isVideo {
                // A clip has no fields of its own to edit, but a batch run is scoped to the grid's
                // selection, not to whatever the panel happens to be previewing. Leaving it out
                // meant one clip sorting first in a selection took the whole AI section away.
                Form {
                    videoFields(asset)
                    Section { batchSuggestionControls }
                }
                .formStyle(.grouped)
            } else if let asset {
                Form {
                    LabeledContent("Title", value: viewModel.titlePreview)
                    TextField("Description", text: $viewModel.editableDescription, axis: .vertical)
                        .lineLimit(3...6)
                    TextField("Keywords", text: $viewModel.editableKeywords, axis: .vertical)
                        .lineLimit(3...8)
                    HStack {
                        TextField("AI Model", text: $viewModel.aiModelText)
                        Menu {
                            ForEach(AIModelSelection.presets, id: \.self) { preset in
                                Button(preset) { viewModel.aiModelText = preset }
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                    Toggle(
                        "Crop to Subject",
                        isOn: Binding(
                            get: { viewModel.subjectIsolationEnabled },
                            set: { viewModel.setSubjectIsolationEnabled($0) }
                        ))
                    if viewModel.manualSubjectCropRect != nil {
                        Button("Reset to AI Crop") {
                            viewModel.setManualCropRect(nil)
                        }
                        .font(.caption)
                    }
                    HStack {
                        Button {
                            viewModel.startAISuggestion()
                        } label: {
                            if viewModel.isSuggestingAI {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Suggest Description + Keywords")
                            }
                        }
                        .disabled(viewModel.selectedAsset == nil || viewModel.isSuggestingAI)
                        if viewModel.isSuggestingAI {
                            Button("Stop") {
                                viewModel.cancelAISuggestion()
                            }
                        }
                    }
                    batchSuggestionControls
                    if let aiStatusMessage = viewModel.aiStatusMessage {
                        Text(aiStatusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let aiEvaluatedImage = viewModel.aiEvaluatedImage {
                        LabeledContent("Evaluated") {
                            VStack(alignment: .leading, spacing: 4) {
                                Image(decorative: aiEvaluatedImage, scale: 1, orientation: .up)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(maxHeight: 160)
                                // Filename and pixel dimensions of what the model actually received
                                // — the cross-reference for the "Scene triage on WxH image" log line
                                // when a description mentions something absent from the big preview.
                                Text(
                                    "\(viewModel.aiEvaluatedImageSourceName ?? "—") · \(aiEvaluatedImage.width)x\(aiEvaluatedImage.height)"
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                    LabeledContent("Camera", value: asset.cameraModel)
                    LabeledContent("Lens", value: asset.lensModel)
                    LabeledContent("Aperture", value: asset.aperture)
                    LabeledContent("Shutter", value: asset.shutterSpeed)
                    LabeledContent("Focal length", value: asset.focalLength)
                    LabeledContent("ISO", value: asset.iso)
                    LabeledContent("Focus distance", value: asset.focusDistance)
                    if let capturedAt = asset.capturedAt {
                        LabeledContent("Captured", value: capturedAt.formatted())
                    }
                    HStack {
                        TextField("Latitude", text: $viewModel.editableLatitudeText)
                        TextField("Longitude", text: $viewModel.editableLongitudeText)
                    }
                    LabeledContent("Altitude") {
                        HStack {
                            Text(asset.gpsAltitude.map { String(format: "%.0f m", $0) } ?? "—")
                            Spacer()
                            Button {
                                Task { await viewModel.refreshAltitude() }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(.borderless)
                            .disabled(
                                viewModel.editableLatitudeText.trimmingCharacters(in: .whitespacesAndNewlines)
                                    .isEmpty
                                    || viewModel.editableLongitudeText.trimmingCharacters(
                                        in: .whitespacesAndNewlines
                                    ).isEmpty
                                    || viewModel.isLookingUpAltitude)
                        }
                    }
                    if let gpsSuggestionStatusMessage = viewModel.gpsSuggestionStatusMessage {
                        Text(gpsSuggestionStatusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)

                saveSection
            } else {
                Spacer()
                Text("Select a photo to see its metadata.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            }

            processMoveSection
        }
        .task(id: viewModel.selectedAssetID) {
            await viewModel.loadArtFilterTokenIfNeeded()
            await viewModel.suggestGPSIfNeeded()
            await viewModel.lookupLocationKeywordsIfNeeded()
        }
        .fileImporter(isPresented: $isChoosingLibraryFolder, allowedContentTypes: [.folder]) { result in
            guard case let .success(url) = result else { return }
            viewModel.setLibraryRoot(url)
            if let pendingProcessScope {
                viewModel.process(scope: pendingProcessScope, libraryRoot: url)
                self.pendingProcessScope = nil
            }
        }
    }

    /// What a clip gets instead of the metadata form. Everything the form offers — description,
    /// keywords, AI suggestions, GPS, save — writes EXIF/IPTC this app does not put into video, so
    /// showing those controls greyed out would only invite the question of how to enable them.
    /// What is left is the little a clip does carry, plus a plain statement of where Process & Move
    /// will put it, since that destination is not the library folder the buttons below imply.
    @ViewBuilder private func videoFields(_ asset: PhotoAsset) -> some View {
        Group {
            LabeledContent("File", value: asset.url.lastPathComponent)
            LabeledContent("Duration", value: VideoAssetReader.durationText(asset.videoDuration))
            if let capturedAt = asset.capturedAt {
                LabeledContent("Recorded", value: capturedAt.formatted())
            }
            Text(
                "Videos carry no editable metadata. Process & Move copies this clip to "
                    + VideoMoveService.destinationDirectory(
                        batch: viewModel.sessionBatch,
                        root: VideoMoveService.defaultDestinationRoot
                    ).path + "."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// The batch row, shared by the still and clip branches of `body`. Its scope is the grid's
    /// selection (or the whole folder), so it belongs to the panel rather than to the previewed
    /// asset - `BatchAISuggestionTargets` drops video-only sets from the count either way.
    @ViewBuilder private var batchSuggestionControls: some View {
        HStack {
            Button {
                viewModel.startBatchAISuggestion()
            } label: {
                // Says both halves of what will happen: how many sets, and whether the
                // run is scoped to the grid selection or to the whole folder.
                Text(
                    (viewModel.hasMultiSelection ? "Suggest Selected Sets" : "Suggest All Sets")
                        + " (\(viewModel.batchAITargetCount))")
            }
            .disabled(
                viewModel.batchAITargetCount == 0 || viewModel.isSuggestingAI
                    || viewModel.isBatchSuggestingAI)
            if viewModel.isBatchSuggestingAI {
                Button("Stop") {
                    viewModel.cancelBatchAISuggestion()
                }
            }
        }
        Toggle(
            "Re-describe sets that already have a description",
            isOn: $viewModel.batchAIRedescribesDescribedSets)
        if viewModel.isBatchSuggestingAI {
            ProgressView(
                value: Double(viewModel.batchAICompletedCount),
                total: Double(max(viewModel.batchAITotalCount, 1)))
        }
    }

    private var saveSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button("Save (This File)") {
                    guard let asset = viewModel.selectedAsset else { return }
                    viewModel.saveMetadata(scope: .singleAsset(asset))
                }
                .disabled(viewModel.selectedAsset == nil || viewModel.isSavingMetadata)

                Button("Save (Capture Set)") {
                    guard let captureSet = viewModel.selectedCaptureSet else { return }
                    viewModel.saveMetadata(scope: .captureSet(captureSet))
                }
                .disabled(viewModel.selectedCaptureSet == nil || viewModel.isSavingMetadata)

                Button("Save (Current Selection)") {
                    let assets = viewModel.manualSelectionAssets
                    guard !assets.isEmpty else { return }
                    viewModel.saveMetadata(scope: .manualSelection(assets))
                }
                .disabled(!viewModel.hasCurrentSelection || viewModel.isSavingMetadata)
            }

            if let saveStatusMessage = viewModel.saveStatusMessage {
                Text(saveStatusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
    }

    private var processMoveSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Process & Move")
                .font(.subheadline.bold())

            TextField("Batch", text: $viewModel.sessionBatch)

            HStack(spacing: 6) {
                Button("Single Image") {
                    guard let asset = viewModel.selectedAsset else { return }
                    requestProcess(.singleAsset(asset))
                }
                .disabled(viewModel.selectedAsset == nil || viewModel.isProcessing)

                Button("Capture Set") {
                    guard let captureSet = viewModel.selectedCaptureSet else { return }
                    requestProcess(.captureSet(captureSet))
                }
                .disabled(viewModel.selectedCaptureSet == nil || viewModel.isProcessing)

                Button("Current Selection") {
                    let assets = viewModel.manualSelectionAssets
                    guard !assets.isEmpty else { return }
                    requestProcess(.manualSelection(assets))
                }
                .disabled(!viewModel.hasCurrentSelection || viewModel.isProcessing)

                Button("Session") { requestProcess(.session(viewModel.captureSets)) }
                    .disabled(viewModel.captureSets.isEmpty || viewModel.isProcessing)
            }

            if viewModel.isProcessing {
                ProgressView(
                    value: Double(viewModel.processedFileCount),
                    total: Double(max(viewModel.processTotalCount, 1)))
            }

            if let processStatusMessage = viewModel.processStatusMessage {
                Text(processStatusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Develop RAW is reached from a context menu rather than a button here, but its
            // progress belongs in the same place as the other long-running action's.
            if let developStatusMessage = viewModel.developStatusMessage {
                Text(developStatusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding([.horizontal, .bottom])
    }

    /// Runs `scope` against the persisted library root, prompting for one first (via the
    /// library-folder `.fileImporter` above) if none has been set in Settings yet.
    private func requestProcess(_ scope: ProcessMoveScope) {
        guard let libraryRootURL = viewModel.libraryRootURL else {
            pendingProcessScope = scope
            isChoosingLibraryFolder = true
            return
        }
        viewModel.process(scope: scope, libraryRoot: libraryRootURL)
    }
}

#Preview {
    MetadataPanelView(viewModel: SourceBrowserViewModel())
}
