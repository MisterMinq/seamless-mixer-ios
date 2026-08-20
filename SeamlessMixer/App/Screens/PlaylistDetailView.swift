import SwiftUI
import UIKit
import PlaylistCore

/// The screen a generated seamless playlist lands on right after "Build
/// Mix" (per the confirmed Navigation Flow: Hub -> Build Mix -> Playlist
/// Detail -> Now Playing) — the bridge between picking a source and actually
/// playing something. Layout per CLAUDE.md's "Playlist Detail (confirmed
/// layout, first pass)": back chevron (automatic, via `NavigationStack`) +
/// star/dots top row, collage artwork, title + source-context subtitle, a
/// single centered Play button, track list reusing the Queue screen's
/// teal/gray connector-line treatment, and a footer line.
///
/// **Deliberate, flagged simplifications for this slice:**
/// - Favorite (star) and the "..." overflow sheet (`PlaylistOverflowSheet`
///   — Favourite/Rename/Refresh/Delete real, Share/Play Next still disabled
///   placeholders) are both wired for real now, per Tiers 1 and 2 of
///   `documentation/Editability_UX_Gap_Analysis.docx`. Rename and Refresh
///   both change something this screen displays (`displayName`, the track
///   list) without this screen being told directly — see `displayName`'s
///   and the sheet's `onDismiss` doc comments below for how that's kept in
///   sync without this view observing `store.playlists` itself.
/// - **Play is real now, blends transitions, and now navigates to Now
///   Playing** — matching the confirmed Navigation Flow (Play -> Now
///   Playing) for the first time; previously Play just started audio
///   in-place with no Now Playing screen to go to. `PlaybackEngine` (built
///   up over four slices: single-track playback, sequential auto-advance,
///   equal-power crossfade blending, and now the elapsed/duration/next-
///   track state Now Playing needs) is a real implementation of CLAUDE.md's
///   "Mixing Engine — AVAudioEngine Design". **It's now an
///   `@EnvironmentObject`, not a per-screen `@StateObject`** — injected once
///   at the app root (`SeamlessMixerApp`) so playback survives navigating
///   away from this screen, rather than being torn down and rebuilt every
///   time. **Fixed 2026-08-13** (see `isThisPlaylistPlaying`): Play used to
///   always restart this playlist from track 1 even if it was already the
///   one playing — flagged at the time as "a deliberate simplification,"
///   but Andy's first real-device listening pass showed this was a real
///   navigation dead-end, not a minor gap: there was no persistent
///   mini-player yet, so navigating back from Now Playing and tapping Play
///   again to get back was the *only* way back in, and doing so restarted
///   the session (and, combined with a separate `PlaybackEngine` bug, could
///   leave two sessions audible at once). Now Play checks
///   `playbackEngine.currentPlaylistID` first and just reopens Now Playing
///   on the in-progress session when it matches, rather than restarting. A
///   full persistent mini-player (reachable from *any* screen, not just this
///   one) remains the confirmed design's fuller fix and is still not built.
///   The now-playing row is still highlighted in the track list here too, so
///   this screen keeps making sense as its own view of playback state, not
///   just a launch point for Now Playing.
/// - Collage artwork is the same flat placeholder tile `MyMixesView` uses,
///   not real per-track artwork compositing.
/// - Each track row's "..." is a real `Menu` (Tier 3): "Remove from this
///   mix" actually deletes the row and renumbers the rest, via
///   `PlaylistDetailViewModel.removeTrack`. "Play Next" stays visible but
///   disabled, blocked on the not-yet-built playback queue.
/// - **Manual drag-to-reorder is real now too** (Tier 3, the other half):
///   the screen is a `List` (not a plain `VStack`) specifically so `.onMove`
///   works, with an `EditButton` in the toolbar to enter/exit reorder mode
///   — SwiftUI's standard pattern for this. **First use of `.onMove`/
///   `EditButton` in this codebase, flagged as this slice's highest-risk
///   part** (same "new territory, check here first" flagging
///   `ArtistPickerView`'s A-Z rail got): untested outside Codemagic's
///   compile/screenshot step, since neither proves drag actually reorders
///   correctly or that the per-row `Menu` stays tappable while `EditMode`
///   is active — that needs Andy's real-device check. The footer lives in
///   its own non-reorderable `Section` with hidden separators/transparent
///   background so it blends into the `List` rather than reading as a list
///   row itself; the teal/gray connector line moved from a separate view
///   *between* rows into the bottom of each row itself, since `List` rows
///   don't have a clean way to render a shared element spanning two
///   adjacent rows. Adding a track to an already-built playlist (short of a
///   full Refresh) is still not implemented — see CLAUDE.md's Rule 8 gap
///   list.
/// - **`header` moved out of the `List` entirely, 2026-08-14** — see
///   `body`'s own doc comment. It used to be the `List`'s own first
///   `Section`, which meant scrolling the track list scrolled the header
///   (artwork/title/Play button) right along with it; real-device feedback
///   made clear that's not what was wanted, and that this screen is what
///   Andy had been describing all along when he talked about a "queue"
///   under the Play button, not the separate `QueueView` screen. `header`
///   is now a plain fixed view above the `List`, and the `List`
///   auto-scrolls to whichever track is currently playing.
struct PlaylistDetailView: View {
    let playlist: Playlist
    let store: PlaylistStore

