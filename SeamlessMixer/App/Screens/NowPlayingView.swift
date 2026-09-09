import SwiftUI
import MediaPlayer

/// First real slice of the Now Playing screen, per CLAUDE.md's "Now
/// Playing (confirmed layout, first pass)" — reached by tapping Play on
/// Playlist Detail, per the confirmed Navigation Flow. Shows what's
/// actually sounding right now, driven live off the shared, app-wide
/// `PlaybackEngine`.
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
/// looked up fresh whenever the now-playing track changes — same lookup
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
/// Image color extraction (`ArtworkPaletteExtractor`) feeding a plain
/// straight-line `LinearGradient` (`Views/NowPlayingBackground.swift`),
/// blended smoothly into the *next* track's palette exactly in step with
/// the real audio crossfade (`PlaybackEngine.crossfadeProgress`), plus
/// adaptive light/dark text and icon colors throughout this screen. See
/// that file's own doc comment for the full design.
///
/// **Track-level favourite star, added 2026-09-06, moved to the toolbar
/// 2026-09-07.** Lives in the top-right `ToolbarItemGroup`, matching
/// `PlaylistDetailView`'s own star placement exactly. Still kept as its own
/// control, alongside — not instead of — the equivalent toggle in Playlist
/// Detail's/Queue's per-track "..." menus, per Andy's original "keep both"
/// call.
///
/// **Deliberate, flagged simplification still remaining:**
/// - The "..." toolbar control only holds one action ("Add to Playlist") —
///   the fuller playlist-level overflow (`PlaylistOverflowSheet`'s Rename/
///   Refresh/Delete/Share, keyed off a real `Playlist`) is still not here;
///   this screen was deliberately *not* handed the full `Playlist` (only
///   `rows`/`sourceCaption`/`store`, a lighter set) to keep its scope to
///   "show what's playing," not duplicate Playlist Detail's controls.
///   Revisit if that turns out to matter in practice.
struct NowPlayingView: View {
    let rows: [PlaylistDetailRow]
    let sourceCaption: String
    /// **Added 2026-09-06**, purely to forward to `QueueView` — this screen
    /// itself still has no favourite/"..." overflow of its own beyond
    /// "Add to Playlist" (see this file's "Deliberate, flagged
    /// simplification" note above), but `QueueView`'s per-track "..." menu
    /// needs real database access to support the per-track favorite.
    let store: PlaylistStore
    /// **Changed from `@EnvironmentObject` to a plain reference, 2026-09-09
    /// — Testing (69), the real, root-caused fix for the "..." toolbar
    /// button's still-recurring flakiness.** See `body`'s own doc comment
    /// for the full diagnosis; passed in explicitly by `PlaylistDetailView`
    /// (which already holds its own `@EnvironmentObject`) rather than
    /// re-fetched from the environment here, since re-fetching it via
    /// `@EnvironmentObject`/`@ObservedObject` is exactly the mechanism that
    /// caused this screen's whole `body` — toolbar included — to
    /// re-evaluate on every `PlaybackEngine.tick()`, ~10x/second.
    let playbackEngine: PlaybackEngine

    @Environment(\.dismiss) private var dismiss

    @State private var artworkImage: UIImage?
    @State private var showQueue = false
    /// **Added 2026-09-07, Batch 3** — drives the "Add to Playlist" sheet.
    /// Owned here (not by `AddToPlaylistView` itself) so a song added deep
    /// inside that screen's own nested "New Playlist" push can close the
    /// *whole* flow in one step — see `AddToPlaylistView`'s own doc comment
    /// for why a plain `@Environment(\.dismiss)` there wouldn't do that.
    @State private var showAddToPlaylist = false
    /// **Added 2026-09-06** — local, optimistic favorite state for whichever
    /// track is currently playing, same reasoning as `QueueView.favoriteOverrides`:
    /// `rows` is a plain snapshot, not something this screen owns/reloads,
    /// so a toggle needs its own state to show immediately. Synced from
    /// `nowPlayingRow?.isFavorite` on appear and every time the playing
    /// track changes.
    @State private var isNowPlayingFavorite = false
    /// The dynamic background's two source palettes — see
    /// `Views/NowPlayingBackground.swift`'s own doc comment for the full
    /// design. `currentPalette` is extracted alongside `artworkImage`
    /// (same lifecycle); `nextPalette` is extracted separately since the
    /// next track's artwork comes from `rows` (already resolved by
    /// `PlaylistDetailViewModel`), not a fresh query.
    @State private var currentPalette: (primary: RGBColor, secondary: RGBColor)?
    @State private var nextPalette: (primary: RGBColor, secondary: RGBColor)?

