import SwiftUI
import MediaPlayer

/// First real slice of the Now Playing screen, per CLAUDE.md's "Now
/// Playing (confirmed layout, first pass)" — reached by tapping Play on
/// Playlist Detail, per the confirmed Navigation Flow. Shows what's
/// actually sounding right now, driven live off the shared, app-wide
/// `PlaybackEngine` (see `SeamlessMixerApp`'s doc comment for why it moved
/// from a per-screen `@StateObject` to an `@EnvironmentObject` alongside
/// this screen).
///
/// **Real transport added 2026-08-14**, after real-device testing found the
/// original Stop-only control unusable for actually verifying playback:
/// tapping it tore the whole session down and auto-navigated away (read by
/// Andy as "pause doesn't work, it just stops and starts over"), and with no
/// seek control, reaching a real crossfade meant waiting out an entire
/// track. Controls are now a real prev/play-pause/next row
/// (`PlaybackEngine.skipToPrevious`/`.pause`/`.resume`/`.skipToNext`), and
/// the progress bar is a real draggable `Slider` calling
/// `PlaybackEngine.seek(toSeconds:)` — dragging near a track's end is now
/// the intended way to force-test a transition without waiting through a
/// whole song. No separate "Stop" button — matches Apple Music's own Now
/// Playing paradigm (pause, or navigate away; playback keeps running in the
/// background either way, per the confirmed background-audio design), not
/// an oversight.
///
/// Also added this pass: real static album artwork (`MPMediaItem.artwork`),
/// looked up fresh whenever `nowPlayingTrackID` changes — same lookup
/// pattern `PlaybackEngine.resolveFileURL` already uses elsewhere in this
/// codebase. Falls back to the flat placeholder tile when a track has no
/// artwork.
///
/// **Source caption is a scrolling `MarqueeText` as of 2026-08-14** — the
/// same real-device feedback pass found the static caption truncated for
/// longer source descriptions with no way to read the rest short of leaving
/// this screen. See `Views/MarqueeText.swift`.
///
/// **Remaining time (not total duration) shown on the right of the progress
/// bar, as of 2026-08-14** — matches Apple Music's own `-M:SS` convention,
/// confirmed directly against a real Apple Music screenshot Andy shared.
///
/// **Queue icon is real, opening `QueueView`, as of 2026-08-14** — resolves
/// a Round 4 discussion (should Playlist Detail merge into Now Playing?)
/// started from that same screenshot: it shouldn't, since real Apple Music
/// keeps its playlist-browsing screen separate too and only ever shows an
/// embedded queue *preview* from Now Playing — `QueueView` is that preview,
/// not a merge. See its own doc comment for the full reasoning and its
/// deliberately read-only first-slice scope.
///
/// **Real connected output device name, as of 2026-08-15** — replaces the
/// hardcoded "This iPhone" placeholder with `PlaybackEngine.outputRouteName`,
/// which tracks `AVAudioSession`'s own current route live. Prompted directly
/// by a real-device report where switching output mid-playback (see
/// `PlaybackEngine`'s route-change fix) was made harder to diagnose by this
/// label never actually reflecting what was connected.
///
/// **Dynamic, artwork-derived background built 2026-08-18** — real Core
/// Image color extraction (`ArtworkPaletteExtractor`) feeding a
/// `MeshGradient` (`Views/NowPlayingBackground.swift`), blended smoothly
/// into the *next* track's palette exactly in step with the real audio
/// crossfade (`PlaybackEngine.crossfadeProgress`), plus adaptive light/dark
/// text and icon colors throughout this screen. See that file's own doc
/// comment for the full design, including the deliberate teal brand-anchor
/// that's the explicit differentiator from Apple Music's own version.
/// Entirely unverified against a real device as of this writing — the
/// first use of Core Image or `MeshGradient` anywhere in this codebase, so
/// treat `ArtworkPaletteExtractor.swift` as the highest-risk file in this
/// slice if colors look wrong or it doesn't compile.
///
/// **Deliberate, flagged simplification still remaining:**
/// - **No favourite star / "..." overflow on this screen.** `PlaylistOverflowSheet`
///   is keyed off a real `Playlist`, which this screen was deliberately
///   *not* handed (only `rows`/`sourceCaption`, a lighter snapshot) to keep
///   this slice's scope to "show what's playing," not duplicate Playlist
///   Detail's controls. Revisit if that turns out to matter in practice.
struct NowPlayingView: View {
    let rows: [PlaylistDetailRow]
    let sourceCaption: String