    @StateObject private var viewModel = PlaylistDetailViewModel()
    @EnvironmentObject private var playbackEngine: PlaybackEngine
    @State private var showNowPlaying = false
    /// The DRM-exclusion message from the build that landed the user here,
    /// if any — see `showExclusionAlert`'s doc comment on `init` for why
    /// this screen owns presenting it rather than `MyMixesView`.
    private let initialExclusionMessage: String?
    /// **Added 2026-08-21**, per Andy's direct request — the actual
    /// excluded tracks, not just the summary count/message, so he can spot-
    /// check specific songs (the same way "Games"/"Galaxy" got settled
    /// back in 0.25.13) instead of only seeing an aggregate number.
    private let initialExcludedTracks: [Track]
    /// Seeded straight from `initialExclusionMessage` at `init` time (not
    /// toggled by an `.onAppear`) so the alert is already primed to show
    /// the moment this screen actually mounts — added 2026-08-14, moved
    /// here from `MyMixesView` after real-device testing found presenting
    /// this alert *there*, in the same state update as the navigation push
    /// that reaches this screen, left a blank white screen behind it once
    /// dismissed. See `MyMixesView.handleBuilt`'s doc comment for the full
    /// diagnosis.
    @State private var showExclusionAlert: Bool
    /// **Added 2026-08-21** — presents `ExcludedSongsView` when the user
    /// taps "View List" on the exclusion alert. Kept as a separate sheet
    /// rather than folded into the alert itself since `Alert` can't hold a
    /// scrollable list.
    @State private var showExcludedSongsList = false
    // Seeded from `playlist.isFavorite` at init so the star renders correctly
    // immediately, then updated optimistically on tap — `playlist` itself is
    // a `let` snapshot from navigation, not observed, so it wouldn't reflect
    // a toggle on its own even though `PlaylistStore.setFavorite` persists
    // and refreshes the underlying data (My Mixes picks that up via
    // `@ObservedObject`; this screen needs its own local copy).
    @State private var isFavorite: Bool
    /// Same reasoning as `isFavorite` above — `playlist.name` is a stale
    /// snapshot, so Rename (via `PlaylistOverflowSheet`) updates this local
    /// copy through its `onRenamed` callback rather than this view somehow
    /// re-reading `playlist` after the fact.
    @State private var displayName: String
    @State private var showOverflow = false
    @Environment(\.dismiss) private var dismiss

    /// True when the session currently loaded in `PlaybackEngine` is *this*
    /// playlist — loaded, not necessarily audibly playing (see
    /// `isThisPlaylistAudiblyPlaying` below for that distinction). Added
    /// 2026-08-13, alongside `PlaybackEngine.currentPlaylistID`, to fix a
    /// real navigation dead-end Andy hit: previously the Play button always
    /// called `play(queue:)` again regardless, which restarted from track 1
    /// and — combined with `PlaybackEngine`'s now-fixed chain-overlap bug —
    /// was the direct cause of "two songs playing" when he navigated back
    /// here and tapped Play just to get back to Now Playing. Now, tapping
    /// Play while this exact playlist is already loaded (playing OR paused)
    /// just re-opens Now Playing on the in-progress session instead of
    /// restarting it.
    private var isThisPlaylistLoaded: Bool {
        playbackEngine.isPlaying && playlist.id != nil && playbackEngine.currentPlaylistID == playlist.id
    }

