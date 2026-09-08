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
/// (created via "New Playlist," or copied from an Apple Music playlist —
/// see `PlaylistStore.copyAppleMusicPlaylist`). A native copy **replaces**
/// the plain Apple Music row it was copied from (same name, a small "SM"
/// badge added) rather than the two coexisting as confusing near-duplicates
/// — Andy's own confirmed resolution for the "which one do I pick" risk
/// once a playlist has genuinely diverged from its Apple Music original. A
/// playlist created fresh (no Apple origin) has no plain row to replace, so
/// it just appears as its own badged cell.
///
/// **Two separate affordances per cell, not one**: tapping the cell body
/// (artwork + name) toggles it as a Build Mix *source*, exactly like every
/// other category picker. A pencil below, on the trailing side of the "N
/// songs" row, opens that playlist's songs.
///
/// **Copy-on-edit no longer runs from here, as of 2026-09-08 (Testing 67) —
/// a real bug fix, see `CustomPlaylistDetailView`'s own top-of-file doc
/// comment for the full diagnosis.** Tapping the pencil on a plain Apple
/// Music row used to copy it immediately, before any actual edit happened —
/// Andy confirmed directly that just opening every playlist "to test it"
/// silently badged and de-arted all of them. `beginEditing` now only picks
/// which `CustomPlaylistDetailView.Target` to show; the real copy happens
/// lazily, inside that screen, the first time a genuine edit (Rename,
/// Remove) is actually attempted — `migrateSelectionIfNeeded` moved
/// alongside it, called via `onCopyCreated` instead of eagerly here.
///
/// **New "..." toolbar menu, 2026-09-07**: "New Playlist" — per the
/// confirmed design, folded into this screen's own overflow menu rather
/// than a separate "+" icon ("Make the path shorter... I am ok to try that
/// folded architecture").
struct PlaylistPickerView: View {
    @ObservedObject var viewModel: SourceSelectionViewModel
    let store: PlaylistStore

    @State private var applePlaylists: [PlaylistRow] = []
    @State private var customPlaylistSongCounts: [Int64: Int] = [:]
    /// **Added 2026-09-08** — a native/copied playlist has no cover of its
    /// own (`MergedRow.artwork` used to return `nil` unconditionally for
    /// every `.custom` row, flagged in an earlier round as "not built this
    /// round"). Real-device testing showed this reading as a genuine loss,
    /// not a placeholder — Andy: "Just because I clicked on the pencil of
    /// an Apple Playlist - Album cover disappears. The same is for New
    /// Playlist. Maybe just choose the album of the 1st song added to a new
    /// Playlist?" That's exactly what this does — the real artwork of
    /// whichever song currently sits at position 0, resolved alongside the
    /// song counts below (same pass, no extra query).
    @State private var customPlaylistArtwork: [Int64: UIImage] = [:]
    /// **Added 2026-08-15** — see `GenrePickerView`'s own note on why this
    /// is separate from the Hub's global search.
    @State private var searchText = ""

    @State private var showNewPlaylist = false
    @State private var editTarget: CustomPlaylistDetailView.Target?

    struct PlaylistRow: Identifiable {
        let persistentID: MPMediaEntityPersistentID
        let name: String
        let songCount: Int
        let artwork: UIImage?
        var id: MPMediaEntityPersistentID { persistentID }
    }

