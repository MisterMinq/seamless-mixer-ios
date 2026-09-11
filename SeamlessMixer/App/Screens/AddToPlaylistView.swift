import SwiftUI
import UIKit
import MediaPlayer
import PlaylistCore

/// Batch 3 of the confirmed "Add to Playlist" design (CLAUDE.md 0.25.68) —
/// the actual "pick a destination and add the currently playing song" flow,
/// reached from Now Playing's "..." → "Add to Playlist." Confirmed flow,
/// Andy's own words: "A song is playing -> tap the 3 dots at the top and
/// select Add to Playlist -> Playlist screen in SelectionHub comes up ->
/// select a Playlist or tap [New Playlist in] the ellipsis -> New Playlist
/// screen appears -> enter a name and press Done -> song is added
/// automatically to the newly created playlist, all whilst the music is
/// still playing -> land back on Now Playing."
///
/// **A new, purpose-built screen rather than reusing `PlaylistPickerView`
/// directly.** That screen is deeply tied to Source Selection's Build-Mix-
/// selection state (`SourceSelectionViewModel`'s `selectedSources`/mode/
/// chip row/etc., none of which applies here — there's no Build Mix
/// happening, just "add one song to one playlist"), and threading a second
/// "destination mode" through an already-substantial screen risked more
/// than building a smaller, self-contained one. Visually mirrors it closely
/// on purpose though — same merged Apple + native grid, same "SM" badge,
/// same copy-on-edit rule for an unedited Apple Music row, same "..." →
/// New Playlist menu, same first-track-artwork resolution for a native
/// playlist's cover (**ported over 2026-09-09** — this screen was built the
/// round before `PlaylistPickerView` gained that fix and never picked it
/// up, a real, confirmed gap Andy's own screenshot caught, not a design
/// choice) — so it reads as "the same Playlists screen," matching
/// the confirmed flow's own description, just without the checkbox-
/// selection/edit-pencil affordances that only make sense when picking
/// Build Mix sources.
///
/// Presented as its own sheet from `NowPlayingView`, with its own
/// `NavigationStack` inside (so "New Playlist" can push within it while
/// still respecting `NewPlaylistView`'s own "no back arrow" design).
struct AddToPlaylistView: View {
    let trackPersistentID: Int64
    let store: PlaylistStore
    /// Called once the song has actually landed somewhere (an existing
    /// playlist, or a brand-new one just created) — the caller
    /// (`NowPlayingView`) flips its own `@State` presentation flag to close
    /// this whole flow. A plain `@Environment(\.dismiss)` from deep inside
    /// this screen's own nested push (New Playlist can be pushed a level
    /// in) would only pop that one level, not close the sheet itself — this
    /// sidesteps that by letting the presenter own the single source of
    /// truth for "is this flow still open," the same pattern
    /// `PlaylistPickerView`'s own local `showNewPlaylist` flag already uses.
    let onDone: () -> Void

    @State private var applePlaylists: [PlaylistRow] = []
    @State private var customPlaylists: [CustomPlaylist] = []
    @State private var customSongCounts: [Int64: Int] = [:]
    /// **Added 2026-09-09, Testing (68)** — this screen's own `MergedRow
    /// .artwork` always returned `nil` for a `.custom` row, unlike
    /// `PlaylistPickerView`'s equivalent (fixed back at 2026-09-08, per
    /// Andy's own suggestion to use a native playlist's first song's real
    /// artwork) — this screen was built the round *before* that fix, as its
    /// own separate, self-contained type (see this file's own top-of-file
    /// doc comment for why), and never picked it up. Andy's screenshot of
    /// this exact screen — every native playlist showing the flat
    /// placeholder, including a real, 242-song one — confirmed it directly.
    /// Same fix, same reasoning, ported over rather than duplicated blind.
    @State private var customArtwork: [Int64: UIImage] = [:]
    @State private var showNewPlaylist = false
    @State private var errorMessage: String?

    struct PlaylistRow: Identifiable {
        let persistentID: MPMediaEntityPersistentID
        let name: String
        let songCount: Int
        let artwork: UIImage?
        var id: MPMediaEntityPersistentID { persistentID }
    }

    /// Same `.apple`/`.custom` merge shape as `PlaylistPickerView.MergedRow`
    /// — deliberately a separate, local type rather than reaching into that
    /// view's own `private` one, keeping this screen self-contained.
    private enum MergedRow: Identifiable {
        case apple(PlaylistRow)
        case custom(CustomPlaylist, songCount: Int, artwork: UIImage?)

