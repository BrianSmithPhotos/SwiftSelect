import SwiftUI
import MacPhotoMasterCore

/// Three-panel shell: source browser | preview | metadata. See docs/SPEC.md §1-3.
///
/// `@ObservedObject` here (not `@StateObject`) because `MacPhotoMasterApp` now owns the one
/// instance for the app's lifetime — it's shared with the Settings scene, which also reads/writes
/// `libraryRootURL`. See `MacPhotoMasterApp`'s doc comment for why.
struct ContentView: View {
    @ObservedObject var browser: SourceBrowserViewModel
    @State private var isMetadataPanelPresented = true
    @State private var isIPadImportPresented = false

    var body: some View {
        NavigationSplitView {
            SourcePanelView(viewModel: browser)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            PreviewPanelView(viewModel: browser)
                .navigationSplitViewColumnWidth(min: 400, ideal: 600)
        }
        .navigationSplitViewStyle(.balanced)
        .inspector(isPresented: $isMetadataPanelPresented) {
            MetadataPanelView(viewModel: browser)
                .inspectorColumnWidth(min: 280, ideal: 320)
        }
        .toolbar {
            // The launch import runs before the first folder has finished loading and takes
            // seconds on a large export, with nothing else on screen to explain the wait — and GPS
            // suggestions are simply absent until it finishes, so silence here reads as a broken
            // feature rather than a busy one.
            ToolbarItem {
                if browser.isSyncingTimeline {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Timeline…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .help("Importing a new Timeline export - GPS suggestions arrive when it finishes")
                }
            }
            ToolbarItem {
                Button {
                    isIPadImportPresented = true
                } label: {
                    Label("Import from iPad", systemImage: "square.and.arrow.down.on.square")
                }
            }
            ToolbarItem {
                Button {
                    browser.setLookVisualiserEnabled(!browser.lookVisualiserEnabled)
                } label: {
                    Label(
                        "Show Camera Look", systemImage: "camera.filters")
                }
                .keyboardShortcut("l", modifiers: .command)
                .help("Show the in-camera look over the preview (Cmd-L)")
                .accessibilityIdentifier("cameraLookToggle")
            }
            ToolbarItem {
                Button {
                    isMetadataPanelPresented.toggle()
                } label: {
                    Label("Toggle Metadata Panel", systemImage: "sidebar.trailing")
                }
            }
        }
        .sheet(isPresented: $isIPadImportPresented) {
            IPadImportView(viewModel: browser)
        }
    }
}

#Preview {
    ContentView(browser: SourceBrowserViewModel())
}
