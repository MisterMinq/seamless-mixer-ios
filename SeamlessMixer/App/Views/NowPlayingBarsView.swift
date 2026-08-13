import SwiftUI

/// A small animated "now playing" indicator — three vertical bars whose
/// heights loop up and down, the familiar Apple Music/Spotify pattern for
/// marking which row/button represents something actually playing right
/// now. Added 2026-08-14, replacing the static `"waveform"`/`"speaker.wave.2.fill"`
/// SF Symbols `PlaylistDetailView` used for this same purpose — real-device
/// feedback specifically noted those read as flat/static, "no flair," since
/// an SF Symbol glyph doesn't actually move.
///
/// Self-contained and stateless from the caller's side — just drop it in
/// wherever a "this is playing" indicator is needed. Unverified against a
/// real device/simulator, same standing caveat as every other UI slice in
/// this app — the animation timing/feel is a judgment call, easy to retune
/// once Andy's actually seen it.
struct NowPlayingBarsView: View {
    var color: Color = DesignTokens.Color.primaryText
    var barWidth: CGFloat = 3
    var maxHeight: CGFloat = 14

    @State private var animating = false

    // Each bar's resting (non-animating) vs. peak (animating) height
    // fraction, staggered so the three don't move in lockstep — a flat,
    // synchronized bounce reads as less "alive" than a staggered one.
    private let restFractions: [CGFloat] = [0.35, 0.85, 0.5]
    private let peakFractions: [CGFloat] = [0.9, 0.4, 1.0]
    private let delays: [Double] = [0, 0.12, 0.24]

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<3, id: \.self) { i in
                RoundedRectangle(cornerRadius: barWidth / 2)
                    .fill(color)
                    .frame(width: barWidth, height: maxHeight * (animating ? peakFractions[i] : restFractions[i]))
            }
        }
        .frame(width: barWidth * 3 + 4, height: maxHeight, alignment: .bottom)
        .onAppear {
            for i in 0..<3 {
                withAnimation(
                    .easeInOut(duration: 0.45)
                        .repeatForever(autoreverses: true)
                        .delay(delays[i])
                ) {
                    // All three bars share one `animating` flag -- the
                    // per-bar stagger comes from `delays` above, not from
                    // separate state, since SwiftUI applies a delayed
                    // `withAnimation` independently per call even against
                    // the same state change.
                    animating = true
                }
            }
        }
    }
}

#Preview {
    NowPlayingBarsView()
        .padding()
        .background(DesignTokens.Color.background)
}
