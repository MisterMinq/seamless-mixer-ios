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
/// - **Play is real now, for the first track only.** `PlaybackEngine` (new
///   this slice) is the first real implementation of CLAUDE.md's "Mixing
///   Engine — AVAudioEngine Design" — but only its single-track-playback
///   slice: tapping Play plays the playlist's first track start to finish,
///   with no crossfade and no automatic advance to track 2. The caption
///   underneath says so plainly, per Rule 3's "don't pretend it works"
///   spirit — a saved playlist is a correctly-sequenced recipe that can now
///   partially, not fully, be heard. Full sequential/crossfaded playback is
///   the next slice.
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
    @StateObject private var playbackEngine = PlaybackEngine()
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
                        trackRow(row, isLast: index == viewModel.rows.count - 1, isImminent: index == 0)
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
                    if playbackEngine.isPlaying {
                        playbackEngine.stop()
                    } else if let first = viewModel.rows.first {
                        playbackEngine.play(trackPersistentID: first.trackPersistentID)
                    }
                } label: {
                    Label(playbackEngine.isPlaying ? "Stop" : "Play", systemImage: playbackEngine.isPlaying ? "stop.fill" : "play.fill")
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
                } else {
                    Text("Plays the first track only for now — full sequential, crossfaded playback through the whole mix is next.")
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
    private func trackRow(_ row: PlaylistDetailRow, isLast: Bool, isImminent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Text("\(row.position + 1)")
                    .font(.footnote)
                    .foregroundStyle(DesignTokens.Color.textSecondary)
                    .frame(width: 20, alignment: .trailing)

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

            if !isLast {
                connector(isImminent: isImminent)
            }
        }
    }

    /// Solid teal for the first transition (the one that would be imminent
    /// the moment Play is tapped), lighter gray further out — same
    /// visual-blending signal as the confirmed Queue screen design, adapted
    /// here since Playlist Detail has no "now playing" row of its own yet
    /// (playback hasn't started). Flagged as a judgment call, not an
    /// explicit CLAUDE.md spec for this screen's pre-playback state.
    private func connector(isImminent: Bool) -> some View {
        Rectangle()
            .fill(isImminent ? DesignTokens.Color.primary : DesignTokens.Color.border)
            .frame(width: 2, height: DesignTokens.Spacing.md)
            .padding(.leading, 20 + DesignTokens.Spacing.sm)
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
}
