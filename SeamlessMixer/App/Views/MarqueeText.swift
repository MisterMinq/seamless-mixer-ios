import SwiftUI

/// A single line of text that continuously scrolls left in a seamless loop,
/// so long content is never cut off — added 2026-08-14 for Now Playing's
/// source-context caption (e.g. "Genre + Genre + Artist · Energy Wave · 36
/// songs · 51 min"), which real-device feedback found got truncated with no
/// way to read the rest without leaving the screen to check Playlist Detail.
///
/// Always scrolling, not just when the text happens to overflow — a
/// continuously "running banner" is what was actually asked for, and it
/// avoids the extra complexity/risk of measuring the container's width at
/// runtime to conditionally decide. Two copies of the text are laid out
/// side by side and shifted left together; once the first copy has scrolled
/// fully past, the second is exactly in its place, so the loop point is
/// invisible.
///
/// Unverified against a real device/simulator, same standing caveat as
/// every other UI slice in this app — text-width measurement via a hidden
/// background copy is a standard SwiftUI technique but worth a real look
/// once Andy's seen it, especially for very short captions where a
/// continuous scroll might feel unnecessary rather than useful.
struct MarqueeText: View {
    let text: String
    var font: Font = .footnote
    var color: Color = DesignTokens.Color.textSecondary
    var pointsPerSecond: Double = 30
    /// Gap between the end of one copy and the start of the next as the
    /// loop repeats — reads as a pause, not a hard cut, between passes.
    var gap: CGFloat = 48

    @State private var textWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    private var loopWidth: CGFloat { textWidth + gap }
    private var duration: Double { loopWidth > 0 ? Double(loopWidth) / pointsPerSecond : 0 }

    var body: some View {
        HStack(spacing: gap) {
            textView
            textView
        }
        .offset(x: offset)
        .frame(height: lineHeight, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .background(
            // Invisible, unwrapped copy purely to measure the text's own
            // natural width — the two visible copies above are `.fixedSize()`
            // too, but this one never gets laid out inside the clipped
            // scrolling frame, so its width reading isn't affected by the
            // container's own bounds.
            textView
                .fixedSize()
                .hidden()
                .background(GeometryReader { geo in
                    Color.clear.onAppear { textWidth = geo.size.width }
                })
        )
        .onAppear { startScrolling() }
        .onChange(of: textWidth) { _, _ in startScrolling() }
    }

    private var textView: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
    }

    private var lineHeight: CGFloat {
        // Rough single-line height for the given font -- generous enough not
        // to clip descenders/ascenders across the footnote/caption range
        // this is actually used at.
        18
    }

    private func startScrolling() {
        guard duration > 0 else { return }
        offset = 0
        withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
            offset = -loopWidth
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 20) {
        MarqueeText(text: "Short caption")
        MarqueeText(text: "Genre + Genre + Artist · Energy Wave · 36 songs · 51 min — a much longer source-context caption that would otherwise get cut off")
    }
    .padding()
    .background(DesignTokens.Color.background)
}
