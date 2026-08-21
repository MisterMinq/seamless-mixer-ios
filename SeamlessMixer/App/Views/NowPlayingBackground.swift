import SwiftUI

/// Pure blend logic for Now Playing's dynamic background — separated from
/// the `View` below so the same computation can also drive adaptive
/// text/icon color without duplicating the blend math.
///
/// **The idea, confirmed with Andy 2026-08-18 against real Apple Music
/// reference screenshots**: not a busy multi-hue effect — a single
/// dominant, darkened tone per track (see `ArtworkPaletteExtractor`),
/// blended smoothly into the *next* track's tone exactly in step with the
/// real audio crossfade (`PlaybackEngine.crossfadeProgress`), not on an
/// approximate fixed-duration animation triggered after the blend already
/// happened. One end of the gradient is deliberately always anchored to
/// the app's own teal (`DesignTokens.Color.primary`) rather than letting
/// every part of the screen come from the artwork — the explicit
/// differentiator from Apple Music's own version, which becomes a total
/// chameleon with no persistent brand identity while something plays.
/// This screen should always read as *this app*, whatever's on the album
/// cover.
///
/// **Switched from `MeshGradient` to a plain `LinearGradient`, 2026-08-21
/// — Testing (53), Andy's own direct call, honoring the fallback he'd
/// already pre-authorized two rounds earlier ("if the colour change
/// doesn't work like I expect, we'll just let it cover the whole screen
/// as before").** Two separate rounds (0.25.42's added motion, 0.25.44's
/// removal of that motion) both missed the real point: `MeshGradient`'s
/// bicubic interpolation between points produces smooth, organic, curved
/// color blending *by design*, whether or not the points themselves are
/// animated — removing the animation (0.25.44) never removed that
/// underlying curvature, which is very likely what kept reading as
/// "wavy" even on a fully static mesh. A `LinearGradient` blends its
/// stops along a straight line with no curvature at all, so this closes
/// the door on that whole category of complaint rather than tuning the
/// mesh a third time.
enum NowPlayingPalette {
    /// `DesignTokens.Color.primary` (`#23948F`) as an `RGBColor` — this
    /// file can't import `DesignTokens` circularly in a useful way for a
    /// constant, so the hex is duplicated here once, deliberately, rather
    /// than routed through `Color` and back.
    ///
    /// **Fixed 2026-08-19** — a real build failure (SeamlessMixer App
    /// Build), not a flaky one. The original `0x23.0 / 0xFF` form is
    /// invalid Swift: writing a decimal point directly on a hex integer
    /// literal makes it a *hexadecimal floating-point* literal, which
    /// Swift requires to end with a `p`-exponent (e.g. `0x23.0p0`) — plain
    /// `0x23.0` doesn't compile at all, on any Swift version. Fixed by
    /// converting each hex *integer* to `Double` before dividing, which
    /// was the actual intent (35/255, 148/255, 143/255).
    ///
    /// **Darkened 2026-08-21** — matches the same `.darkened(by: 0.45)`
    /// treatment the artwork-derived colors get (see
    /// `ArtworkPaletteExtractor.extractPalette`), so the brand-teal end of
    /// the gradient doesn't sit noticeably brighter than the rest.
    static let anchor = RGBColor(r: Double(0x23) / 255, g: Double(0x94) / 255, b: Double(0x8F) / 255).darkened(by: 0.45)

    struct Blend {
        /// 3 gradient stops, in order from the top-leading end of the
        /// screen to the bottom-trailing end — matches
        /// `NowPlayingBackground`'s `LinearGradient(colors:startPoint:
        /// endPoint:)` below.
        let colors: [Color]
        /// True when the blended background is dark enough for light/
        /// white text and icons to read clearly against it — the
        /// confirmed design's adaptive-text mechanism, driven by the same
        /// relative-luminance formula already used for this project's
        /// static design-token contrast checks.
        let isDark: Bool
    }

    /// - Parameters:
    ///   - current: the now-playing track's extracted palette, `nil`
    ///     before any track has loaded (falls back to teal-only).
    ///   - next: the next track's extracted palette — only used while
    ///     `isCrossfading` is true.
    ///   - crossfadeProgress: `PlaybackEngine.crossfadeProgress`, 0...1,
    ///     the *same* value driving the audio's own volume curve.
    static func blend(
        current: (primary: RGBColor, secondary: RGBColor)?,
        next: (primary: RGBColor, secondary: RGBColor)?,
        crossfadeProgress: Double,
        isCrossfading: Bool
    ) -> Blend {
        let base = current ?? (anchor, anchor)
        let active: (primary: RGBColor, secondary: RGBColor)
        if isCrossfading, let next {
            active = (
                RGBColor.lerp(base.primary, next.primary, t: crossfadeProgress),
                RGBColor.lerp(base.secondary, next.secondary, t: crossfadeProgress)
            )
        } else {
            active = base
        }

        let midpoint = RGBColor.lerp(active.primary, active.secondary, t: 0.5)
        let stops = [anchor, active.primary, midpoint]
        let averageLuminance = stops.map(\.luminance).reduce(0, +) / Double(stops.count)

        return Blend(colors: stops.map(\.color), isDark: averageLuminance < 0.5)
    }
}

/// Renders one `NowPlayingPalette.Blend` as a plain straight-line gradient
/// — see `NowPlayingPalette`'s own doc comment for why this replaced
/// `MeshGradient` entirely, not just its animation. `.animation(_:value:)`
/// on the colors smooths over the ~10Hz steps `PlaybackEngine`'s crossfade
/// timer produces into a continuous blend, rather than visibly stepping
/// between samples. No per-frame redraw, no drift — this only redraws when
/// `blend.colors` actually changes (a track or crossfade).
struct NowPlayingBackground: View {
    let blend: NowPlayingPalette.Blend

    var body: some View {
        LinearGradient(colors: blend.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
            .animation(.linear(duration: 0.15), value: blend.colors)
    }
}
