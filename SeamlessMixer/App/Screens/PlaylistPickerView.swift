import SwiftUI
import UIKit
import MediaPlayer
import PlaylistCore

/// Second of the four (now five, see below) category pickers (Screen 2),
/// per the confirmed Source Selection design: "grid-style rows with square
/// collage/artwork thumbnails, same as Apple's own Playlists screen,
/// checkbox added. No A-Z rail — Andy's own library only has a handful of
/// playlists, and playlists are usually recognized by cover/name at a
/// glance rather than looked up alphabetically."
///
/// **Merged with native `CustomPlaylist`s, 2026-09-07 (Batch 2), per the
/// confirmed "Add to Playlist" design.** This grid used to show only real
/// Apple Music playlists; it now also shows the app's own native playlists
/// (created via "New Playlist," or copied from an Apple Music playlist the
/// moment it's opened to edit — see `PlaylistStore.copyAppleMusicPlaylist`).
/// A native copy **replaces** the plain Apple Music row it was copied from
/// (same name, a small "SM" badge added) rather than the two coexisting as
/// confusing near-duplicates — Andy's own confirmed resolution for the
/// "which one do I pick" risk once a playlist has genuinely diverged from
/// its Apple Music original. A playlist created fresh (no Apple origin) has
/// no plain row to replace, so it just appears as its own badged cell.
///
/// **Two separate affordances per cell, not one**: tapping the cell body
/// (as before) toggles it as a Build Mix *source*, exactly like every other
/// category picker. A small pencil-in-circle overlay (bottom-leading, clear
/// of the existing selection checkmark at top-trailing) opens that
/// playlist's songs for viewing/editing — for a plain, not-yet-copied Apple
/// Music row, tapping it performs copy-on-edit first (there's no write API
/// to a real Apple Music playlist's membership, so editing one always means
/// editing an independent native copy from that point on).
///
/// **New "..." toolbar menu, same round**: "New Playlist" — per the
/// confirmed design, folded into this screen's own overflow menu rather
/// than a separate "+" icon ("Make the path shorter... I am ok to try that
/// folded architecture").
struct PlaylistPickerView: View {
    @ObservedObject var viewModel: SourceSelectionViewModel
    let store: PlaylistStore

    @State private var applePlaylists: [PlaylistRow] = []
    @State private var customPlaylistSongCounts: [Int64: Int] = [:]
    /// **Added 2026-08-15** — see `GenrePickerView`'s own note on why this
    /// is separate from the Hub's global search.
    @State private var searchText = ""

    @State private var showNewPlaylist = false
    @State private var editingCustomPlaylistID: Int64?

    struct PlaylistRow: Identifiable {
        let persistentID: MPMediaEntityPersistentID
        let name: String
        let songCount: Int
        let artwork: UIImage?
        var id: MPMediaEntityPersistentID { persistentID }
    }

    /// One row in the merged grid — either a plain, not-yet-copied Apple
    /// Music playlist, or a native `CustomPlaylist` (copied or created
    /// fresh). See this file's own doc comment for the merge rule.
    private enum MergedRow: Identifiable {
        case apple(PlaylistRow)
        case custom(CustomPlaylist, songCount: Int)

        var id: String {
            switch self {
            case .apple(let row): return "apple:\(row.persistentID)"
            case .custom(let playlist, _): return "custom:\(playlist.id ?? 0)"
            }
        }

        var name: String {
            switch self {
            case .apple(let row): return row.name
            case .custom(let playlist, _): return playlist.name
            }
        }

        var songCount: Int {
            switch self {
            case .apple(let row): return row.songCount
            case .custom(_, let count): return count
            }
        }

        var artwork: UIImage? {
            switch self {
            case .apple(let row): return row.artwork
            // Real per-song artwork for a native playlist isn't built this
            // round -- flagged, not silently missing -- a merged row shows
            // the flat placeholder tile until a future pass resolves it the
            // same way `PlaylistStore.loadCollages` already does for Seamless
            // Mixes.
            case .custom: return nil
            }
        }

        var isNative: Bool {
            if case .custom = self { return true }
            return false
        }
    }

