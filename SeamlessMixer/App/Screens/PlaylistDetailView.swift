import SwiftUI
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
///   is active — that needs Andy's real-device check. Header/footer live in
///   their own non-reorderable `Section`s with hidden separators/
///   transparent backgrounds so they blend into the `List` the same way
///   they looked in the old `ScrollView`+`VStack` layout; the teal/gray
///   connector line moved from a separate view *between* rows into the
///   bottom of each row itself, since `List` rows don't have a clean way to
///   render a shared element spanning two adjacent rows. Adding a track to
///   an already-built playlist (short of a full Refresh) is still not
///   implemented — see CLAUDE.md's Rule 8 gap list.
struct PlaylistDetailView: View {
    let playlist: Playlist
    let store: PlaylistStore

    @StateObject private var viewModel = PlaylistDetailViewModel()
    @EnvironmentObject private var playbackEngine: PlaybackEngine
    @State private var showNowPlaying = false
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

    init(playlist: Playlist, store: PlaylistStore) {
        self.playlist = playlist
        self.store = store
        _isFavorite = State(initialValue: playlist.isFavorite)
        _displayName = State(initialValue: playlist.name)
    }

    var body: some View {
        List {
            // Header/loading/empty states each get their own `Section` with
            // hidden separators and a clear row background so they blend
            // into the `List` the same way they read in the old
            // `ScrollView`+`VStack` layout, rather than looking like list
            // rows themselves.
            Section {
                header
            }
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            if viewModel.isLoading {
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, DesignTokens.Spacing.xl)
                }
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            } else if viewModel.rows.isEmpty {
                Section {
                    Text("This playlist has no tracks yet.")
                        .font(.body)
                        .foregroundStyle(DesignTokens.Color.textSecondary)
                        .padding(.horizontal, DesignTokens.Spacing.md)
                }
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            } else {
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
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(DesignTokens.Color.background)
        .navigationTitle(displayName)
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
    }

    // MARK: - Header

    /// `.padding(...)` moved here from the old screen-level `ScrollView`
    /// padding — the `List`'s header `Section` now uses zero `listRowInsets`
    /// (so the artwork tile can stretch edge-to-edge like it always could),
    /// which means header content that *should* stay inset needs its own
    /// padding instead of inheriting it from a shared container.
    private var header: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            RoundedRectangle(cornerRadius: DesignTokens.Size.cornerRadiusArtwork)
                .fill(DesignTokens.Color.surfaceTint)
                .frame(maxWidth: .infinity)
                .frame(height: 220)
                .overlay(
                    Image(systemName: "music.note.list")
                        .font(.system(size: DesignTokens.Size.iconLarge))
                        .foregroundStyle(DesignTokens.Color.primaryText)
                )

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
                        .frame(width: 26, alignment: .trailing)
                } else {
                    // `.lineLimit(1)` added 2026-08-14 -- a real bug: with no
                    // line limit, a 20pt-wide frame wasn't always quite wide
                    // enough for two-digit numbers at this font, so SwiftUI
                    // wrapped some of them onto two lines instead of keeping
                    // them on one ("25" rendering as "2" over "5"). Widened
                    // this frame to 26pt to match -- both branches must stay
                    // the same width, or the row content shifts sideways
                    // depending on whether it's the now-playing row.
                    Text("\(row.position + 1)")
                        .font(.footnote)
                        .foregroundStyle(DesignTokens.Color.textSecondary)
                        .lineLimit(1)
                        .frame(width: 26, alignment: .trailing)
                }

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
                    Image(systemName: "ellipsis")
                        .foregroundStyle(DesignTokens.Color.textSecondary)
                        .frame(width: DesignTokens.Size.tapTargetMin, height: DesignTokens.Size.tapTargetMin)
                }
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
            .padding(.leading, 26 + DesignTokens.Spacing.sm)
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