    /// One row in the merged grid — either a plain Apple Music playlist
    /// (real artwork, no badge, no native counterpart yet — read-only until
    /// actually edited), or a native `CustomPlaylist` (copied or created
    /// fresh). See this file's own doc comment for the merge rule.
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
                return .custom(
                    custom,
                    songCount: customPlaylistSongCounts[custom.id ?? -1] ?? apple.songCount,
                    artwork: customPlaylistArtwork[custom.id ?? -1]
                )
            }
            return .apple(apple)
        }
        for custom in standaloneCustom {
            rows.append(.custom(
                custom,
                songCount: customPlaylistSongCounts[custom.id ?? -1] ?? 0,
                artwork: customPlaylistArtwork[custom.id ?? -1]
            ))
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
        .navigationDestination(item: $editTarget) { target in
            CustomPlaylistDetailView(target: target, store: store) { copiedPlaylist in
                // Only ever called for a target that started as
                // `.appleOrigin` and just got copied for real, inside that
                // screen, on its first genuine edit — see
                // `CustomPlaylistDetailView`'s own doc comment.
                viewModel.refreshCustomPlaylists()
                if case .appleOrigin(let persistentID) = target {
                    migrateSelectionIfNeeded(fromApplePersistentID: persistentID, to: copiedPlaylist)
                }
            }
            .onDisappear {
                // Covers a rename (name shown on this grid's cell), a
                // delete (the row needs to vanish from the merged grid
                // entirely), or a first-ever edit just having created a new
                // native copy — none of which this picker would otherwise
                // know about, since it never observes `store` directly.
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
        case .custom(let custom, _, _):
            // Bit-cast the `CustomPlaylist`'s own `Int64` row id into the
            // same `persistentID` field a real Apple Music source uses --
            // see `SourceType.customPlaylist`'s own doc comment.
            let bitCastID = MPMediaEntityPersistentID(bitPattern: custom.id ?? 0)
            source = SelectedSource(id: "customPlaylist:\(bitCastID)", type: .customPlaylist, label: custom.name, persistentID: bitCastID)
        }
        let selected = viewModel.isSelected(source)

        return VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
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
                }
            }
            .buttonStyle(.plain)

            // **Moved out from under the artwork 2026-09-08** — the edit
            // pencil used to overlay this whole cell's bottom-leading
            // corner, which put it directly on top of this exact "N songs"
            // text (Andy, with a screenshot: "It covers no. of songs in
            // current position... Pencil should be on the right side.").
            // Now a plain sibling row, trailing side, clear of everything
            // else and matching where he asked for it.
            HStack {
                Text("\(row.songCount) songs")
                    .font(.caption)
                    .foregroundStyle(DesignTokens.Color.textSecondary)
                Spacer()
                editButton(for: row)
            }
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
                .foregroundStyle(DesignTokens.Color.primary, DesignTokens.Color.surfaceTint)
        }
        .buttonStyle(.plain)
    }

    /// A `.custom` row already has a real `CustomPlaylist` id — pushes
    /// straight to it. A `.apple` row is shown read-only, per this file's
    /// own doc comment — no copy happens here anymore; `beginEditing` only
    /// picks which target to show.
    private func beginEditing(_ row: MergedRow) {
        switch row {
        case .custom(let custom, _, _):
            editTarget = .existing(custom.id ?? 0)
        case .apple(let apple):
            editTarget = .appleOrigin(apple.persistentID)
        }
    }

    /// If the plain Apple Music playlist just genuinely edited was already
    /// picked as a Build Mix source, its selection needs to move to the new
    /// native copy that just replaced it in this grid — otherwise the old,
    /// now-orphaned `.playlist` source would silently linger in the Hub's
    /// chip row while the merged cell it used to represent shows as
    /// unselected, a real (if minor) inconsistency copy-on-edit would
    /// otherwise introduce. A no-op when the edited row wasn't selected to
    /// begin with. **Now triggered by `CustomPlaylistDetailView`'s
    /// `onCopyCreated` callback (2026-09-08), the actual moment a copy gets
    /// made, instead of running eagerly from `beginEditing` above.**
    private func migrateSelectionIfNeeded(fromApplePersistentID applePersistentID: MPMediaEntityPersistentID, to copy: CustomPlaylist) {
        guard let apple = applePlaylists.first(where: { $0.persistentID == applePersistentID }) else { return }
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

    /// Best-effort, same "a missing count/artwork isn't worth blocking the
    /// screen over" posture `PlaylistStore.loadCollages` already
    /// established. **Extended 2026-09-08** to also resolve each native
    /// playlist's own cover — the real artwork of whichever song currently
    /// sits at position 0, standing in for a cover a `CustomPlaylist` has no
    /// real one of its own, per Andy's own suggestion (see this file's
    /// `customPlaylistArtwork` doc comment).
    private func loadCustomPlaylistSongCounts() {
        guard let db = store.db else { return }
        var counts: [Int64: Int] = [:]
        var artwork: [Int64: UIImage] = [:]
        for playlist in viewModel.customPlaylists {
            guard let id = playlist.id else { continue }
            // `try?` on a throwing function that itself returns an Optional
            // flattens to one level (SE-0230) -- a single `?` here, not a
            // double one, per this project's own hard-earned lesson on this
            // exact mistake (see `SourceSelectionViewModel.loadFavoriteSongsCount`'s
            // history).
            let detail = try? db.loadCustomPlaylistDetail(customPlaylistID: id)
            counts[id] = detail?.tracks.count ?? 0
            if let firstTrackID = detail?.tracks.first?.track.persistentID {
                artwork[id] = ArtworkResolver.loadArtwork(forTrackPersistentID: firstTrackID, size: CGSize(width: 140, height: 140))
            }
        }
        customPlaylistSongCounts = counts
        customPlaylistArtwork = artwork
    }
}
