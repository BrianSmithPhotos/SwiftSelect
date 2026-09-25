import SwiftUI
import SwiftSelectCore

/// `swift run` execs the built binary directly with no `.app` bundle around it, so LaunchServices
/// never registers this process as a real foreground app — it can still create/show windows and
/// take mouse clicks (window-level hit testing doesn't care), but it never becomes the system
/// "active application", so menu-bar keyboard shortcuts (Cmd+, for Settings, etc.) keep routing to
/// whatever terminal/IDE actually launched it. Explicitly claiming `.regular` activation policy and
/// activating on launch fixes this without needing to package a bundle.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // No `.app` bundle means no Info.plist `CFBundleIconFile` either, so the Dock/Cmd+Tab icon
        // has to be set programmatically instead. The PNG is used as it comes: `Tools/IconGen`
        // draws it on the same 824/1024 icon grid every other Dock icon sits on, with the
        // continuous-corner squircle and the drop shadow already in the image. Masking it here
        // as well would inset it a second time and cut the squircle's corners off with a plain
        // rounded rect.
        if let iconURL = Bundle.module.url(forResource: "AppIcon", withExtension: "png"),
            let icon = NSImage(contentsOf: iconURL)
        {
            NSApp.applicationIconImage = icon
        }
    }
}

// `@main` lives in `Main.swift`, which chooses between this app and the headless
// write-back run before SwiftUI is touched.
struct SwiftSelectApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Owned here (rather than by `ContentView`) so the Settings scene below can share the same
    /// instance — the library-root setting it edits has to be visible to the main window's process
    /// actions, not a separate copy.
    @State private var browser = SourceBrowserViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(browser: browser)
        }
        Settings {
            SettingsView(viewModel: browser)
        }
    }
}
