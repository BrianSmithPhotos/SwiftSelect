import AVFoundation
import AppKit
import SwiftUI
import MacPhotoMasterCore

/// The large preview for a video: the picture, a transport, and a strip of stills from across the
/// clip. Deciding whether a clip is worth keeping means seeing it, which is the whole reason videos
/// show up in the browser at all (docs/SPEC.md §9) — and most of that decision is "is any of this
/// usable", which the strip answers without playing anything.
///
/// The controls are the app's own rather than AVKit's. `VideoPlayer` brings a floating control bar
/// that draws over the picture, and clicking its play button did nothing in the running app while
/// the same player played on command — see docs/ARCHITECTURE.md "Videos". Owning the transport
/// removes that layer: the button here calls `play()` directly.
///
/// Nothing autoplays. Stepping through a card with the arrow keys would otherwise start audio on
/// every clip it passed over.
struct VideoPreviewView: View {
    let url: URL

    @StateObject private var controller = VideoPlaybackController()
    @State private var skimFrames: [VideoSkimStrip.Frame] = []

    /// Ten across the clip: enough to see what happens in it, few enough to sit in one row beside
    /// the picture without scrolling on a normal window.
    private static let skimFrameCount: Int = 10

    var body: some View {
        VStack(spacing: 8) {
            PlayerLayerView(player: controller.player)
            transport
            skimStrip
        }
        // Keyed on the URL so moving to another clip loads it into the same player rather than
        // leaving the old one playing under the new one.
        .task(id: url) {
            skimFrames = []
            await controller.load(url)
            skimFrames = await VideoSkimStrip().frames(
                at: url, duration: controller.duration, count: Self.skimFrameCount,
                maxPixelSize: 160)
        }
        .onDisappear { controller.teardown() }
    }

    private var transport: some View {
        HStack(spacing: 10) {
            Button(action: controller.togglePlayPause) {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 16)
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("videoPlayPause")
            .accessibilityLabel(controller.isPlaying ? "Pause" : "Play")

            Text(VideoAssetReader.durationText(controller.currentTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Slider(value: scrubPosition, in: 0...max(controller.duration, 0.01))
                .accessibilityIdentifier("videoScrubber")
                .accessibilityLabel("Scrub through the clip")

            Text(VideoAssetReader.durationText(controller.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        // Nothing to drive until the clip's length is known — a slider over a 0...0.01 range would
        // jump to the end on the first pixel of a drag.
        .disabled(controller.duration <= 0)
    }

    @ViewBuilder private var skimStrip: some View {
        if !skimFrames.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(skimFrames) { frame in
                        Button {
                            controller.seek(to: frame.time)
                        } label: {
                            Image(decorative: frame.image, scale: 1)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 96, height: 54)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                        .help("Jump to \(VideoAssetReader.durationText(frame.time))")
                        .accessibilityLabel(
                            "Jump to \(VideoAssetReader.durationText(frame.time))")
                    }
                }
                .padding(.horizontal, 8)
            }
            .frame(height: 54)
        }
    }

    /// Seeks live as the slider moves rather than on release: finding the usable part of a clip
    /// means watching the picture follow the thumb. Seeks are keyframe-tolerant
    /// (`VideoPlaybackController.seekTolerance`), and AVPlayer drops a pending seek when a new one
    /// arrives, so a fast drag costs one seek rather than a queue of them.
    private var scrubPosition: Binding<Double> {
        Binding(get: { controller.currentTime }, set: { controller.seek(to: $0) })
    }
}

/// The video surface. An `AVPlayerLayer` directly, rather than AVKit's `VideoPlayer`, so the pane
/// carries exactly one set of controls — the app's own, above.
private struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerBackedView {
        PlayerBackedView(player: player)
    }

    func updateNSView(_ nsView: PlayerBackedView, context: Context) {
        nsView.playerLayer.player = player
    }
}

/// A view whose backing layer *is* the player layer, so the picture resizes with the pane without
/// any frame bookkeeping.
final class PlayerBackedView: NSView {
    /// Safe to force: `makeBackingLayer` below is the only thing that ever creates this view's layer.
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    init(player: AVPlayer) {
        super.init(frame: .zero)
        // Order matters: `wantsLayer` is what calls `makeBackingLayer`, so there is no layer to
        // reach for until after it is set.
        wantsLayer = true
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not loaded from a nib") }

    override func makeBackingLayer() -> CALayer { AVPlayerLayer() }
}
