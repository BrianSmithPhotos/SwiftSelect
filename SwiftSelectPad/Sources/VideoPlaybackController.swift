import AVFoundation
import Foundation
import Observation

/// Owns the player behind the video preview, and the three values its transport draws from.
///
/// The app draws its own play button and scrub slider rather than using AVKit's floating controls
/// (docs/ARCHITECTURE.md "Videos"), so the transport talks to this and nothing else. Everything
/// here is `@MainActor`: the periodic observer publishes on the main queue and the slider writes
/// back from a gesture, so there is no other thread in the picture.
///
/// `@Observable` rather than `ObservableObject`: a view redraws only for the properties it reads,
/// so the ten-a-second `currentTime` tick no longer invalidates views that only read `isPlaying`.
@MainActor
@Observable
final class VideoPlaybackController {
    /// One player for the life of the pane, reused across clips by replacing its item. A new player
    /// per clip would mean a new `AVPlayerLayer` binding on every selection change.
    let player = AVPlayer()

    private(set) var currentTime: TimeInterval = 0
    /// Zero until the clip's length is known, and for a clip whose length AVFoundation can't report
    /// — which the view reads as "no transport to draw yet".
    private(set) var duration: TimeInterval = 0
    private(set) var isPlaying: Bool = false

    /// Bookkeeping only; no view reads it, so it is kept out of observation tracking.
    @ObservationIgnored private var timeObserver: Any?

    /// How far a seek may land from where the slider was let go. Zero tolerance forces a decode from
    /// the previous keyframe, which on a 4K clip read off the card it was shot on takes long enough
    /// to make a drag feel stuck; a quarter-second lands on a keyframe and returns at once.
    private static let seekTolerance = CMTime(seconds: 0.25, preferredTimescale: 600)

    func load(_ url: URL) async {
        teardown()
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)

        // Ten updates a second: enough for the slider to track playback smoothly, few enough that
        // it is not republishing the view on every frame of a 4K clip.
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = time.seconds
                // Read back from the player rather than tracked at the button: playback reaching
                // the end of a clip stops it without anyone pressing anything.
                self.isPlaying = self.player.rate != 0
            }
        }

        guard let loaded = try? await item.asset.load(.duration), loaded.isNumeric else { return }
        duration = loaded.seconds
    }

    func togglePlayPause() {
        if player.rate == 0 {
            // A clip parked at its end would otherwise sit there doing nothing when played.
            if duration > 0, currentTime >= duration - 0.1 { seek(to: 0) }
            player.play()
        } else {
            player.pause()
        }
        isPlaying = player.rate != 0
    }

    /// Seeks, and moves `currentTime` immediately rather than waiting for the next observer tick —
    /// a slider bound to a value that lags its own drag by up to a tenth of a second fights back.
    func seek(to time: TimeInterval) {
        let clamped = min(max(time, 0), duration)
        currentTime = clamped
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: Self.seekTolerance, toleranceAfter: Self.seekTolerance)
    }

    /// Explicit rather than left to deallocation: a periodic observer keeps the player alive, and
    /// releasing the item's reference alone leaves its open file descriptor to whenever the last
    /// retain unwinds. This app is deliberately left running for days at a time.
    func teardown() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentTime = 0
        duration = 0
        isPlaying = false
    }
}
