import AVKit
import SwiftUI

/// The large preview for a video: a real player with transport controls, not a poster frame.
/// Deciding whether a clip is worth keeping means watching it, which is the whole reason videos
/// show up in the browser at all (docs/SPEC.md §9).
///
/// Nothing here autoplays. Stepping through a card with the arrow keys would otherwise start
/// audio on every clip it passed over.
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
        // Keyed on the URL so moving to another clip tears the old player down rather than leaving
        // it playing under the new one. The teardown is explicit — releasing the reference alone
        // leaves the item's open file descriptor to whenever the last frame's retain cycle unwinds,
        // and this app is deliberately left running for days at a time.
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
