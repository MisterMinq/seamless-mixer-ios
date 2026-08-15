import SwiftUI
import UIKit
import MediaPlayer
import PlaylistCore

/// Second of the four category pickers (Screen 2), per the confirmed
/// Source Selection design: "grid-style rows with square collage/artwork
/// thumbnails, same as Apple's own Playlists screen, checkbox added. No A-Z
/// rail — Andy's own library only has a handful of playlists, and playlists
/// are usually recognized by cover/name at a glance rather than looked up
/// alphabetically."
///
/// Built after Genres (the simplest of the four) and before Artists/Albums
/// (which both need an A-Z index rail, a larger separate piece of work) —
/// same phased approach as everything else in this app.
///
/// `MixBuilder` now resolves `.playlist` selections for real — it re-finds
/// the exact `MPMediaPlaylist` by `persistentID` (a playlist's own name
/// isn't a reliable re-lookup key the way a genre's is) and pulls its
/// `.items` directly, added the same slice as the Artists/Albums non-genre
/// resolution. "Whole library" is still the one remaining unsupported
/// selection.
struct PlaylistPickerView: View {
    @ObservedObject var viewModel: SourceSelectionViewModel
    @State private var playlists: [PlaylistRow] = []
    /// **Added 2026-08-15** — see `GenrePickerView`'s own note on why this
    /// is separate from the Hub's global search.
    @State private var searchText = ""

    struct PlaylistRow: Identifiable {
        let persistentID: MPMediaEntityPersistentID
        let name: String
        let songCount: Int
        let artwork: UIImage?
        var id: MPMediaEntityPersistentID { persistentID }
    }

    private let columns = [GridItem(.adaptive(minimum: 140), spacing: DesignTokens.Spacing.sm)]

    private var filteredPlaylists: [PlaylistRow] {
        guard !searchText.isEmpty else { return playlists }
        return playlists.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: DesignTokens.Spacing.md) {
                ForEach(filteredPlaylists) { playlist in
                    cell(for: playlist)
                }
            }
            .padding(DesignTokens.Spacing.md)
        }
        .background(DesignTokens.Color.background)
        .searchable(text: $searchText, prompt: "Search playlists")
        .navigationTitle("Playlists")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadPlaylists)
    }

    private func cell(for playlist: PlaylistRow) -> some View {
        let source = SelectedSource(id: "playlist:\(playlist.persistentID)", type: .playlist, label: playlist.name, persistentID: playlist.persistentID)
        let selected = viewModel.isSelected(source)

        return Button {
            viewModel.toggle(source)
        } label: {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                ZStack(alignment: .topTrailing) {
                    artworkTile(for: playlist)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selected ? DesignTokens.Color.primary : .white)
                        .padding(4)
                        .background(Circle().fill(Color.black.opacity(0.35)))
                        .padding(DesignTokens.Spacing.xxs)
                }
                Text(playlist.name)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(DesignTokens.Color.textPrimary)
                    .lineLimit(1)
                // Same "N songs" caption every category picker keeps, per
                // the confirmed design's row-consistency note.
                Text("\(playlist.songCount) songs")
                    .font(.caption)
                    .foregroundStyle(DesignTokens.Color.textSecondary)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func artworkTile(for playlist: PlaylistRow) -> some View {
        RoundedRectangle(cornerRadius: DesignTokens.Size.cornerRadiusMedium)
            .fill(DesignTokens.Color.surfaceTint)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let artwork = playlist.artwork {
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
        playlists = collections
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
}