        var id: String {
            switch self {
            case .apple(let row): return "apple:\(row.persistentID)"
            case .custom(let playlist, _, _): return "custom:\(playlist.id ?? 0)"
            }
        }
        var name: String {
            switch self {
            case .apple(let row): return row.name
            case .custom(let playlist, _, _): return playlist.name
            }
        }
        var songCount: Int {
            switch self {
            case .apple(let row): return row.songCount
            case .custom(_, let count, _): return count
            }
        }
        var artwork: UIImage? {
            switch self {
            case .apple(let row): return row.artwork
            case .custom(_, _, let artwork): return artwork
            }
        }
        var isNative: Bool {
            if case .custom = self { return true }
            return false
        }
    }

    /// **Aligned with `PlaylistPickerView.mergedRows` 2026-09-11 (Testing
    /// 74), two real bugs fixed together, not one:** this screen was built
    /// a round before `PlaylistPickerView`'s 2026-09-10 "show both, don't
    /// replace" revision and never picked it up (the same "built the round
    /// before, never ported over" gap already flagged once for artwork on
    /// this file's own top-of-file doc comment) — it was still *replacing*
    /// an edited Apple Music playlist's row with its "SM" copy instead of
    /// showing both, so a song couldn't be added to the original from here
    /// once it had ever been edited. Separately, an origin-linked copy
    /// whose Apple Music playlist has since been deleted used to vanish
    /// from this grid entirely (it was only ever emitted alongside its
    /// matching Apple row) — real data with no way to reach it. Both fixed
    /// the same way `PlaylistPickerView` now is: the Apple row is always
    /// kept, a matched copy is added right after it (not instead), and any
    /// origin-linked copy that no longer matches a live Apple row folds
    /// into the standalone group instead of disappearing.
    private var mergedRows: [MergedRow] {
        var customByOrigin: [MPMediaEntityPersistentID: CustomPlaylist] = [:]
        var standaloneCustom: [CustomPlaylist] = []
        for custom in customPlaylists {
            if let origin = custom.originApplePlaylistPersistentID {
                customByOrigin[origin] = custom
            } else {
                standaloneCustom.append(custom)
            }
        }

        var rows: [MergedRow] = []
        var matchedOrigins: Set<MPMediaEntityPersistentID> = []
        for apple in applePlaylists {
            rows.append(.apple(apple))
            if let custom = customByOrigin[apple.persistentID] {
                rows.append(customRow(for: custom))
                matchedOrigins.insert(apple.persistentID)
            }
        }
        let orphanedOriginCustoms = customByOrigin
            .filter { !matchedOrigins.contains($0.key) }
            .map(\.value)
        for custom in standaloneCustom + orphanedOriginCustoms {
            rows.append(customRow(for: custom))
        }
        return rows
    }

    private func customRow(for custom: CustomPlaylist) -> MergedRow {
        .custom(
            custom,
            songCount: customSongCounts[custom.id ?? -1] ?? 0,
            artwork: customArtwork[custom.id ?? -1]
        )
    }