    private var mergedRows: [MergedRow] {
        var customByOrigin: [MPMediaEntityPersistentID: CustomPlaylist] = [:]
        var standaloneCustom: [CustomPlaylist] = []
        for custom in viewModel.customPlaylists {
            if let origin = custom.originApplePlaylistPersistentID {
                customByOrigin[origin] = custom
            } else {
                standaloneCustom.append(custom)
            }
        }

        var rows: [MergedRow] = applePlaylists.map { apple in
            if let custom = customByOrigin[apple.persistentID] {
                return .custom(custom, songCount: customPlaylistSongCounts[custom.id ?? -1] ?? apple.songCount)
            }
            return .apple(apple)
        }
        for custom in standaloneCustom {
            rows.append(.custom(custom, songCount: customPlaylistSongCounts[custom.id ?? -1] ?? 0))
        }
        return rows
    }

    private let columns = [GridItem(.adaptive(minimum: 140), spacing: DesignTokens.Spacing.sm)]

    private var filteredRows: [MergedRow] {
        guard !searchText.isEmpty else { return mergedRows }
        return mergedRows.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        // Plain, embedded field, not `.searchable()` -- see
        // `InlineSearchField`'s own doc comment for why.
        VStack(spacing: 0) {
            InlineSearchField(text: $searchText, prompt: "Search playlists")
            ScrollView {
                LazyVGrid(columns: columns, spacing: DesignTokens.Spacing.md) {
                    ForEach(filteredRows) { row in
                        cell(for: row)
                    }
                }
                .padding(DesignTokens.Spacing.md)
            }
        }
        .background(DesignTokens.Color.background)
        .navigationTitle("Playlists")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
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
        .navigationDestination(isPresented: $showNewPlaylist) {
            NewPlaylistView(store: store) { _ in
                viewModel.refreshCustomPlaylists()
                showNewPlaylist = false
            }
        }
        .navigationDestination(item: $editingCustomPlaylistID) { customPlaylistID in
            CustomPlaylistDetailView(customPlaylistID: customPlaylistID, store: store)
                .onDisappear {
                    // Covers a rename (name shown on this grid's cell) and a
                    // delete (the row needs to vanish from the merged grid
                    // entirely) that could have happened on that screen,
                    // neither of which this picker would otherwise know
                    // about — it never observes `store` directly.
                    viewModel.refreshCustomPlaylists()
                    loadCustomPlaylistSongCounts()
                }
        }
        .onAppear {
            loadPlaylists()
            viewModel.refreshCustomPlaylists()
            loadCustomPlaylistSongCounts()
        }
    }

