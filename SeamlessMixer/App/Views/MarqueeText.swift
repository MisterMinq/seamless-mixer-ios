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
/// side by side; once the first copy has scrolled fully past, the second is
/// exactly in its place, so the loop point should be invisible.
///
/// **Rewritten 2026-08-14 (same day as the first version)** — real-device
/// testing found the scroll wasn't actually continuous: it visibly "ended
/// and reset" rather than flowing. The original approach drove the offset
/// with `withAnimation(...).repeatForever(autoreverses: false)`, which
/// depends on SwiftUI restarting the 0→`-loopWidth` interpolation from
/// scratch each cycle — in principle invisible here (offset 0 and
/// offset `-loopWidth` show pixel-identical content, since that's exactly
/// where the second copy sits), but evidently not reliably so in practice.
/// Replaced with `TimelineView(.animation)`, which recomputes the offset
/// every frame from elapsed wall-clock time via `.truncatingRemainder`
/// (modulo) — a continuously wrapping value with no discrete "restart"
/// event for SwiftUI to visibly snap through, so there's nothing for a
/// seam to appear at.
///
/// Unverified against a real device/simulator (same standing caveat as
/// every UI slice in this app) — but this technique doesn't depend on
/// `repeatForever`'s restart behavior at all, which is the specific thing
/// that broke last time, so it's a materially different approach, not a
/// tweak of the same one.
///
/// **Hardened 2026-08-14 (same day again)** — this view's two side-by-side
/// `.fixedSize()` text copies are *deliberately* wider than any reasonable
/// container (that's the whole point, they need somewhere to scroll to),
/// but that turned out to let their oversized ideal width leak into
/// whatever laid this view out, forcing the entire screen wider than the
/// device and cutting off unrelated content on both edges — see
/// `NowPlayingView`'s own doc comment for the full incident. Wrapped the
/// scrolling content in its own `GeometryReader` so this view always
/// self-constrains to whatever width its immediate parent actually gives
/// it, rather than trusting every future call site to separately remember
/// to pin a width — `GeometryReader` fills the space it's offered without
/// ever requesting more based on its children, which is exactly the
/// "stop this size from propagating upward" behavior needed here.
struct MarqueeText: View {
    let text: String
    var font: Font = .footnote
    var color: Color = DesignTokens.Color.textSecondary
    var pointsPerSecond: Double = 30
    /// Gap between the end of one copy and the start of the next as the
    /// loop repeats — reads as a pause, not a hard cut, between passes.
    var gap: CGFloat = 48

    @State private var textWidth: CGFloat = 0
    @State private var startDate = Date()

    private var loopWidth: CGFloat { textWidth + gap }

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation) { context in
                let elapsed = context.date.timeIntervalSince(startDate)
                let offset = currentOffset(elapsedSeconds: elapsed)

                HStack(spacing: gap) {
                    textView
                    textView
                }
                .offset(x: offset)
            }
            .frame(width: geo.size.width, height: lineHeight, alignment: .leading)
            .clipped()
        }
        .frame(height: lineHeight)
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
        .onAppear { startDate = Date() }
    }

    /// Computed fresh every frame from elapsed time, not accumulated or
    /// animated toward a target — `.truncatingRemainder` (modulo) against
    /// `loopWidth` means the value wraps continuously with no jump, since
    /// the instant it would reach `-loopWidth` it's already back to
    /// (effectively) `0` by construction, not by a separate reset step.
    private func currentOffset(elapsedSeconds: TimeInterval) -> CGFloat {
        guard loopWidth > 0 else { return 0 }
        let traveled = CGFloat(elapsedSeconds) * pointsPerSecond
        return -traveled.truncatingRemainder(dividingBy: loopWidth)
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
}

#Preview {
    VStack(alignment: .leading, spacing: 20) {
        MarqueeText(text: "Short caption")
        MarqueeText(text: "Genre + Genre + Artist · Energy Wave · 36 songs · 51 min — a much longer source-context caption that would otherwise get cut off")
    }
    .padding()
    .background(DesignTokens.Color.background)
}
