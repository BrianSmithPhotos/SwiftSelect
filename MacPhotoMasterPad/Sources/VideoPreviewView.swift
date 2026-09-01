import AVKit
import SwiftUI

/// iPad counterpart to the Mac app's `VideoPreviewView` — a real player with transport controls in
/// place of the zoomable still, because deciding whether a clip is worth keeping means watching it
/// (docs/SPEC.md §9). Duplicated rather than shared for the same reason the rest of the iPad UI is:
/// `MacPhotoMasterCore` holds no view code.
///
/// Nothing autoplays, and the player is torn down explicitly when the selection moves on — dropping
/// the reference alone would leave the item's open file descriptor until the last retain unwound,
/// and this app is deliberately left running for days at a time.
struct VideoPreviewView: View {
    let url: URL

    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
            } else {
                Color.clear
            }
        }
        .task(id: url) {
            teardown()
            player = AVPlayer(url: url)
        }
        .onDisappear(perform: teardown)
    }

    private func teardown() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }
}