    @EnvironmentObject private var playbackEngine: PlaybackEngine
    @Environment(\.dismiss) private var dismiss

    /// While the user has a finger on the slider, the displayed value comes
    /// from `dragValue` (not the live-updating `playbackEngine.elapsedSeconds`)
    /// so the thumb doesn't fight the user's own drag gesture — `seek(toSeconds:)`
    /// only actually runs once the drag ends.
    @State private var isDragging = false
    @State private var dragValue: Double = 0
    @State private var artworkImage: UIImage?
    @State private var showQueue = false
    /// The dynamic background's two source palettes — see
    /// `Views/NowPlayingBackground.swift`'s own doc comment for the full
    /// design. `currentPalette` is extracted alongside `artworkImage`
    /// (same lifecycle); `nextPalette` is extracted separately since the
    /// next track's artwork comes from `rows` (already resolved by
    /// `PlaylistDetailViewModel`), not a fresh query.
    @State private var currentPalette: (primary: RGBColor, secondary: RGBColor)?
    @State private var nextPalette: (primary: RGBColor, secondary: RGBColor)?

    private var nowPlayingRow: PlaylistDetailRow? {
        rows.first { $0.trackPersistentID == playbackEngine.nowPlayingTrackID }
    }

    private var nextRow: PlaylistDetailRow? {
        rows.first { $0.trackPersistentID == playbackEngine.nextTrackPersistentID }
    }