    private func cell(for row: MergedRow) -> some View {
        let source: SelectedSource
        switch row {
        case .apple(let apple):
            source = SelectedSource(id: "playlist:\(apple.persistentID)", type: .playlist, label: apple.name, persistentID: apple.persistentID)
        case .custom(let custom, _):
            // Bit-cast the `CustomPlaylist`'s own `Int64` row id into the
            // same `persistentID` field a real Apple Music source uses --
            // see `SourceType.customPlaylist`'s own doc comment.
            let bitCastID = MPMediaEntityPersistentID(bitPattern: custom.id ?? 0)
            source = SelectedSource(id: "customPlaylist:\(bitCastID)", type: .customPlaylist, label: custom.name, persistentID: bitCastID)
        }
        let selected = viewModel.isSelected(source)

        return ZStack(alignment: .bottomLeading) {
            Button {
                viewModel.toggle(source)
            } label: {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                    ZStack(alignment: .topTrailing) {
                        artworkTile(for: row)
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(selected ? DesignTokens.Color.primary : .white)
                            .padding(4)
                            .background(Circle().fill(Color.black.opacity(0.35)))
                            .padding(DesignTokens.Spacing.xxs)
                    }
                    HStack(spacing: 4) {
                        Text(row.name)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(DesignTokens.Color.textPrimary)
                            .lineLimit(1)
                        if row.isNative {
                            smBadge
                        }
                    }
                    // Same "N songs" caption every category picker keeps, per
                    // the confirmed design's row-consistency note.
                    Text("\(row.songCount) songs")
                        .font(.caption)
                        .foregroundStyle(DesignTokens.Color.textSecondary)
                }
            }
            .buttonStyle(.plain)

            // Opens this playlist's songs for viewing/editing -- separate
            // from the cell's own selection tap above, per this file's own
            // doc comment.
            editButton(for: row)
                .padding(DesignTokens.Spacing.xxs)
        }
    }

    /// "SM" badge — the confirmed design's chosen differentiator for a
    /// native (app-created or app-edited) playlist vs. an unedited Apple
    /// Music one, per Andy's own suggestion.
    private var smBadge: some View {
        Text("SM")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(DesignTokens.Color.onPrimary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Capsule().fill(DesignTokens.Color.primary))
    }

    private func editButton(for row: MergedRow) -> some View {
        Button {
            beginEditing(row)
        } label: {
            Image(systemName: "pencil.circle.fill")
                .font(.title3)
                .foregroundStyle(.white, Color.black.opacity(0.45))
        }
        .buttonStyle(.plain)
    }

    /// A `.custom` row already has a real `CustomPlaylist` id to push to
    /// directly. A `.apple` row has never been edited before -- copy-on-edit
    /// runs first (`PlaylistStore.copyAppleMusicPlaylist`), creating (or, if
    /// this exact playlist was already copied in an earlier session,
    /// re-finding) the native copy, before pushing to it.
    private func beginEditing(_ row: MergedRow) {
        switch row {
        case .custom(let custom, _):
            editingCustomPlaylistID = custom.id
        case .apple(let apple):
            guard let matchingPlaylist = MPMediaQuery.playlists().collections?
                .first(where: { $0.persistentID == apple.persistentID }) as? MPMediaPlaylist,
                let copy = store.copyAppleMusicPlaylist(matchingPlaylist)
            else { return }
            viewModel.refreshCustomPlaylists()
            migrateSelectionIfNeeded(from: apple, to: copy)
            editingCustomPlaylistID = copy.id
        }
    }

    /// If the plain Apple Music playlist being edited was already picked as
    /// a Build Mix source, its selection needs to move to the new native
    /// copy that just replaced it in this grid — otherwise the old, now-
    /// orphaned `.playlist` source would silently linger in the Hub's chip
    /// row while the merged cell it used to represent shows as unselected,
    /// a real (if minor) inconsistency copy-on-edit would otherwise
    /// introduce. A no-op when the edited row wasn't selected to begin with.
    private func migrateSelectionIfNeeded(from apple: PlaylistRow, to copy: CustomPlaylist) {
        let oldSource = SelectedSource(id: "playlist:\(apple.persistentID)", type: .playlist, label: apple.name, persistentID: apple.persistentID)
        guard viewModel.isSelected(oldSource) else { return }
        viewModel.toggle(oldSource) // deselect the now-superseded Apple row
        let bitCastID = MPMediaEntityPersistentID(bitPattern: copy.id ?? 0)
        let newSource = SelectedSource(id: "customPlaylist:\(bitCastID)", type: .customPlaylist, label: copy.name, persistentID: bitCastID)
        viewModel.toggle(newSource) // select the native copy in its place
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

    private func loadPlaylists() {
        let collections = MPMediaQuery.playlists().collections ?? []
        applePlaylists = collections
            .compactMap { collection -> PlaylistRow? in
                guard let playlist = collection as? MPMediaPlaylist else { return nil }
                let name = playlist.name ?? "Untitled Playlist"
                // Downscaled to the grid cell's rough on-screen size rather
                // than requesting the artwork's full native resolution, per
                // the design tokens' "downscaled first for speed" guidance
                // for artwork-derived work elsewhere in the app.
                let artworkImage = playlist.representativeItem?.artwork?.image(at: CGSize(width: 140, height: 140))
                return PlaylistRow(
                    persistentID: playlist.persistentID,
                    name: name,
                    songCount: playlist.items.count,
                    artwork: artworkImage
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Best-effort, same "a missing count isn't worth blocking the screen
    /// over" posture `PlaylistStore.loadCollages` already established --
    /// falls back to the origin Apple Music playlist's own song count (set
    /// in `mergedRows` above) or 0 rather than surfacing a separate error.
    private func loadCustomPlaylistSongCounts() {
        guard let db = store.db else { return }
        var counts: [Int64: Int] = [:]
        for playlist in viewModel.customPlaylists {
            guard let id = playlist.id else { continue }
            // `try?` on a throwing function that itself returns an Optional
            // flattens to one level (SE-0230) -- a single `?` here, not a
            // double one, per this project's own hard-earned lesson on this
            // exact mistake (see `SourceSelectionViewModel.loadFavoriteSongsCount`'s
            // history).
            counts[id] = (try? db.loadCustomPlaylistDetail(customPlaylistID: id))?.tracks.count ?? 0
        }
        customPlaylistSongCounts = counts
    }
}