    /// **Local mirrors of `playbackEngine`'s own `@Published` state, added
    /// 2026-09-09** — kept in sync via narrow `.onReceive` subscriptions on
    /// just the specific publisher each one needs (see `body`'s trailing
    /// modifiers), rather than this screen holding a blanket
    /// `@EnvironmentObject`/`@ObservedObject` subscription to the whole
    /// object. Each of these changes at most a few times a minute in real
    /// use (a track change, a pause/resume, a route change) — nothing here
    /// ticks at `PlaybackEngine.tick()`'s ~10Hz rate, which is the entire
    /// point: this screen's own `body` (and therefore its `.toolbar`) now
    /// only re-evaluates on these genuinely infrequent events, not on every
    /// playback tick.
    @State private var nowPlayingTrackID: Int64?
    @State private var nextTrackID: Int64?
    @State private var isPaused = false
    @State private var outputRouteName = "This iPhone"
    /// The adaptive-text-color decision derived from the live background
    /// blend — see `updateIsDark(crossfadeProgress:isCrossfading:)`'s own
    /// doc comment for why this is deduped rather than a straight mirror.
    @State private var isDark = false

    private var nowPlayingRow: PlaylistDetailRow? {
        rows.first { $0.trackPersistentID == nowPlayingTrackID }
    }

    private var nextRow: PlaylistDetailRow? {
        rows.first { $0.trackPersistentID == nextTrackID }
    }