    /// True only when this playlist is loaded *and* actually audible right
    /// now — distinct from `isThisPlaylistLoaded`, which stays true while
    /// paused (deliberately, so "resume this session" logic keeps working).
    /// Added 2026-08-14 to fix a real bug: the animated `NowPlayingBarsView`
    /// was keyed off `isThisPlaylistLoaded` alone, so it kept animating —
    /// visually claiming something was playing — even after the user tapped
    /// Pause and no audio was actually sounding.
    private var isThisPlaylistAudiblyPlaying: Bool {
        isThisPlaylistLoaded && !playbackEngine.isPaused
    }

    /// **Fixed 2026-08-18, real bug, second attempt at this same column.**
    /// The 2026-08-14 fix widened this from 20pt to a fixed 26pt
    /// specifically to stop two-digit numbers ("25") wrapping onto two
    /// lines — but a fixed constant just moves the same problem to the next
    /// digit count. Andy's real screenshot showed a 131-track mix with
    /// three-digit positions ("98," "99," "100"+) rendering as "1…" — the
    /// same wrap/truncation bug, just one digit later, because 26pt was
    /// sized for "up to 2 digits," not "however many this playlist actually
    /// needs." Computed from `viewModel.rows.count` instead of a guessed
    /// constant, so it's correct for any playlist size going forward
    /// without needing a third guess at some new fixed number.
    private var numberColumnWidth: CGFloat {
        let maxDigits = String(max(viewModel.rows.count, 1)).count
        return CGFloat(14 + maxDigits * 8)
    }

    init(playlist: Playlist, store: PlaylistStore, initialExclusionMessage: String? = nil, initialExcludedTracks: [Track] = []) {
        self.playlist = playlist
        self.store = store
        self.initialExclusionMessage = initialExclusionMessage
        self.initialExcludedTracks = initialExcludedTracks
        _isFavorite = State(initialValue: playlist.isFavorite)
        _displayName = State(initialValue: playlist.name)
        _showExclusionAlert = State(initialValue: initialExclusionMessage != nil)
    }

