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
        /// 9 mesh-gradient colors, in row-major order (top row left-to-
        /// right, then middle row, then bottom row) matching
        /// `MeshGradient(width: 3, height: 3, ...)`'s own point ordering
        /// below.
        ///
        /// **Widened from 4 to 9, 2026-08-21** — Testing (51): Andy
        /// reported the idle drift (added the same testing round prior)
        /// "happens only on the side/borders of the screen. That looks
        /// real weird." Real artifact of a 2x2 mesh: `MeshGradient`
        /// interpolates smoothly toward the center, so a single corner's
        /// motion is strongest right at that corner and fades to almost
        /// nothing by the middle — there's nothing *to* move in the middle
        /// of a 4-point mesh, it's just an interpolated average of the 4
        /// corners. A 3x3 grid gives 5 more points (the 4 edge midpoints
        /// plus the true center) to actually animate, spreading real
        /// motion across the whole screen instead of concentrating it at
        /// the 4 corners. The 5 new points are built by bilinearly
        /// interpolating the same 4 base colors this always computed
        /// (`anchor`/`active.primary`/`active.secondary`/`midpoint`) — the
        /// underlying 4-corner "story" is unchanged, this just samples it
        /// more finely.
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

        let topLeft = anchor
        let topRight = active.primary
        let bottomLeft = active.secondary
        let bottomRight = RGBColor.lerp(active.primary, active.secondary, t: 0.5)

        // Bilinearly interpolate the 4 base corners into a 3x3 grid --
        // see `colors`'s own doc comment for why. Row-major, matching
        // MeshGradient's point ordering.
        var grid: [RGBColor] = []
        for v in [0.0, 0.5, 1.0] {
            let left = RGBColor.lerp(topLeft, bottomLeft, t: v)
            let right = RGBColor.lerp(topRight, bottomRight, t: v)
            for u in [0.0, 0.5, 1.0] {
                grid.append(RGBColor.lerp(left, right, t: u))
            }
        }

        let averageLuminance = grid.map(\.luminance).reduce(0, +) / Double(grid.count)
        return Blend(colors: grid.map(\.color), isDark: averageLuminance < 0.5)
    }
}

/// Renders one `NowPlayingPalette.Blend` as a full-screen mesh gradient.
/// `.animation(_:value:)` on the *colors* smooths over the ~10Hz steps
/// `PlaybackEngine`'s crossfade timer produces into a continuous blend,
/// rather than visibly stepping between samples.
///
/// **Idle drift added 2026-08-21** — Testing (50): Andy's honest reaction
/// after actually seeing this on a real device was "nothing dynamic about
/// it... I thought it would be floating like clouds or waves." He was
/// right that it wasn't -- until this change, the mesh's 4 corner *points*
/// were a hardcoded constant (`[[0,0],[1,0],[0,1],[1,1]]`); only the
/// *colors* at those fixed positions ever changed, and only at a track or
/// crossfade boundary. Nothing moved, ever, while a track just played --
/// there was no ambient motion to fail at reading as "floating" in the
/// first place. This adds real, continuous motion: each of the 4 points
/// drifts on its own slow sine path (different period/phase per corner so
/// they don't move in lockstep), independent of `blend.colors` entirely --
/// the cloud/wave-like sway keeps going even mid-track, not just at
/// transitions. Amplitude is kept small (0.05, out of the 0...1 mesh
/// coordinate space) so it reads as a gentle sway, not a distortion.
/// **Known, flagged trade-off**: `TimelineView(.animation)` redraws every
/// frame for as long as this screen is visible, a real, continuous cost
/// (previously this view only redrew on a color change) -- acceptable for
/// a screen the user is actively looking at, not evaluated against
/// battery drain over a long multi-hour playback session.
///
/// **Widened from a 2x2 to a 3x3 mesh, 2026-08-21** — Testing (51): see
/// `NowPlayingPalette.Blend.colors`'s own doc comment for the full "motion
/// only at the edges" root cause. `driftedPoints` now animates 9 points
/// (the 4 original corners, the 4 edge midpoints, and the true center)
/// instead of 4, each on its own sine phase, so the sway is visible across
/// the whole screen rather than concentrated at the 4 corners.
struct NowPlayingBackground: View {
    let blend: NowPlayingPalette.Blend

    var body: some View {
        TimelineView(.animation) { context in
            MeshGradient(
                width: 3, height: 3,
                points: driftedPoints(at: context.date),
                colors: blend.colors
            )
            .animation(.linear(duration: 0.15), value: blend.colors)
        }
        .ignoresSafeArea()
    }

    /// Row-major, matching `NowPlayingPalette.Blend.colors`'s own ordering:
    /// top row left-to-right, then middle row, then bottom row.
    private func driftedPoints(at date: Date) -> [SIMD2<Float>] {
        let t = date.timeIntervalSinceReferenceDate

        func drift(_ base: SIMD2<Float>, period: Double, phase: Double) -> SIMD2<Float> {
            let amplitude: Float = 0.05
            let angle = (t / period + phase) * 2 * .pi
            let dx = Float(sin(angle)) * amplitude
            let dy = Float(cos(angle * 0.7)) * amplitude
            return SIMD2(
                min(1, max(0, base.x + dx)),
                min(1, max(0, base.y + dy))
            )
        }

        // 9 base positions (u, v) each in {0, 0.5, 1}, each drifting on its
        // own period/phase so the 9 points never move in lockstep.
        let basePositions: [SIMD2<Float>] = [
            SIMD2(0, 0), SIMD2(0.5, 0), SIMD2(1, 0),
            SIMD2(0, 0.5), SIMD2(0.5, 0.5), SIMD2(1, 0.5),
            SIMD2(0, 1), SIMD2(0.5, 1), SIMD2(1, 1)
        ]
        let periods: [Double] = [14, 18, 16, 21, 25, 19, 15, 17, 20]
        let phases: [Double] = [0.00, 0.15, 0.30, 0.45, 0.60, 0.75, 0.90, 0.10, 0.55]

        return zip(basePositions, zip(periods, phases)).map { base, periodPhase in
            drift(base, period: periodPhase.0, phase: periodPhase.1)
        }
    }
}