    var body: some View {
        // **Root-caused for real, 2026-09-09 — Testing (69).** The
        // "..." toolbar button was already suspected and partly addressed
        // once this same round (2026-09-09, Testing 68): swapping its
        // `Menu` for a plain `Button` (see git history / CLAUDE.md 0.25.80)
        // on the theory that a `Menu`'s real UIKit popup interaction was
        // what destabilized under this screen's ~10Hz re-render rate.
        // Testing (69) proved that theory incomplete: the *plain Button*
        // glitched in the exact same way ("takes 5-7 taps... opens when
        // the background in the ellipsis is brighter") — meaning the
        // popup was never the real culprit, just the most visibly broken
        // symptom of it.
        //
        // **The actual mechanism**: every SwiftUI view struct that
        // declares `@EnvironmentObject`/`@ObservedObject` for an object
        // has its *entire* `body` re-invoked on *any* `@Published` change
        // to that object — Combine's invalidation granularity is per
        // object, not per property. This screen previously declared
        // `@EnvironmentObject var playbackEngine`, and `PlaybackEngine
        // .elapsedSeconds` publishes on every ~0.1s timer tick during
        // playback — so this screen's whole `body`, `.toolbar` included,
        // was re-evaluated ~10x/second the entire time a track played,
        // regardless of whether the toolbar's own content actually
        // referenced `elapsedSeconds`. `.toolbar` content is bridged to
        // real `UIBarButtonItem`s under the hood, and that bridging layer
        // is evidently far less tolerant of being torn down and rebuilt
        // at that rate than an ordinary in-content `Button` is — this
        // screen's *other* plain `Button`s (the transport row) sit under
        // the identical churn and have never once been reported as flaky,
        // and `PlaylistDetailView`'s own toolbar star/"..." (which never
        // reads a ticking property in its own `body`) has likewise never
        // been reported flaky. That contrast is the real tell, not
        // `Menu` vs. `Button`.
        //
        // **Fixed properly this time**: this screen no longer subscribes
        // to `playbackEngine` at all (see the `playbackEngine` property's
        // own doc comment) — it's a plain, unobserved reference now.
        // Everything that genuinely needs to update at `tick()`'s ~10Hz
        // rate (the progress bar's elapsed time, the background gradient's
        // live crossfade blend) moved into its own small subview
        // (`NowPlayingProgressBarLive`, `NowPlayingBackgroundLive` below)
        // that holds its *own* `@ObservedObject` subscription — neither is
        // a toolbar item, so per the evidence above, ticking freely is
        // safe for both. Everything else this screen needs from
        // `playbackEngine` (which track is playing, paused state, output
        // route, and even the derived light/dark text-color decision) is
        // mirrored into local `@State` via narrow `.onReceive`
        // subscriptions on the one specific `@Published` property each
        // needs, each writing to `@State` only when the value actually
        // changes — see the trailing `.onReceive` modifiers below and
        // `updateIsDark`'s own doc comment. The net effect: this screen's
        // `body` — and its `.toolbar` — now only re-evaluates on genuinely
        // infrequent events (a track change, a pause/resume, a route
        // change, a rare light/dark flip), never on a bare playback tick.
        //
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
        // width back up through the view hierarchy -- `MarqueeText`'s own
        // `.clipped()` stops it from *rendering* outside its bounds, but
        // doesn't stop it from *sizing* its ancestors that way, so the
        // whole content column (title, transport row, everything) could end
        // up wider than the actual screen with no explicit width to stop it.
        // Fixed by pinning both dimensions explicitly instead of just one.
        ZStack {
            // **Restructured 2026-08-21** — Testing (53): Andy reported
            // white gaps opening at the screen's edges, shifting
            // continuously while a track played ("borders moving in a
            // wavy way... keeps going on whilst the song keeps playing").
            // Real, different bug from the mesh-curvature issue fixed the
            // same round -- this background used to be attached via
            // `.background { NowPlayingBackground(...) }` on the
            // `GeometryReader`/`ScrollView` below, and `.background()`'s
            // sizing can follow its *content* view's own reported size
            // rather than staying pinned to the full screen -- exactly the
            // kind of drift a screen with continuously re-rendering
            // content (the progress bar updating ~10Hz, `MarqueeText`
            // scrolling continuously) could produce. Pulling the
            // background out as its own explicit `ZStack` layer, given no
            // frame information from the foreground at all, means it can
            // never track anything else's size -- it always fills exactly
            // what the `ZStack` itself is given, permanently.
            //
            // **Isolated into its own subview, 2026-09-09** — see this
            // file's top-of-`body` doc comment; this is what lets the
            // gradient keep updating live in step with the audio crossfade
            // without dragging this screen's own `body` along for the ride.
            NowPlayingBackgroundLive(
                playbackEngine: playbackEngine,
                currentPalette: currentPalette,
                nextPalette: nextPalette
            )

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

                    // **Isolated into its own subview, 2026-09-09** — see
                    // this file's top-of-`body` doc comment. Owns its own
                    // drag state internally now too (previously
                    // `isDragging`/`dragValue` lived on this screen itself,
                    // needed only so a track change could reset a
                    // possibly-stuck drag — the subview now watches
                    // `playbackEngine.nowPlayingTrackID` directly for that,
                    // via its own `@ObservedObject`, so nothing here needs
                    // to reach into it at all).
                    NowPlayingProgressBarLive(
                        playbackEngine: playbackEngine,
                        isDisabled: nowPlayingRow == nil,
                        textColor: secondaryTextColor
                    )

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
                    // 2026-08-15 -- reads `PlaybackEngine.outputRouteName`
                    // (mirrored locally as of 2026-09-09), which tracks
                    // `AVAudioSession`'s own current route (the same source
                    // of truth Control Center uses), so it updates live the
                    // moment output switches between the phone speaker,
                    // AirPods, or a Bluetooth speaker/amp. Queue icon is
                    // real as of 2026-08-14 (see `QueueView`).
                    HStack {
                        Label(outputRouteName, systemImage: "hifispeaker")
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
        }
        .navigationBarTitleDisplayMode(.inline)
        // **Star + "..." button, both in the top-right `ToolbarItemGroup`,
        // as of 2026-09-07** — matches `PlaylistDetailView`'s own toolbar
        // layout exactly (star first, then the overflow control). Neither
        // reads a ticking property directly -- both branch on the local
        // `nowPlayingRow`/`isNowPlayingFavorite` mirrors, per this file's
        // top-of-`body` doc comment -- so as of 2026-09-09 this toolbar
        // only rebuilds on genuinely infrequent events, closing out the
        // real cause of the still-recurring "5-7 taps" glitch. `.buttonStyle
        // (.plain)` on both avoids the default-chrome bug this project has
        // already hit and fixed on every other bare Menu/Button in this app.
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    if let row = nowPlayingRow {
                        toggleNowPlayingFavorite(row: row)
                    }
                } label: {
                    Image(systemName: isNowPlayingFavorite ? "star.fill" : "star")
                        .foregroundStyle(primaryTextColor)
                }
                .buttonStyle(.plain)
                .disabled(nowPlayingRow == nil)

                Button {
                    showAddToPlaylist = true
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(primaryTextColor)
                }
                .buttonStyle(.plain)
                .disabled(nowPlayingRow == nil)
            }
        }
        .sheet(isPresented: $showAddToPlaylist) {
            if let row = nowPlayingRow {
                AddToPlaylistView(trackPersistentID: row.trackPersistentID, store: store) {
                    showAddToPlaylist = false
                }
            }
        }
        // **Narrow `.onReceive` subscriptions, 2026-09-09** — replace the
        // former `@EnvironmentObject`-driven `.onChange(of: playbackEngine
        // .X)` handlers (which required this whole screen to subscribe to
        // the entire object) with one subscription per specific `@Published`
        // property this screen actually needs, per this file's top-of-`body`
        // doc comment. `Published<T>.Publisher` emits its current value
        // immediately on subscribe (the same behavior a `CurrentValueSubject`
        // has), so these also cover this screen's first appearance -- the
        // `.onAppear` block below is a belt-and-suspenders duplicate of that
        // initial load, not the only place it happens.
        .onReceive(playbackEngine.$isPlaying) { isPlaying in
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
        .onReceive(playbackEngine.$isPaused) { isPaused = $0 }
        .onReceive(playbackEngine.$outputRouteName) { outputRouteName = $0 }
        .onReceive(playbackEngine.$nowPlayingTrackID) { newID in
            nowPlayingTrackID = newID
            loadArtwork(for: newID)
            syncNowPlayingFavorite(for: newID)
        }
        .onReceive(playbackEngine.$nextTrackPersistentID) { newID in
            nextTrackID = newID
            loadNextPalette()
        }
        .onReceive(playbackEngine.$crossfadeProgress) { progress in
            updateIsDark(crossfadeProgress: progress, isCrossfading: playbackEngine.isCrossfading)
        }
        .onReceive(playbackEngine.$isCrossfading) { crossfading in
            updateIsDark(crossfadeProgress: playbackEngine.crossfadeProgress, isCrossfading: crossfading)
        }
        .onAppear {
            nowPlayingTrackID = playbackEngine.nowPlayingTrackID
            nextTrackID = playbackEngine.nextTrackPersistentID
            isPaused = playbackEngine.isPaused
            outputRouteName = playbackEngine.outputRouteName
            loadArtwork(for: playbackEngine.nowPlayingTrackID)
            loadNextPalette()
            syncNowPlayingFavorite(for: playbackEngine.nowPlayingTrackID)
        }
        .sheet(isPresented: $showQueue) {
            QueueView(rows: rows, store: store)
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
            updateIsDark(crossfadeProgress: playbackEngine.crossfadeProgress, isCrossfading: playbackEngine.isCrossfading)
            return
        }
        let image = ArtworkResolver.loadArtwork(forTrackPersistentID: trackID, size: CGSize(width: 260, height: 260))
        artworkImage = image
        currentPalette = image.flatMap(ArtworkPaletteExtractor.extractPalette(from:))
        updateIsDark(crossfadeProgress: playbackEngine.crossfadeProgress, isCrossfading: playbackEngine.isCrossfading)
    }

    // MARK: - Favourite

    /// Reads the current track's favorite status from `rows` (already
    /// resolved by `PlaylistDetailViewModel`) into local state — see
    /// `isNowPlayingFavorite`'s own doc comment for why this needs its own
    /// state rather than reading `nowPlayingRow?.isFavorite` inline (this
    /// screen's `rows` is a fixed snapshot, so a toggle here wouldn't
    /// otherwise be reflected until the track actually changes).
    private func syncNowPlayingFavorite(for trackID: Int64?) {
        isNowPlayingFavorite = rows.first { $0.trackPersistentID == trackID }?.isFavorite ?? false
    }

    private func toggleNowPlayingFavorite(row: PlaylistDetailRow) {
        isNowPlayingFavorite.toggle()
        store.setTrackFavorite(trackPersistentID: row.trackPersistentID, isFavorite: isNowPlayingFavorite)
    }

    /// Separate from `loadArtwork` -- the next track's artwork comes from
    /// `rows` (already resolved, thumbnail-sized, by
    /// `PlaylistDetailViewModel`), not a fresh `ArtworkResolver` query, so
    /// this only needs to re-run when *which* track is next changes.
    private func loadNextPalette() {
        guard let artwork = nextRow?.artwork else {
            nextPalette = nil
            updateIsDark(crossfadeProgress: playbackEngine.crossfadeProgress, isCrossfading: playbackEngine.isCrossfading)
            return
        }
        nextPalette = ArtworkPaletteExtractor.extractPalette(from: artwork)
        updateIsDark(crossfadeProgress: playbackEngine.crossfadeProgress, isCrossfading: playbackEngine.isCrossfading)
    }

    /// **Added 2026-09-09**, replacing the old `backgroundBlend` computed
    /// property that read `playbackEngine.crossfadeProgress`/`.isCrossfading`
    /// live -- doing that directly in this screen's own `body` would have
    /// meant subscribing to the same ~10Hz-publishing object this whole fix
    /// is about *not* subscribing to. Instead, every event that could
    /// plausibly change the light/dark decision (a crossfade-progress tick,
    /// an `isCrossfading` flip, a new current/next palette) calls this, and
    /// it only actually *writes* `isDark` -- and therefore only actually
    /// re-renders this screen -- when the computed value differs from what's
    /// already there. In practice `isDark` flips rarely: the background is
    /// always darkened toward black by `ArtworkPaletteExtractor`
    /// (`.darkened(by: 0.45)`), so the light/dark threshold is very rarely
    /// crossed mid-crossfade -- most calls here are a no-op write-wise,
    /// which is exactly the point: this runs on every tick during a
    /// crossfade, but only actually changes anything on the rare occasions
    /// the light/dark call would visibly need to change anyway.
    private func updateIsDark(crossfadeProgress: Double, isCrossfading: Bool) {
        let newIsDark = NowPlayingPalette.blend(
            current: currentPalette,
            next: nextPalette,
            crossfadeProgress: crossfadeProgress,
            isCrossfading: isCrossfading
        ).isDark
        if newIsDark != isDark {
            isDark = newIsDark
        }
    }

    private var primaryTextColor: Color {
        isDark ? .white : DesignTokens.Color.textPrimary
    }

    private var secondaryTextColor: Color {
        isDark ? Color.white.opacity(0.75) : DesignTokens.Color.textSecondary
    }

    // MARK: - Time formatting

    /// `fileprivate`, not `private` -- `NowPlayingProgressBarLive` below
    /// (a sibling type in this same file) needs these too, and `private`
    /// members aren't visible outside the declaring type even within the
    /// same file.
    fileprivate static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    fileprivate static func formatRemainingTime(elapsed: Double, total: Double) -> String {
        guard total.isFinite, total > 0 else { return "-0:00" }
        return "-" + formatTime(max(0, total - elapsed))
    }

    // MARK: - Controls

    /// **`.buttonStyle(.plain)` added 2026-08-18 on all three buttons here
    /// -- real bug, not a style tweak.** None of these buttons ever set an
    /// explicit button style, so each picked up the platform's default
    /// bordered/glass chrome -- a light gray pill/circle rendered behind
    /// the icon regardless of what the icon itself draws. `.buttonStyle
    /// (.plain)` removes the chrome without changing tap targets, hit
    /// areas, or the disabled-state dimming these buttons already rely on.
    /// **Icon colors made adaptive 2026-08-18** — matches the real Apple
    /// Music reference screenshots (uniformly white icons throughout, no
    /// single control kept a distinct fixed tint). The teal brand identity
    /// lives in the background itself now (`NowPlayingPalette`'s
    /// always-present anchor point), not in singling out the play/pause
    /// button's own color. **Reads the local `isPaused` mirror as of
    /// 2026-09-09**, not `playbackEngine.isPaused` directly -- this screen
    /// no longer subscribes to `playbackEngine`, so a direct read here
    /// would only reflect whatever value happened to be current the last
    /// time something else forced a re-render, not the real current state.
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
                if isPaused {
                    playbackEngine.resume()
                } else {
                    playbackEngine.pause()
                }
            } label: {
                Image(systemName: isPaused ? "play.circle.fill" : "pause.circle.fill")
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

/// **Added 2026-09-09** — see `NowPlayingView.body`'s own doc comment for
/// the full diagnosis this is the fix for. Holds its own `@ObservedObject`
/// subscription to `playbackEngine` (the same instance `NowPlayingView`
/// itself no longer subscribes to) so its own re-renders track playback
/// position at `PlaybackEngine.tick()`'s ~10Hz rate without that churn
/// reaching `NowPlayingView`'s `body` -- and therefore its `.toolbar` --
/// at all. Not a toolbar item itself, so per the evidence gathered
/// diagnosing this bug, re-rendering this often is safe.
///
/// Owns its own drag state internally, and resets it on a track change by
/// watching `playbackEngine.nowPlayingTrackID` directly (via `.onChange`,
/// which works correctly here since this view's own `body` already
/// re-evaluates on every relevant change through its own subscription) --
/// this used to live on `NowPlayingView` itself (needed only for this
/// reset), which no longer needs to know about drag state at all.
private struct NowPlayingProgressBarLive: View {
    @ObservedObject var playbackEngine: PlaybackEngine
    let isDisabled: Bool
    let textColor: Color

    /// While the user has a finger on the slider, the displayed value comes
    /// from `dragValue` (not the live-updating `playbackEngine.elapsedSeconds`)
    /// so the thumb doesn't fight the user's own drag gesture — `seek(toSeconds:)`
    /// only actually runs once the drag ends.
    @State private var isDragging = false
    @State private var dragValue: Double = 0

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.xxs) {
            Slider(
                value: Binding(
                    get: { isDragging ? dragValue : playbackEngine.elapsedSeconds },
                    // **Guarded 2026-08-21** — Testing (51): this used to
                    // write `dragValue` unconditionally on every call, even
                    // outside an actual drag gesture. SwiftUI can invoke a
                    // Slider's setter for reasons beyond a user drag (e.g.
                    // reconciling the bound value against a just-changed
                    // `in:` range, which happens here every time the track
                    // changes and `currentTrackDurationSec` shrinks/grows).
                    // An unguarded write could silently leave `dragValue`
                    // holding a stale position that only matters the next
                    // time `isDragging` goes true -- guarding it means a
                    // stray, non-drag write can no longer corrupt what the
                    // next real drag starts from.
                    set: { if isDragging { dragValue = $0 } }
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
            .disabled(isDisabled)
            HStack {
                Text(NowPlayingView.formatTime(isDragging ? dragValue : playbackEngine.elapsedSeconds))
                Spacer()
                // Remaining time, not total duration -- matches Apple
                // Music's own convention (confirmed directly against Andy's
                // reference screenshot, "-4:09"). Real-device feedback
                // (Round 3, issue 6) asked for exactly this.
                Text(NowPlayingView.formatRemainingTime(
                    elapsed: isDragging ? dragValue : playbackEngine.elapsedSeconds,
                    total: playbackEngine.currentTrackDurationSec
                ))
            }
            .font(.caption)
            .foregroundStyle(textColor)
        }
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .onChange(of: playbackEngine.nowPlayingTrackID) { _, _ in
            // **Added 2026-08-21** — Testing (51): Andy reported the
            // progress bar "stayed at the full time for the next songs
            // even when the song was starting" after seeking near a
            // track's end a few times (to preview crossfades) and then
            // tapping the FF button twice in a row -- a stuck `isDragging`
            // could otherwise leave the slider showing a stale
            // near-the-end position from the *previous* track. A track
            // actually changing should always mean "stop trusting any
            // in-progress drag and show the real, live position."
            isDragging = false
        }
    }
}

/// **Added 2026-09-09** — see `NowPlayingView.body`'s own doc comment for
/// the full diagnosis. Holds its own `@ObservedObject` subscription so the
/// background gradient keeps blending live, in step with the real audio
/// crossfade (`playbackEngine.crossfadeProgress`), without that ~10Hz
/// churn reaching `NowPlayingView`'s own `body`. Not a toolbar item, so
/// per the evidence gathered diagnosing this bug, re-rendering this often
/// is safe -- `NowPlayingBackground` itself already only actually redraws
/// when its resolved `blend.colors` changes (see that view's own doc
/// comment), so this recomputing the blend every tick costs little even
/// though it's cheap to call regardless.
private struct NowPlayingBackgroundLive: View {
    @ObservedObject var playbackEngine: PlaybackEngine
    let currentPalette: (primary: RGBColor, secondary: RGBColor)?
    let nextPalette: (primary: RGBColor, secondary: RGBColor)?

    var body: some View {
        NowPlayingBackground(blend: NowPlayingPalette.blend(
            current: currentPalette,
            next: nextPalette,
            crossfadeProgress: playbackEngine.crossfadeProgress,
            isCrossfading: playbackEngine.isCrossfading
        ))
        .ignoresSafeArea()
    }
}

#Preview {
    NavigationStack {
        NowPlayingView(
            rows: [],
            sourceCaption: "Genre · Smooth jazz · Energy wave · 12 songs · 47 min",
            store: PlaylistStore(),
            playbackEngine: PlaybackEngine()
        )
    }
}
