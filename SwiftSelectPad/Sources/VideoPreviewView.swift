import AVFoundation
import SwiftUI
import UIKit
import SwiftSelectCore

/// iPad counterpart to the Mac's `VideoPreviewView`: the picture, a transport, and a strip of stills
/// from across the clip, tapped to jump there (docs/SPEC.md §9). Most of deciding whether a clip is
/// worth keeping is "is any of this usable", which the strip answers without playing anything.
///
/// The controls are the app's own rather than AVKit's, for the reason the Mac's are — see that file
/// and docs/ARCHITECTURE.md "Videos". Nothing autoplays.
struct VideoPreviewView: View {
    let url: URL

    @StateObject private var controller = VideoPlaybackController()
    @State private var skimFrames: [VideoSkimStrip.Frame] = []

    private static let skimFrameCount: Int = 10

    var body: some View {
        VStack(spacing: 8) {
            PlayerLayerView(player: controller.player)
            transport
            skimStrip
        }
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
        HStack(spacing: 12) {
            Button(action: controller.togglePlayPause) {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                    // A finger-sized target, unlike the Mac's pointer-sized one.
                    .frame(width: 44, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
        .padding(.horizontal, 12)
        .disabled(controller.duration <= 0)
    }

    @ViewBuilder private var skimStrip: some View {
        if !skimFrames.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(skimFrames) { frame in
                        Button {
                            controller.seek(to: frame.time)
                        } label: {
                            Image(decorative: frame.image, scale: 1)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 106, height: 60)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            "Jump to \(VideoAssetReader.durationText(frame.time))")
                    }
                }
                .padding(.horizontal, 12)
            }
            .frame(height: 60)
        }
    }

    /// Seeks live as the thumb moves rather than on release: finding the usable part of a clip means
    /// watching the picture follow your finger. Seeks are keyframe-tolerant
    /// (`VideoPlaybackController.seekTolerance`), so a drag stays live even reading off a card.
    private var scrubPosition: Binding<Double> {
        Binding(get: { controller.currentTime }, set: { controller.seek(to: $0) })
    }
}

/// The video surface. An `AVPlayerLayer` directly, rather than AVKit's `VideoPlayer`, so the pane
/// carries exactly one set of controls — the app's own, above.
private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerBackedView {
        let view = PlayerBackedView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: PlayerBackedView, context: Context) {
        uiView.playerLayer.player = player
    }
}

/// A view whose backing layer *is* the player layer, so the picture resizes with the pane without
/// any frame bookkeeping.
final class PlayerBackedView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    /// Safe to force: `layerClass` above fixes what this view's layer is.
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
