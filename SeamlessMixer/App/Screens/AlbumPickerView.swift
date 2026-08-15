import SwiftUI
import UIKit
import MediaPlayer
import PlaylistCore

/// Fourth and last of the four category pickers (Screen 2), per the
/// confirmed Source Selection design: "same grid treatment as Playlists,
/// plus an A-Z index rail like Artists — album collections scale the same
/// way artist lists do."
///
/// Deliberately combines two already-proven patterns rather than
/// introducing a third: `PlaylistPickerView`'s artwork-grid cell (square
/// tile, checkmark overlay, name + song count) and `ArtistPickerView`'s
/// A-Z rail (`ScrollViewReader` + per-letter `.id()`, tap-to-scroll
/// overlay) — both confirmed compiling and working on Codemagic already.
/// One structural difference from Artists: this uses a plain `ScrollView`
/// + `LazyVStack` of (letter header + `LazyVGrid`) per section, not
/// `List`/`Section`, since a `List` doesn't nest a grid per section
/// cleanly — a `ScrollView`-based layout was the more direct fit here.
///
/// `MixBuilder` now resolves `.album` selections for real (via
/// `MPMediaItemPropertyAlbumPersistentID`), added the same slice as the
/// Playlists/Artists non-genre resolution.
struct AlbumPickerView: View {
    @ObservedObject var viewModel: SourceSelectionViewModel
    @State private var sections: [AlbumSection] = []
    /// **Added 2026-08-15** — see `ArtistPickerView`'s own note; same
    /// per-section filtering approach, since this picker shares the same
    /// A-Z-rail structure.
    @State private var searchText = ""

    struct AlbumRow: Identifiable {
        let persistentID: MPMediaEntityPersistentID
        let title: String
        let songCount: Int
        let artwork: UIImage?
        var id: MPMediaEntityPersistentID { persistentID }
    }

    struct AlbumSection: Identifiable {
        let letter: String
        let albums: [AlbumRow]
        var id: String { letter }
    }

    private let columns = [GridItem(.adaptive(minimum: 140), spacing: DesignTokens.Spacing.sm)]

    private var filteredSections: [AlbumSection] {
        guard !searchText.isEmpty else { return sections }
        return sections.compactMap { section in
            let matches = section.albums.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
            return matches.isEmpty ? nil : AlbumSection(letter: section.letter, albums: matches)
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .trailing) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                        ForEach(filteredSections) { section in
                            Text(section.letter)
                                .font(.headline)
                                .foregroundStyle(DesignTokens.Color.textSecondary)
                                .id(section.letter)
                                .padding(.top, DesignTokens.Spacing.sm)

                            LazyVGrid(columns: columns, spacing: DesignTokens.Spacing.md) {
                                ForEach(section.albums) { album in
                                    cell(for: album)
                                }
                            }
                        }
                    }
                    .padding(DesignTokens.Spacing.md)
                }

                if searchText.isEmpty, sections.count > 1 {
                    indexRail(proxy: proxy)
                }
            }
        }
        .background(DesignTokens.Color.background)
        .searchable(text: $searchText, prompt: "Search albums")
        .navigationTitle("Albums")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadAlbums)
    }

    private func indexRail(proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 1) {
            ForEach(sections) { section in
                Button {
                    proxy.scrollTo(section.letter, anchor: .top)
                } label: {
                    Text(section.letter)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(DesignTokens.Color.primaryText)
                        .frame(width: 18)
                }
            }
        }
        .padding(.trailing, DesignTokens.Spacing.xxs)
    }

    private func cell(for album: AlbumRow) -> some View {
        let source = SelectedSource(id: "album:\(album.persistentID)", type: .album, label: album.title, persistentID: album.persistentID)
        let selected = viewModel.isSelected(source)

        return Button {
            viewModel.toggle(source)
        } label: {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                // Checkmark moved to `.topLeading` 2026-08-14 -- real-device
                // feedback found the right column of this 2-column grid put
                // its checkmark right next to the A-Z index rail pinned at
                // the screen's own trailing edge, so taps meant for the
                // checkmark were landing on the rail instead and jumping to
                // a different letter. Left-aligned matches Genres/Artists'
                // own convention anyway -- Playlists (no A-Z rail to
                // conflict with) is the one screen that keeps the
                // trailing-side treatment.
                ZStack(alignment: .topLeading) {
                    artworkTile(for: album)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selected ? DesignTokens.Color.primary : .white)
                        .padding(4)
                        .background(Circle().fill(Color.black.opacity(0.35)))
                        .padding(DesignTokens.Spacing.xxs)
                }
                Text(album.title)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(DesignTokens.Color.textPrimary)
                    .lineLimit(1)
                Text("\(album.songCount) songs")
                    .font(.caption)
                    .foregroundStyle(DesignTokens.Color.textSecondary)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func artworkTile(for album: AlbumRow) -> some View {
        RoundedRectangle(cornerRadius: DesignTokens.Size.cornerRadiusMedium)
            .fill(DesignTokens.Color.surfaceTint)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let artwork = album.artwork {
                    Image(uiImage: artwork)
                        .resizable()
                        .scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Size.cornerRadiusMedium))
                } else {
                    Image(systemName: "square.stack")
                        .foregroundStyle(DesignTokens.Color.primaryText)
                }
            }
            .clipped()
    }

    private func loadAlbums() {
        let collections = MPMediaQuery.albums().collections ?? []
        let rows: [AlbumRow] = collections.compactMap { collection in
            guard let item = collection.representativeItem,
                  let title = item.albumTitle, !title.isEmpty else { return nil }
            return AlbumRow(
                persistentID: item.albumPersistentID,
                title: title,
                songCount: collection.items.count,
                artwork: item.artwork?.image(at: CGSize(width: 140, height: 140))
            )
        }

        // Same "#" bucket-for-non-letters convention as ArtistPickerView.
        let grouped = Dictionary(grouping: rows) { row -> String in
            guard let first = row.title.first, first.isLetter else { return "#" }
            return String(first).uppercased()
        }

        sections = grouped.keys.sorted().map { letter in
            let sorted = grouped[letter]!.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            return AlbumSection(letter: letter, albums: sorted)
        }
    }
}
