import SwiftUI

/// Pure blend logic for Now Playing's dynamic background — separated from
/// the `View` below so the same computation can also drive adaptive
/// text/icon color without duplicating the blend math.
///
/// **The idea, confirmed with Andy 2026-08-18 against real Apple Music
/// reference screenshots**: not a busy multi-hue mesh — a single dominant,
/// darkened tone per track (see `ArtworkPaletteExtractor`), blended
/// smoothly into the *next* track's tone exactly in step with the real
/// audio crossfade (`PlaybackEngine.crossfadeProgress`), not on an
/// approximate fixed-duration animation triggered after the blend
/// already happened. One mesh corner is deliberately always anchored to
/// the app's own teal (`DesignTokens.Color.primary`) rather than letting
/// every corner come from the artwork — the explicit differentiator from
/// Apple Music's own version, which becomes a total chameleon with no
/// persistent brand identity while something plays. This screen should
/// always read as *this app*, whatever's on the album cover.
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
    /// **Darkened 2026-08-21** — Testing (49) real-device report, screenshots
    /// across 5 different albums (very different real cover art: red/black,
    /// blue/white, warm brown, red/yellow/brown) all showed the same "blue
    /// diagonal" in the upper-left, with only the opposite side changing.
    /// Root cause: this corner was the raw, undarkened brand teal, while the
    /// other three corners are all `.darkened(by: 0.45)` (see
    /// `ArtworkPaletteExtractor.extractPalette`) — a `MeshGradient`
    /// interpolates continuously between its 4 points, so one corner sitting
    /// noticeably brighter/more saturated than the rest doesn't stay
    /// confined to its own quadrant, it visually dominates a large share of
    /// the screen regardless of what's actually playing. Matching the same
    /// darkening here keeps the teal brand anchor (hue unchanged) without
    /// letting its raw brightness drown out the genuine per-track variation
    /// in the other three corners.
    static let anchor = RGBColor(r: Double(0x23) / 255, g: Double(0x94) / 255, b: Double(0x8F) / 255).darkened(by: 0.45)

    struct Blend {
        /// Four mesh-gradient corner colors, in `[topLeft, topRight,
        /// bottomLeft, bottomRight]` order matching `MeshGradient`'s own
        /// `points:` array below.
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
        let corners = [anchor, active.primary, active.secondary, midpoint]
        let averageLuminance = corners.map(\.luminance).reduce(0, +) / Double(corners.count)

        return Blend(colors: corners.map(\.color), isDark: averageLuminance < 0.5)
    }
}

/// Renders one `NowPlayingPalette.Blend` as a full-screen mesh gradient.
/// `.animation(_:value:)` on the mesh itself smooths over the ~10Hz steps
/// `PlaybackEngine`'s crossfade timer produces into a continuous blend,
/// rather than visibly stepping between samples.
struct NowPlayingBackground: View {
    let blend: NowPlayingPalette.Blend

    var body: some View {
        MeshGradient(
            width: 2, height: 2,
            points: [[0, 0], [1, 0], [0, 1], [1, 1]],
            colors: blend.colors
        )
        .ignoresSafeArea()
        .animation(.linear(duration: 0.15), value: blend.colors)
    }
}