    var body: some View {
        // **Restructured 2026-08-14**, after real-device feedback made clear
        // this screen was never actually the "Queue/Up Next" screen Andy
        // thought he was describing -- he'd been talking about *this*
        // screen (Playlist Detail: artwork/title/Play button + the track
        // list underneath it) the whole time, and the real complaint was
        // that this whole thing was one continuous `List`, so scrolling the
        // track list dragged the header -- artwork, title, the Play button
        // -- up and off-screen right along with it. Split into a fixed
        // `header` (a plain view, never inside any scroll container) above
        // a separately-scrollable track list below it, so the header is
        // always visible and only the tracks scroll. `trackListAndFooter`
        // also auto-scrolls to whichever track is currently playing (see
        // `scrollToNowPlaying`), directly answering the other half of the
        // same feedback: "after a while I do not know what is playing."
        VStack(spacing: 0) {
            header
                .background(DesignTokens.Color.background)

            Group {
                if viewModel.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.rows.isEmpty {
                    Text("This playlist has no tracks yet.")
                        .font(.body)
                        .foregroundStyle(DesignTokens.Color.textSecondary)
                        .padding(.horizontal, DesignTokens.Spacing.md)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    trackListAndFooter
                }
            }
        }
        .background(DesignTokens.Color.background)
        // **Visible title text suppressed 2026-08-15, fixed for real
        // 2026-08-15 (same day).** Andy flagged this as real, pointless
        // duplication: the mix's name already reads prominently in
        // `header`, right below the artwork, and the confirmed design's own
        // top-row spec was always just "back chevron + star/dots" (matching
        // Now Playing's "no large title, just a collapse chevron") — a
        // nav-bar title text was never part of the intended layout here, it
        // just quietly crept in. **First attempt didn't actually work**:
        // kept `.navigationTitle(displayName)` set and added an empty
        // `ToolbarItem(placement: .principal) { EmptyView() }`, on the
        // (textbook, but wrong in practice) assumption that a `.principal`
        // toolbar item fully overrides the title view — a real-device
        // screenshot showed the name still rendering next to Edit despite
        // that. Fixed by setting `.navigationTitle("")` directly instead —
        // the empty string is what SwiftUI's real nav bar actually reads
        // for what to draw, so this is the version confirmed to work rather
        // than the "should work" one. Trade-off, accepted deliberately: an
        // empty title means VoiceOver's own automatic screen-title
        // announcement and a subsequent screen's back-button label (this
        // app never pushes deeper than this from here today, so the latter
        // doesn't currently matter in practice) lose that value too — worth
        // a real accessibility label on this screen if that's ever raised
        // as its own issue, not folded into this fix blind.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                // Drag-to-reorder's entry point -- SwiftUI's standard
                // pattern for a `List` with `.onMove`: toggles the
                // environment's `editMode`, which `List` reads to show
                // drag handles on rows with an `.onMove` modifier.
                if !viewModel.rows.isEmpty {
                    EditButton()
                        .tint(DesignTokens.Color.primaryText)
                }
                Button {
                    isFavorite.toggle()
                    if let id = playlist.id {
                        store.setFavorite(playlistID: id, isFavorite: isFavorite)
                    }
                } label: {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                }
                .tint(DesignTokens.Color.primaryText)
                Button {
                    showOverflow = true
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .tint(DesignTokens.Color.primaryText)
            }
        }
        .task {
            viewModel.load(playlist: playlist, store: store)
        }
        // Play's destination, per the confirmed Navigation Flow (Play ->
        // Now Playing). `rows`/`subtitle` are handed over as a plain
        // snapshot rather than re-fetched by `NowPlayingView` itself --
        // this screen already has them loaded, and `PlaybackEngine` only
        // exposes track *IDs*, never titles/artists, so something has to
        // supply that lookup.
        .navigationDestination(isPresented: $showNowPlaying) {
            NowPlayingView(rows: viewModel.rows, sourceCaption: viewModel.subtitle)
        }
        // `onDismiss` re-loads regardless of which action was taken (Rename/
        // Refresh/neither) -- Refresh replaces this playlist's tracks, so
        // the track list/subtitle need a fresh read; re-running the same
        // load for a plain Rename or a dismiss-without-action is a cheap,
        // harmless no-op by comparison, and simpler than threading a
        // "did anything actually change" flag back out of the sheet.
        .sheet(isPresented: $showOverflow, onDismiss: {
            viewModel.load(playlist: playlist, store: store)
        }) {
            PlaylistOverflowSheet(
                playlist: playlist, store: store,
                onRenamed: { displayName = $0 },
                onDeleted: { dismiss() }
            )
        }
        // Moved here from `MyMixesView` 2026-08-14 -- see `showExclusionAlert`'s
        // own doc comment for why presenting this alongside a navigation
        // push (on the pushing screen) caused a real blank-white-screen bug.
        .alert("Some songs couldn't be included", isPresented: $showExclusionAlert) {
            // **"View List" added 2026-08-21**, per Andy's direct request —
            // only shown when there's actually a list to view (an alert with
            // a dead-end button reading "View List" for an empty array would
            // be worse than not offering it).
            if !initialExcludedTracks.isEmpty {
                Button("View List") { showExcludedSongsList = true }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(initialExclusionMessage ?? "")
        }
        .sheet(isPresented: $showExcludedSongsList) {
            ExcludedSongsView(tracks: initialExcludedTracks)
        }
    }

    // MARK: - Track list + footer (scrollable, header excluded)