    var body: some View {
        // Wrapped in a ScrollView as of 2026-08-14 -- real-device feedback
        // found the play button, the time labels, and long titles cut off
        // ("out of range, not in the screen range") once a track was
        // playing.
        //
        // **Corrected 2026-08-14 (same day) — the first fix only addressed
        // vertical overflow.** Real-device screenshots after that fix showed
        // the cutoff was actually *horizontal* (left and right edges both
        // cut, content not centered) — a different bug the vertical-only fix
        // didn't touch at all. Root cause: `.frame(minHeight: geo.size.height)`
        // constrained height but never explicitly constrained *width*, and
        // `MarqueeText`'s inner content (two `.fixedSize()` copies of
        // `sourceCaption` side by side, deliberately wider than the screen
        // so it has somewhere to scroll to) could report that large ideal
        // width back up through the view hierarchy — `MarqueeText`'s own
        // `.clipped()` stops it from *rendering* outside its bounds, but
        // doesn't stop it from *sizing* its ancestors that way, so the
        // whole content column (title, transport row, everything) could end
        // up wider than the actual screen with no explicit width to stop it.
        // Fixed by pinning both dimensions explicitly instead of just one.
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: DesignTokens.Spacing.lg) {
                    if !sourceCaption.isEmpty {
                        // Real scrolling marquee (2026-08-14) — a static,
                        // centered, single-line caption truncated for longer
                        // source descriptions (e.g. several combined
                        // sources), with no way to read the rest without
                        // leaving this screen.
                        MarqueeText(text: sourceCaption, color: secondaryTextColor)
                            .padding(.horizontal, DesignTokens.Spacing.lg)
                    }

                    Spacer()

                    artworkTile

                    if let row = nowPlayingRow {
                        VStack(spacing: DesignTokens.Spacing.xxs) {
                            Text(row.title)
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(primaryTextColor)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                            Text(row.artist)
                                .font(.body)
                                .foregroundStyle(secondaryTextColor)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, DesignTokens.Spacing.lg)
                    } else {
                        Text("Nothing playing")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(secondaryTextColor)
                    }

                    progressBar

                    controls

                    if let nextRow {
                        HStack(spacing: DesignTokens.Spacing.xs) {
                            Image(systemName: "arrow.triangle.merge")
                                .font(.footnote)
                                .foregroundStyle(DesignTokens.Color.secondary)
                            // Next-track thumbnail, added 2026-08-18 per
                            // Andy's confirmed request. Reuses `nextRow
                            // .artwork` directly -- already resolved by
                            // `PlaylistDetailViewModel.load()` (via
                            // `ArtworkResolver`) as part of building `rows`,
                            // so this needs no new query of its own.
                            nextTrackThumbnail(for: nextRow)
                            Text("Blending into \(nextRow.title)")
                                .font(.footnote)
                                .foregroundStyle(secondaryTextColor)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    // Bottom row per the confirmed design: connected output
                    // device + queue icon. Output device is real as of
                    // 2026-08-15 -- reads `PlaybackEngine.outputRouteName`,
                    // which tracks `AVAudioSession`'s own current route
                    // (the same source of truth Control Center uses), so it
                    // updates live the moment output switches between the
                    // phone speaker, AirPods, or a Bluetooth speaker/amp.
                    // Queue icon is real as of 2026-08-14 (see `QueueView`).
                    HStack {
                        Label(playbackEngine.outputRouteName, systemImage: "hifispeaker")
                            .font(.caption)
                            .foregroundStyle(secondaryTextColor)
                            .lineLimit(1)
                        Spacer()
                        Button {
                            showQueue = true
                        } label: {
                            Image(systemName: "list.bullet")
                                .foregroundStyle(primaryTextColor)
                        }
                        .buttonStyle(.plain)
                        .disabled(nowPlayingRow == nil)
                    }
                    .padding(.horizontal, DesignTokens.Spacing.lg)
                }
                .padding(.vertical, DesignTokens.Spacing.lg)
                .frame(width: geo.size.width)
                .frame(minHeight: geo.size.height)
            }
        }
        .background {
            // Real dynamic, artwork-derived background, added 2026-08-18 --
            // replaces the static `DesignTokens.Color.background` fill.
            // See `Views/NowPlayingBackground.swift`'s own doc comment.
            NowPlayingBackground(blend: backgroundBlend)
        }
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: playbackEngine.isPlaying) { _, isPlaying in
            // If playback stops entirely (queue ran out, or an error) while
            // this screen is showing, there's nothing left to display --
            // popping back to Playlist Detail is a cleaner outcome than
            // sitting on a "Nothing playing" screen the user didn't
            // navigate to on purpose. Pausing does NOT trigger this --
            // `isPlaying` stays true while paused, only a genuine stop
            // flips it.
            if !isPlaying {
                dismiss()
            }
        }
        .onChange(of: playbackEngine.nowPlayingTrackID) { _, trackID in
            loadArtwork(for: trackID)
        }
        .onChange(of: playbackEngine.nextTrackPersistentID) { _, _ in
            loadNextPalette()
        }
        .onAppear {
            loadArtwork(for: playbackEngine.nowPlayingTrackID)
            loadNextPalette()
        }
        .sheet(isPresented: $showQueue) {
            QueueView(rows: rows)
        }
    }

    // MARK: - Artwork

    @ViewBuilder
    private var artworkTile: some View {
        RoundedRectangle(cornerRadius: DesignTokens.Size.cornerRadiusArtwork)
            .fill(DesignTokens.Color.surfaceTint)
            .frame(width: 260, height: 260)
            .overlay {
                if let artworkImage {
                    Image(uiImage: artworkImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 260, height: 260)
                        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Size.cornerRadiusArtwork))
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: DesignTokens.Size.iconLarge * 2))
                        .foregroundStyle(DesignTokens.Color.primaryText)
                }
            }
    }

    /// Small artwork tile for the "Blending into [next track]" indicator —
    /// same flat-icon fallback convention every other artwork tile in this
    /// app uses when a track has none.
    @ViewBuilder
    private func nextTrackThumbnail(for row: PlaylistDetailRow) -> some View {
        Group {
            if let artwork = row.artwork {
                Image(uiImage: artwork)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: DesignTokens.Size.cornerRadiusSmall)
                        .fill(DesignTokens.Color.surfaceTint)
                    Image(systemName: "music.note")
                        .font(.caption2)
                        .foregroundStyle(DesignTokens.Color.primaryText)
                }
            }
        }
        .frame(width: 20, height: 20)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Size.cornerRadiusSmall))
    }

    /// **Fixed 2026-08-18** — was a single-item `MPMediaQuery` lookup using
    /// `MPMediaPropertyPredicate` on `MPMediaItemPropertyPersistentID`, the
    /// same unreliable pattern already fixed in three other places this
    /// project (see `MixBuilder.requeryItem`'s own doc comment) — large
    /// `UInt64` persistentID values can silently fail to match via this
    /// predicate even when the track genuinely exists. Found while building
    /// `ArtworkResolver` for Playlist Detail's own per-track thumbnails;
    /// this screen's big artwork tile now goes through that same reliable
    /// helper instead, at its own higher resolution (`rows`' own cached
    /// artwork, used for the small next-track thumbnail below, is rendered
    /// at thumbnail size and would look soft blown up to 260pt).
    private func loadArtwork(for trackID: Int64?) {
        guard let trackID else {
            artworkImage = nil
            currentPalette = nil
            return
        }
        let image = ArtworkResolver.loadArtwork(forTrackPersistentID: trackID, size: CGSize(width: 260, height: 260))
        artworkImage = image
        currentPalette = image.flatMap(ArtworkPaletteExtractor.extractPalette(from:))
    }

    /// Separate from `loadArtwork` -- the next track's artwork comes from
    /// `rows` (already resolved, thumbnail-sized, by
    /// `PlaylistDetailViewModel`), not a fresh `ArtworkResolver` query, so
    /// this only needs to re-run when *which* track is next changes.
    private func loadNextPalette() {
        guard let artwork = nextRow?.artwork else {
            nextPalette = nil
            return
        }
        nextPalette = ArtworkPaletteExtractor.extractPalette(from: artwork)
    }

    /// The dynamic background's current blend, and the adaptive text/icon
    /// colors it implies -- see `NowPlayingPalette.blend`'s own doc
    /// comment. Reads `playbackEngine.crossfadeProgress`/`.isCrossfading`
    /// directly (both `@Published`), so this recomputes live in step with
    /// the real audio crossfade, not on a separate approximated timer.
    private var backgroundBlend: NowPlayingPalette.Blend {
        NowPlayingPalette.blend(
            current: currentPalette,
            next: nextPalette,
            crossfadeProgress: playbackEngine.crossfadeProgress,
            isCrossfading: playbackEngine.isCrossfading
        )
    }

    private var primaryTextColor: Color {
        backgroundBlend.isDark ? .white : DesignTokens.Color.textPrimary
    }

    private var secondaryTextColor: Color {
        backgroundBlend.isDark ? Color.white.opacity(0.75) : DesignTokens.Color.textSecondary
    }

    // MARK: - Progress

    private var progressBar: some View {
        VStack(spacing: DesignTokens.Spacing.xxs) {
            Slider(
                value: Binding(
                    get: { isDragging ? dragValue : playbackEngine.elapsedSeconds },
                    set: { dragValue = $0 }
                ),
                in: 0...max(playbackEngine.currentTrackDurationSec, 1),
                onEditingChanged: { editing in
                    if editing {
                        dragValue = playbackEngine.elapsedSeconds
                        isDragging = true
                    } else {
                        playbackEngine.seek(toSeconds: dragValue)
                        isDragging = false
                    }
                }
            )
            .tint(DesignTokens.Color.primary)
            .disabled(nowPlayingRow == nil)
            HStack {
                Text(Self.formatTime(isDragging ? dragValue : playbackEngine.elapsedSeconds))
                Spacer()
                // Remaining time, not total duration -- matches Apple
                // Music's own convention (confirmed directly against Andy's
                // reference screenshot, "-4:09"). Real-device feedback
                // (Round 3, issue 6) asked for exactly this.
                Text(Self.formatRemainingTime(
                    elapsed: isDragging ? dragValue : playbackEngine.elapsedSeconds,
                    total: playbackEngine.currentTrackDurationSec
                ))
            }
            .font(.caption)
            .foregroundStyle(secondaryTextColor)
        }
        .padding(.horizontal, DesignTokens.Spacing.lg)
    }

    private static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private static func formatRemainingTime(elapsed: Double, total: Double) -> String {
        guard total.isFinite, total > 0 else { return "-0:00" }
        return "-" + formatTime(max(0, total - elapsed))
    }

    // MARK: - Controls

    /// **`.buttonStyle(.plain)` added 2026-08-18 on all three buttons here
    /// -- real bug, not a style tweak.** None of these buttons ever set an
    /// explicit button style, so each picked up the platform's default
    /// bordered/glass chrome -- a light gray pill/circle rendered behind
    /// the icon regardless of what the icon itself draws. Andy's real
    /// device screenshot showed exactly this: gray capsule backgrounds
    /// behind the plain "backward.fill"/"forward.fill" glyphs (which have
    /// no background of their own) and a second, larger gray circle behind
    /// the "play.circle.fill"/"pause.circle.fill" glyph's own teal circle.
    /// Same class of bug as `PlaylistDetailView`'s per-track Menu and the
    /// A-Z index rail earlier this session -- a bare `Button`/`Menu` with
    /// only an icon label picks up unwanted default chrome unless
    /// `.buttonStyle(.plain)` explicitly opts out of it. Andy: "Why is
    /// there a patch of grey behind the 3 dots? It seems to be a feature
    /// too behind the play, ff and rewind buttons in Now Playing screen.
    /// Let's get rid of them... in both screens." `.buttonStyle(.plain)`
    /// removes the chrome without changing tap targets, hit areas, or the
    /// disabled-state dimming these buttons already rely on.
    /// **Icon colors made adaptive 2026-08-18** (were fixed
    /// `DesignTokens.Color.primaryText`/`.primary`) — Andy asked directly
    /// that the transport buttons' colors respond to the new dynamic
    /// background too, matching the real Apple Music reference screenshots
    /// he shared (uniformly white icons throughout, no single control kept
    /// a distinct fixed tint). The teal brand identity lives in the
    /// background itself now (`NowPlayingPalette`'s always-present anchor
    /// point), not in singling out the play/pause button's own color.
    private var controls: some View {
        HStack(spacing: DesignTokens.Spacing.xl) {
            Button {
                playbackEngine.skipToPrevious()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.title2)
                    .foregroundStyle(primaryTextColor)
            }
            .buttonStyle(.plain)
            .disabled(nowPlayingRow == nil)

            Button {
                if playbackEngine.isPaused {
                    playbackEngine.resume()
                } else {
                    playbackEngine.pause()
                }
            } label: {
                Image(systemName: playbackEngine.isPaused ? "play.circle.fill" : "pause.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(primaryTextColor)
            }
            .buttonStyle(.plain)
            .disabled(nowPlayingRow == nil)

            Button {
                playbackEngine.skipToNext()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title2)
                    .foregroundStyle(primaryTextColor)
            }
            .buttonStyle(.plain)
            .disabled(nextRow == nil)
        }
    }
}

#Preview {
    NavigationStack {
        NowPlayingView(rows: [], sourceCaption: "Genre · Smooth jazz · Energy wave · 12 songs · 47 min")
            .environmentObject(PlaybackEngine())
    }
}