    private let columns = [GridItem(.adaptive(minimum: 140), spacing: DesignTokens.Spacing.sm)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(DesignTokens.Color.error)
                        .padding(DesignTokens.Spacing.md)
                }
                if mergedRows.isEmpty {
                    Text("No playlists yet — tap \u{201c}…\u{201d} above to create one.")
                        .font(.footnote)
                        .foregroundStyle(DesignTokens.Color.textSecondary)
                        .padding(DesignTokens.Spacing.lg)
                } else {
                    LazyVGrid(columns: columns, spacing: DesignTokens.Spacing.md) {
                        ForEach(mergedRows) { row in
                            cell(for: row)
                        }
                    }
                    .padding(DesignTokens.Spacing.md)
                }
            }
            .background(DesignTokens.Color.background)
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onDone)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button("New Playlist", systemImage: "plus") {
                            showNewPlaylist = true
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .foregroundStyle(DesignTokens.Color.textSecondary)
                            .padding(8)
                            .background(Circle().fill(DesignTokens.Color.surfaceTint))
                    }
                    .menuStyle(.borderlessButton)
                }
            }
            // No back arrow inside `NewPlaylistView` per its own confirmed
            // design; its `onCreated` here both adds the song AND (via
            // `addSong`'s own call to `onDone()`) closes this whole flow —
            // the "land back on Now Playing" half of the confirmed flow,
            // deliberately left unwired by `NewPlaylistView`'s own doc
            // comment until this exact call site existed.
            .navigationDestination(isPresented: $showNewPlaylist) {
                NewPlaylistView(store: store) { created in
                    addSong(toCustomPlaylistID: created.id)
                }
            }
            .onAppear(perform: load)
        }
    }

    private func cell(for row: MergedRow) -> some View {
        Button {
            addSong(to: row)
        } label: {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                artworkTile(for: row)
                HStack(spacing: 4) {
                    Text(row.name)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(DesignTokens.Color.textPrimary)
                        .lineLimit(1)
                    if row.isNative { smBadge }
                }
                Text("\(row.songCount) songs")
                    .font(.caption)
                    .foregroundStyle(DesignTokens.Color.textSecondary)
            }
        }
        .buttonStyle(.plain)
    }

    /// Same confirmed "SM" badge as `PlaylistPickerView`'s own — see that
    /// file's doc comment for the full reasoning.
    private var smBadge: some View {
        Text("SM")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(DesignTokens.Color.onPrimary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Capsule().fill(DesignTokens.Color.primary))
    }

    @ViewBuilder
    private func artworkTile(for row: MergedRow) -> some View {
        RoundedRectangle(cornerRadius: DesignTokens.Size.cornerRadiusMedium)
            .fill(DesignTokens.Color.surfaceTint)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let artwork = row.artwork {
                    Image(uiImage: artwork)
                        .resizable()
                        .scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Size.cornerRadiusMedium))
                } else {
                    Image(systemName: "music.note.list")
                        .foregroundStyle(DesignTokens.Color.primaryText)
                }
            }
            .clipped()
    }

    private func load() {
        let collections = MPMediaQuery.playlists().collections ?? []
        applePlaylists = collections
            .compactMap { collection -> PlaylistRow? in
                guard let playlist = collection as? MPMediaPlaylist else { return nil }
                let name = playlist.name ?? "Untitled Playlist"
                let artworkImage = playlist.representativeItem?.artwork?.image(at: CGSize(width: 140, height: 140))
                return PlaylistRow(persistentID: playlist.persistentID, name: name, songCount: playlist.items.count, artwork: artworkImage)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        guard let db = store.db else { return }
        customPlaylists = (try? db.loadCustomPlaylists()) ?? []
        var counts: [Int64: Int] = [:]
        var firstTrackIDs: [Int64: Int64] = [:]
        for playlist in customPlaylists {
            guard let id = playlist.id else { continue }
            let detail = try? db.loadCustomPlaylistDetail(customPlaylistID: id)
            counts[id] = detail?.tracks.count ?? 0
            if let firstTrackID = detail?.tracks.first?.track.persistentID {
                firstTrackIDs[id] = firstTrackID
            }
        }
        customSongCounts = counts
        // **Batched into one artwork pass, 2026-09-11 (Testing 74)** — see
        // `PlaylistPickerView.loadCustomPlaylistSongCounts`'s own doc
        // comment for the full diagnosis. This screen had the identical
        // per-playlist full-library-scan pattern, and sits right behind Now
        // Playing's "..." menu — the leading cause of Andy's report that
        // Now Playing's "..." glitches after visiting this sheet.
        let resolvedByTrack = ArtworkResolver.loadArtwork(forTrackPersistentIDs: Array(firstTrackIDs.values), size: CGSize(width: 140, height: 140))
        customArtwork = firstTrackIDs.compactMapValues { resolvedByTrack[$0] }
    }

    /// A `.custom` row already has a real `CustomPlaylist` id to add
    /// straight into. A `.apple` row has never been edited before — copy-
    /// on-edit runs first (`PlaylistStore.copyAppleMusicPlaylist`, same
    /// idempotent "re-find the existing copy if one already exists"
    /// behavior `PlaylistPickerView` already relies on), since there's no
    /// write API to a real Apple Music playlist's own membership.
    private func addSong(to row: MergedRow) {
        switch row {
        case .custom(let custom, _, _):
            addSong(toCustomPlaylistID: custom.id)
        case .apple(let apple):
            guard let matchingPlaylist = MPMediaQuery.playlists().collections?
                .first(where: { $0.persistentID == apple.persistentID }) as? MPMediaPlaylist,
                let copy = store.copyAppleMusicPlaylist(matchingPlaylist)
            else {
                errorMessage = "Couldn't open that playlist to add this song."
                return
            }
            addSong(toCustomPlaylistID: copy.id)
        }
    }

    private func addSong(toCustomPlaylistID customPlaylistID: Int64?) {
        guard let customPlaylistID else {
            errorMessage = "Couldn't add this song — the playlist wasn't saved correctly."
            return
        }
        store.addToCustomPlaylist(trackPersistentID: trackPersistentID, customPlaylistID: customPlaylistID)
        onDone()
    }
}