    /// The scrollable part of this screen — track rows plus the footer —
    /// separated out 2026-08-14 so scrolling it never moves `header` above
    /// it (see `body`'s own doc comment for why). Still a `List` (not a
    /// plain `ScrollView`) so `.onMove`/`EditButton` drag-to-reorder keeps
    /// working exactly as before; only what's *inside* the scrollable area
    /// changed, not the reordering mechanism itself.
    ///
    /// Wrapped in a `ScrollViewReader` so the currently-playing row can be
    /// scrolled into view automatically — `onAppear` handles landing on
    /// this screen while something's already playing partway through the
    /// list, `onChange(of: playbackEngine.nowPlayingTrackID)` keeps
    /// following it as playback advances. Directly answers the other half
    /// of the real-device report that prompted this restructuring: "the
    /// 3rd song playing is not on top, meaning after a while I do not know
    /// what is playing."
    private var trackListAndFooter: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    ForEach(Array(viewModel.rows.enumerated()), id: \.element.id) { index, row in
                        trackRow(
                            row, isLast: index == viewModel.rows.count - 1, isImminent: index == 0,
                            // `!playbackEngine.isPaused` -- same 2026-08-14
                            // fix as `isThisPlaylistAudiblyPlaying` above:
                            // don't show animated bars on a paused track.
                            isNowPlaying: playbackEngine.isPlaying && !playbackEngine.isPaused && playbackEngine.nowPlayingTrackID == row.trackPersistentID
                        )
                    }
                    .onMove { source, destination in
                        viewModel.moveTracks(from: source, to: destination, playlist: playlist, store: store)
                    }
                }
                .listRowInsets(EdgeInsets(top: 0, leading: DesignTokens.Spacing.md, bottom: 0, trailing: DesignTokens.Spacing.md))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

                Section {
                    footer
                }
                .listRowInsets(EdgeInsets(top: 0, leading: DesignTokens.Spacing.md, bottom: 0, trailing: DesignTokens.Spacing.md))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .onAppear {
                scrollToNowPlaying(proxy: proxy)
            }
            .onChange(of: playbackEngine.nowPlayingTrackID) { _, _ in
                scrollToNowPlaying(proxy: proxy)
            }
        }
    }

    /// Scrolls the track list so whichever row is currently playing lands
    /// near the top of the visible area. A no-op if nothing's playing, or
    /// if the track that's playing isn't actually part of *this* playlist
    /// (a different mix playing in the background while this screen happens
    /// to be open) — `first(where:)` simply finds nothing to scroll to.
    private func scrollToNowPlaying(proxy: ScrollViewProxy) {
        guard let nowPlayingID = playbackEngine.nowPlayingTrackID,
              let row = viewModel.rows.first(where: { $0.trackPersistentID == nowPlayingID }) else { return }
        withAnimation {
            proxy.scrollTo(row.id, anchor: .top)
        }
    }

    // MARK: - Header

    /// `.padding(...)` moved here from the old screen-level `ScrollView`
    /// padding — the `List`'s header `Section` now uses zero `listRowInsets`
    /// (so the artwork tile can stretch edge-to-edge like it always could),
    /// which means header content that *should* stay inset needs its own
    /// padding instead of inheriting it from a shared container.
    private var header: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            // **Real collage artwork, added 2026-08-20** -- was a flat
            // placeholder (a single "music.note.list" icon on a tinted
            // square) the whole time; per Andy's direct request and the
            // confirmed design's own "auto-generated collage artwork"
            // note, up to 4 distinct albums from this mix's own tracks
            // now tile a real 2x2 grid instead. Falls back to the same
            // flat placeholder only if no track artwork resolved at all
            // (e.g. an empty or not-yet-loaded playlist).
            Group {
                if viewModel.collageImages.isEmpty {
                    RoundedRectangle(cornerRadius: DesignTokens.Size.cornerRadiusArtwork)
                        .fill(DesignTokens.Color.surfaceTint)
                        .overlay(
                            Image(systemName: "music.note.list")
                                .font(.system(size: DesignTokens.Size.iconLarge))
                                .foregroundStyle(DesignTokens.Color.primaryText)
                        )
                } else {
                    CollageArtworkView(images: viewModel.collageImages)
                        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Size.cornerRadiusArtwork))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 220)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text(displayName)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(DesignTokens.Color.textPrimary)
                if !viewModel.subtitle.isEmpty {
                    Text(viewModel.subtitle)
                        .font(.footnote)
                        .foregroundStyle(DesignTokens.Color.textSecondary)
                }
            }

            VStack(spacing: DesignTokens.Spacing.xxs) {
                Button {
                    guard !viewModel.rows.isEmpty else { return }
                    // Only start a fresh session if this playlist isn't
                    // already loaded (playing OR paused) — otherwise just
                    // reopen Now Playing on what's already in progress. See
                    // `isThisPlaylistLoaded`'s doc comment for why this
                    // matters.
                    if !isThisPlaylistLoaded {
                        playbackEngine.play(
                            queue: viewModel.rows.map {
                                PlaybackEngine.QueuedTrack(
                                    trackPersistentID: $0.trackPersistentID,
                                    crossfadeStartOffsetSec: $0.crossfadeStartOffsetSec,
                                    crossfadeDurationSec: $0.crossfadeDurationSec,
                                    playableStartSec: $0.playableStartSec
                                )
                            },
                            playlistID: playlist.id
                        )
                    }
                    showNowPlaying = true
                } label: {
                    // `Label`'s `systemImage:` only takes a static glyph name,
                    // not a custom view, so the "Now Playing" state is built
                    // by hand here instead to use the real animated
                    // `NowPlayingBarsView` (2026-08-14, replacing a static
                    // "waveform" glyph real-device feedback called "no flair").
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        // Bars only animate when actually audible -- keyed
                        // off `isThisPlaylistAudiblyPlaying`, not just
                        // "loaded," so a paused session doesn't visually
                        // claim to be playing (2026-08-14 fix).
                        if isThisPlaylistAudiblyPlaying {
                            NowPlayingBarsView(color: DesignTokens.Color.onPrimary, maxHeight: 16)
                        } else if isThisPlaylistLoaded {
                            Image(systemName: "pause.fill")
                        } else {
                            Image(systemName: "play.fill")
                        }
                        Text(isThisPlaylistLoaded ? "Now Playing" : "Play")
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: DesignTokens.Size.buttonHeightStandard)
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignTokens.Color.primary)
                .foregroundStyle(DesignTokens.Color.onPrimary)
                .disabled(viewModel.rows.isEmpty)

                if let error = playbackEngine.playbackError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(DesignTokens.Color.error)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                } else if isThisPlaylistLoaded {
                    Text("Already playing — tap to return to Now Playing.")
                        .font(.caption)
                        .foregroundStyle(DesignTokens.Color.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Plays the whole set with real crossfade blending between tracks.")
                        .font(.caption)
                        .foregroundStyle(DesignTokens.Color.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, DesignTokens.Spacing.xs)
        }
        .padding(DesignTokens.Spacing.md)
    }

    // MARK: - Track list

    /// One track row plus (except for the last row) the teal/gray connector
    /// beneath it — folded into a single row now that this screen is a
    /// `List` rather than a `VStack` the connector could be threaded
    /// between as its own sibling view. `isLast` skips the connector for
    /// the final row (nothing to blend into); `isImminent` is true only for
    /// the very first transition, same rule as the previous layout.
    /// `isNowPlaying` mirrors the Queue screen's confirmed "now playing"
    /// treatment (tinted background, small play icon in place of the
    /// position number) now that `PlaybackEngine` can actually report which
    /// track is currently sounding.
    private func trackRow(_ row: PlaylistDetailRow, isLast: Bool, isImminent: Bool, isNowPlaying: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                if isNowPlaying {
                    // Real animated bars (2026-08-14), replacing a static
                    // "speaker.wave.2.fill" glyph — same reasoning as the
                    // header Play button above.
                    NowPlayingBarsView(color: DesignTokens.Color.primaryText, barWidth: 2.5, maxHeight: 12)
                        .frame(width: numberColumnWidth, alignment: .trailing)
                } else {
                    // `.lineLimit(1)` added 2026-08-14 -- a real bug: with no
                    // line limit, a 20pt-wide frame wasn't always quite wide
                    // enough for two-digit numbers at this font, so SwiftUI
                    // wrapped some of them onto two lines instead of keeping
                    // them on one ("25" rendering as "2" over "5"). Width is
                    // now `numberColumnWidth` (see that property's own doc
                    // comment) instead of a fixed guess -- both branches
                    // must stay the same width, or the row content shifts
                    // sideways depending on whether it's the now-playing row.
                    Text("\(row.position + 1)")
                        .font(.footnote)
                        .foregroundStyle(DesignTokens.Color.textSecondary)
                        .lineLimit(1)
                        .frame(width: numberColumnWidth, alignment: .trailing)
                }

                artworkTile(for: row)

                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                    Text(row.title)
                        .font(.body)
                        .foregroundStyle(DesignTokens.Color.textPrimary)
                        .lineLimit(1)
                    Text(row.artist)
                        .font(.footnote)
                        .foregroundStyle(DesignTokens.Color.textSecondary)
                        .lineLimit(1)
                }

                Spacer()

                Text(row.durationText)
                    .font(.footnote)
                    .foregroundStyle(DesignTokens.Color.textSecondary)

                Menu {
                    Button(role: .destructive) {
                        viewModel.removeTrack(row: row, playlist: playlist, store: store)
                    } label: {
                        Label("Remove from this mix", systemImage: "minus.circle")
                    }
                    // Blocked on the not-yet-built playback queue (per CLAUDE.md's
                    // Mixing Engine section) -- same "visible but disabled, not
                    // hidden" treatment `PlaylistOverflowSheet` already uses for
                    // Share/Play Next at the playlist level.
                    Button {} label: {
                        Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                    }
                    .disabled(true)
                } label: {
                    // **Real root cause found 2026-08-18, third attempt at
                    // this exact control.** The first fix added explicit
                    // circular chrome to match `MyMixesView`'s hand-coded
                    // background; a second (wrong) fix removed it entirely,
                    // misreading Andy's report as "no gray background
                    // anywhere." Andy corrected this precisely: My Mixes'
                    // single gray circle was always correct and was never
                    // the problem -- this `Menu`'s "..." has an *extra*
                    // gray layer *on top of* a circle matching that one,
                    // because a `Menu` with no explicit `.menuStyle` gets
                    // its own default interactive chrome from iOS
                    // automatically (the same class of "unstyled control
                    // picks up unwanted platform chrome" bug already fixed
                    // for the A-Z index rail and, this same round, Now
                    // Playing's transport buttons). `.buttonStyle(.plain)`
                    // has no effect on a `Menu` (it isn't a `Button`) --
                    // the correct suppressor is `.menuStyle
                    // (.borderlessButton)`, applied to the `Menu` itself
                    // below. With that in place, the explicit circle here
                    // is the *only* background rendered, matching My
                    // Mixes' exactly instead of stacking under it.
                    Image(systemName: "ellipsis")
                        .foregroundStyle(DesignTokens.Color.textSecondary)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(DesignTokens.Color.surfaceTint))
                        .frame(width: DesignTokens.Size.tapTargetMin, height: DesignTokens.Size.tapTargetMin)
                }
                .menuStyle(.borderlessButton)
            }
            .padding(.vertical, DesignTokens.Spacing.xxs)
            .padding(.horizontal, isNowPlaying ? DesignTokens.Spacing.xs : 0)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Size.cornerRadiusSmall)
                    .fill(isNowPlaying ? DesignTokens.Color.surfaceTint : Color.clear)
            )

            if !isLast {
                connector(isImminent: isImminent)
            }
        }
    }

    /// Real per-track thumbnail, added 2026-08-18 per Andy's confirmed
    /// request (see the standing `project_album_artwork_rollout` note) —
    /// same 36pt rounded-rect tile treatment `SongPickerView.artworkTile`
    /// already uses, with the same flat-icon fallback when a track has no
    /// artwork or isn't found in the library any more.
    @ViewBuilder
    private func artworkTile(for row: PlaylistDetailRow) -> some View {
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
                        .font(.footnote)
                        .foregroundStyle(DesignTokens.Color.primaryText)
                }
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Size.cornerRadiusSmall))
    }

    /// Solid teal for the first transition (the one that's imminent when
    /// playback is at or before the first track), lighter gray further out
    /// — same visual-blending signal as the confirmed Queue screen design.
    /// Still keyed to list position (`index == 0`) rather than tracking
    /// actual playback position once a mix is partway through — the
    /// now-playing highlight (`isNowPlaying`) shows *where* playback is,
    /// this connector doesn't yet shift to show which transition is
    /// imminent *from* there. Flagged as a judgment call, not an explicit
    /// CLAUDE.md spec for this screen.
    private func connector(isImminent: Bool) -> some View {
        Rectangle()
            .fill(isImminent ? DesignTokens.Color.primary : DesignTokens.Color.border)
            .frame(width: 2, height: DesignTokens.Spacing.md)
            // **Fixed 2026-08-19** -- was a hardcoded `26`, a stale leftover
            // from before `numberColumnWidth` became dynamic (see that
            // property's own doc comment). Left unupdated at the time, this
            // has been slightly misaligned for every playlist whose number
            // column isn't exactly 26pt wide (i.e. almost all of them) --
            // caught during an unrelated self-review pass, not reported.
            .padding(.leading, numberColumnWidth + DesignTokens.Spacing.sm)
    }

    // MARK: - Footer

    private var footer: some View {
        Text(viewModel.footerText)
            .font(.caption)
            .foregroundStyle(DesignTokens.Color.textSecondary)
            .padding(.top, DesignTokens.Spacing.sm)
    }
}

#Preview {
    NavigationStack {
        PlaylistDetailView(
            playlist: Playlist(name: "Smooth Jazz Seamless Mix", mode: .energyWave),
            store: PlaylistStore()
        )
    }
    .environmentObject(PlaybackEngine())
}
